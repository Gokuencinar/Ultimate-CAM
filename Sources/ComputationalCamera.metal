#include <metal_stdlib>
using namespace metal;

struct FusionParameters {
    uint4 size; // width, height, tile side, sensor/RGB mode
    int4 search; // radius, has seed, spare, spare
    float4 control; // noise variance, tone gain, white point, spare
    float4 luma;
};
constexpr sampler pixels(coord::pixel,address::clamp_to_edge,filter::linear);

kernel void uc_pyramid(texture2d<float,access::read> input [[texture(0)]],
                       texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    uint2 edge=uint2(input.get_width()-1,input.get_height()-1),q=p*2;
    output.write((input.read(min(q,edge))+input.read(min(q+uint2(1,0),edge))+
                  input.read(min(q+uint2(0,1),edge))+input.read(min(q+1,edge)))*0.25f,p);
}

inline float uc_tile_cost(texture2d<float,access::sample> reference,
                          texture2d<float,access::sample> sample,uint2 tile,float2 shift,
                          constant FusionParameters &params) {
    float cost=0;uint count=0;
    for (uint y=0;y<16;y+=2) for (uint x=0;x<16;x+=2) {
        float2 p=float2(tile*16+uint2(x,y))+0.5f,q=p+shift;
        if (p.x>=reference.get_width() || p.y>=reference.get_height() || q.x<0.5f || q.y<0.5f ||
            q.x>sample.get_width()-0.5f || q.y>sample.get_height()-0.5f) continue;
        float a=dot(reference.sample(pixels,p),params.luma),b=dot(sample.sample(pixels,q),params.luma)*params.control.w;
        cost+=min(abs(a-b),0.25f);++count;
    }
    return count>=12 ? cost/float(count):INFINITY;
}

// One thread per tile. Coarse-to-fine bounded search; phase channels are never
// shuffled by Bayer interpolation. Flow is in the current level's quad pixels.
kernel void uc_tile_flow(texture2d<float,access::sample> reference [[texture(0)]],
                         texture2d<float,access::sample> sample [[texture(1)]],
                         texture2d<float,access::read> seed [[texture(2)]],
                         texture2d<float,access::write> output [[texture(3)]],
                         constant FusionParameters &params [[buffer(0)]],uint2 tile [[thread_position_in_grid]]) {
    if (tile.x>=output.get_width() || tile.y>=output.get_height()) return;
    float2 center=min((float2(tile)+0.5f)*16.0f,float2(reference.get_width(),reference.get_height())-1.0f);
    int2 prediction=0;
    if (params.search.y) {
        uint2 index=min(uint2(center*0.5f/16.0f),uint2(seed.get_width()-1,seed.get_height()-1));
        prediction=int2(round(seed.read(index).xy*2.0f));
    }
    float best=INFINITY,second=INFINITY;int2 chosen=prediction;
    for (int dy=-params.search.x;dy<=params.search.x;++dy) for (int dx=-params.search.x;dx<=params.search.x;++dx) {
        int2 shift=prediction+int2(dx,dy);
        float cost=uc_tile_cost(reference,sample,tile,float2(shift),params);
        if (cost<best) { second=best;best=cost;chosen=shift; } else second=min(second,cost);
    }
    float2 refined=float2(chosen);
    if (params.search.w && isfinite(best)) {
        for (int y=-2;y<=2;++y) for (int x=-2;x<=2;++x) {
            float2 shift=float2(chosen)+float2(x,y)*0.25f;
            float cost=uc_tile_cost(reference,sample,tile,shift,params);
            if (cost<best) { best=cost;refined=shift; }
        }
    }
    float confidence=isfinite(best) ? clamp((second-best)/max(second,1e-6f)*4.0f,0.0f,1.0f):0.0f;
    output.write(float4(refined,isfinite(best) ? best:1.0f,confidence),tile);
}

kernel void uc_fuse_tiles(texture2d<float,access::read> reference [[texture(0)]],
                          texture2d<float,access::sample> sample [[texture(1)]],
                          texture2d<float,access::read> mean [[texture(2)]],
                          texture2d<float,access::read> weights [[texture(3)]],
                          texture2d<float,access::read> flow [[texture(4)]],
                          texture2d<float,access::write> nextMean [[texture(5)]],
                          texture2d<float,access::write> nextWeights [[texture(6)]],
                          constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=reference.get_width() || p.y>=reference.get_height()) return;
    float4 anchor=reference.read(p),acc=mean.read(p);float oldWeight=weights.read(p).x;
    float2 grid=(float2(p)+0.5f)/16.0f-0.5f;
    int2 base=int2(floor(grid));float2 fraction=fract(grid);
    float4 contribution=0;float accepted=0;
    // Blend four independent tile warps with a partition of unity. Averaging
    // displacement first would blur object boundaries when tiles disagree.
    for (uint i=0;i<4;++i) {
        uint2 corner=uint2(i&1,i>>1);
        uint2 index=uint2(clamp(base+int2(corner),int2(0),int2(flow.get_width()-1,flow.get_height()-1)));
        float4 motion=flow.read(index);float2 q=float2(p)+0.5f+motion.xy;
        if (q.x<0.5f || q.y<0.5f || q.x>sample.get_width()-0.5f || q.y>sample.get_height()-0.5f) continue;
        float4 sensor=sample.sample(pixels,q);
        float4 candidate=sensor*params.control.w;
        float4 residual=candidate-anchor;
        float energy=params.size.w ? dot(residual*residual,float4(0.25f)):dot(residual.rgb*residual.rgb,float3(1.0f/3));
        float variance=max(params.control.x,1e-7f);
        float robust=exp(-energy/(18.0f*variance));
        // A low-cost zero match is valid in smooth areas; a high-cost ambiguous
        // match is rejected. The reference always supplies weight one.
        float reliable=motion.z<3.0f*sqrt(variance) ? 1.0f:motion.w;
        float spatial=(corner.x ? fraction.x:1-fraction.x)*(corner.y ? fraction.y:1-fraction.y);
        float exposureWeight=1.0f;
        if (params.search.z) {
            float low=min(min(sensor.r,sensor.g),min(sensor.b,sensor.a));
            float high=max(max(sensor.r,sensor.g),max(sensor.b,sensor.a));
            exposureWeight=smoothstep(0.001f,0.012f,low)*(1.0f-smoothstep(0.94f,0.995f,high));
        }
        float weight=spatial*robust*reliable*exposureWeight;
        contribution+=candidate*weight;accepted+=weight;
    }
    float weight=oldWeight+accepted;
    float4 fused=(acc*oldWeight+contribution)/max(weight,1.0f);
    if (!params.size.w) fused.a=1;
    nextMean.write(fused,p);nextWeights.write(float4(weight),p);
}

kernel void uc_night_tone(texture2d<float,access::sample> input [[texture(0)]],
                          texture2d<float,access::write> output [[texture(1)]],
                          constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    float3 rgb=max(input.sample(pixels,float2(p)+0.5f).rgb,0.0f);
    float luminance=max(dot(rgb,float3(0.2126f,0.7152f,0.0722f)),1e-6f),logL=log2(luminance);
    float sum=0,weights=0;
    for (int y=-2;y<=2;++y) for (int x=-2;x<=2;++x) {
        float3 neighbor=max(input.sample(pixels,float2(p)+0.5f+float2(x,y)*6.0f).rgb,0.0f);
        float local=log2(max(dot(neighbor,float3(0.2126f,0.7152f,0.0722f)),1e-6f));
        float weight=exp(-float(x*x+y*y)/4.0f-abs(local-logL)*1.5f);
        sum+=local*weight;weights+=weight;
    }
    float base=exp2(sum/max(weights,1e-6f)),scaled=base*params.control.y;
    float white=max(params.control.z,1.0f);
    float compressed=scaled*(1.0f+scaled/(white*white))/(1.0f+scaled);
    float detail=clamp(luminance/max(base,1e-6f),0.25f,4.0f);
    float3 result=rgb*(compressed*detail/luminance);
    // Scale all channels equally when a highlight exceeds the SDR container.
    result/=max(1.0f,max(result.r,max(result.g,result.b)));
    output.write(float4(result,1),p);
}
