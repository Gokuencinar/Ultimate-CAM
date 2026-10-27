#include <metal_stdlib>
#include "FusionMath.h"
using namespace metal;

struct FusionParameters {
    uint4 size; // width, height, tile side, sensor/RGB mode
    int4 search; // radius, has seed, spare, spare
    float4 control; // noise variance, tone gain, white point, spare
    float4 luma;
    float4 noise; // Pair shot/read variance in the reference exposure domain.
    float4 tone; // toe strength, deep-shadow chroma start/end, reserved.
    float4 sensorNoise; // Reference shot/read, sample shot/read before scaling.
    uint4 flags; // Astro / reserved.
    float4 sr; // Crop origin in quads; output/source sampling scales.
    uint4 roi; // Half-open active quad box (or level-scaled box for flow).
};
constexpr sampler pixels(coord::pixel,address::clamp_to_edge,filter::linear);

kernel void uc_protect_bayer(texture2d<float,access::read> input [[texture(0)]],
                             texture2d<float,access::write> output [[texture(1)]],
                             constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    float4 center=input.read(p),low=float4(INFINITY),high=float4(-INFINITY);uint count=0;
    for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
        int2 q=int2(p)+int2(x,y);
        if ((x==0 && y==0) || any(q<0) || q.x>=int(input.get_width()) || q.y>=int(input.get_height())) continue;
        float4 neighbor=input.read(uint2(q));low=min(low,neighbor);high=max(high,neighbor);++count;
    }
    if (count>=3) {
        // Component-wise only: each texture channel is one fixed CFA phase.
        // Estimate variance from neighbours so an impulse cannot inflate it.
        float4 variance=max(params.sensorNoise.x*max((low+high)*0.5f,0.0f)+params.sensorNoise.y,1e-8f);
        float4 threshold=6.0f*sqrt(variance),bounded=clamp(center,low,high);
        float4 strength=smoothstep(threshold,threshold*2.0f,abs(center-bounded));
        center=mix(center,bounded,strength);
    }
    output.write(center,p);
}

kernel void uc_initial_weights(texture2d<float,access::write> output [[texture(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x<output.get_width() && p.y<output.get_height()) output.write(float4(1.0f),p);
}

kernel void uc_luma(texture2d<float,access::read> input [[texture(0)]],
                    texture2d<float,access::write> output [[texture(1)]],
                    constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x<output.get_width() && p.y<output.get_height()) output.write(float4(dot(input.read(p),params.luma)),p);
}

kernel void uc_pyramid(texture2d<float,access::read> input [[texture(0)]],
                       texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    uint2 edge=uint2(input.get_width()-1,input.get_height()-1),q=p*2;
    float value=(input.read(min(q,edge)).r+input.read(min(q+uint2(1,0),edge)).r+
                 input.read(min(q+uint2(0,1),edge)).r+input.read(min(q+1,edge)).r)*0.25f;
    output.write(float4(value),p);
}

inline float uc_tile_cost(texture2d<float,access::sample> reference,
                          texture2d<float,access::sample> sample,uint2 tile,float2 shift,
                          constant FusionParameters &params) {
    float cost=0;uint count=0;
    for (uint y=0;y<16;y+=2) for (uint x=0;x<16;x+=2) {
        float2 p=float2(tile*16+uint2(x,y))+0.5f,q=p+shift;
        if (p.x>=reference.get_width() || p.y>=reference.get_height() || q.x<0.5f || q.y<0.5f ||
            q.x>sample.get_width()-0.5f || q.y>sample.get_height()-0.5f) continue;
        float a=reference.sample(pixels,p).r,b=sample.sample(pixels,q).r*params.control.w;
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
    if (params.size.w==1 && (tile.x*16>=params.roi.z || tile.y*16>=params.roi.w ||
        (tile.x+1)*16<=params.roi.x || (tile.y+1)*16<=params.roi.y)) {
        output.write(float4(0,0,1,0),tile);return;
    }
    float2 center=min((float2(tile)+0.5f)*16.0f,float2(reference.get_width(),reference.get_height())-1.0f);
    int2 prediction=0;float seedConfidence=0;
    if (params.search.y) {
        uint2 index=min(uint2(center*0.5f/16.0f),uint2(seed.get_width()-1,seed.get_height()-1));
        float4 prior=seed.read(index);prediction=int2(round(prior.xy*2.0f));seedConfidence=prior.w;
    }
    float priorWeight=1e-5f+2e-4f*seedConfidence;
    float best=uc_tile_cost(reference,sample,tile,float2(prediction),params),second=INFINITY;
    float bestScore=best;int2 chosen=prediction;
    for (int dy=-params.search.x;dy<=params.search.x;++dy) for (int dx=-params.search.x;dx<=params.search.x;++dx) {
        if (dx==0 && dy==0) continue;
        int2 shift=prediction+int2(dx,dy);
        float cost=uc_tile_cost(reference,sample,tile,float2(shift),params);
        float score=cost+priorWeight*float(dx*dx+dy*dy);
        if (score<bestScore) { second=bestScore;bestScore=score;best=cost;chosen=shift; } else second=min(second,score);
    }
    float2 refined=float2(chosen);
    if (params.search.w && isfinite(best)) {
        for (uint stage=0;stage<2;++stage) {
            float step=stage==0 ? 0.5f:0.25f;
            float2 origin=refined;
            for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
                if (x==0 && y==0) continue;
                float2 shift=origin+float2(x,y)*step;
                float cost=uc_tile_cost(reference,sample,tile,shift,params);
                float2 deviation=shift-float2(prediction);
                float score=cost+priorWeight*dot(deviation,deviation);
                if (score<bestScore) { bestScore=score;best=cost;refined=shift; }
            }
        }
    }
    float a=reference.sample(pixels,center+float2(-5,-5)).r,b=reference.sample(pixels,center+float2(5,-5)).r;
    float c=reference.sample(pixels,center+float2(-5,5)).r,d=reference.sample(pixels,center+float2(5,5)).r;
    float contrast=max(max(a,b),max(c,d))-min(min(a,b),min(c,d));
    float floor=max(0.002f,2.0f*sqrt(max(params.control.x,1e-8f)));
    float textureWeight=smoothstep(floor,floor*3.0f,contrast);
    float confidence=isfinite(best) ? clamp((second-bestScore)/max(second,1e-6f)*4.0f,0.0f,1.0f)*textureWeight:0.0f;
    output.write(float4(refined,isfinite(best) ? best:1.0f,confidence),tile);
}

// Keep strong matches and motion boundaries intact. Replace only an isolated,
// ambiguous vector supported by at least three confident neighbouring tiles.
kernel void uc_regularize_flow(texture2d<float,access::sample> reference [[texture(0)]],
                               texture2d<float,access::sample> sample [[texture(1)]],
                               texture2d<float,access::read> input [[texture(2)]],
                               texture2d<float,access::write> output [[texture(3)]],
                               constant FusionParameters &params [[buffer(0)]],uint2 tile [[thread_position_in_grid]]) {
    if (tile.x>=output.get_width() || tile.y>=output.get_height()) return;
    if (params.size.w==1 && (tile.x*16>=params.roi.z || tile.y*16>=params.roi.w ||
        (tile.x+1)*16<=params.roi.x || (tile.y+1)*16<=params.roi.y)) {
        output.write(float4(0,0,1,0),tile);return;
    }
    float4 current=input.read(tile);
    if (current.w<0.25f) {
        float xs[8],ys[8],confidence=0;uint count=0;
        for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
            int2 q=int2(tile)+int2(x,y);
            if ((x==0 && y==0) || any(q<0) || q.x>=int(input.get_width()) || q.y>=int(input.get_height())) continue;
            float4 neighbor=input.read(uint2(q));
            if (neighbor.w<0.25f || !all(isfinite(neighbor))) continue;
            xs[count]=neighbor.x;ys[count]=neighbor.y;confidence+=neighbor.w;++count;
        }
        if (count>=3) {
            for (uint i=1;i<count;++i) {
                for (uint j=i;j>0 && xs[j]<xs[j-1];--j) { float t=xs[j];xs[j]=xs[j-1];xs[j-1]=t; }
                for (uint j=i;j>0 && ys[j]<ys[j-1];--j) { float t=ys[j];ys[j]=ys[j-1];ys[j-1]=t; }
            }
            float2 median=float2(xs[count/2],ys[count/2]);uint support=0;
            for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
                int2 q=int2(tile)+int2(x,y);
                if ((x==0 && y==0) || any(q<0) || q.x>=int(input.get_width()) || q.y>=int(input.get_height())) continue;
                float4 neighbor=input.read(uint2(q));
                if (neighbor.w>=0.25f && distance(neighbor.xy,median)<1.5f) ++support;
            }
            if (support>=3 && distance(current.xy,median)>1.5f) {
                float cost=uc_tile_cost(reference,sample,tile,median,params);
                // Photometric veto: never borrow flow across an object edge
                // when it explains the local tile worse than the original.
                if (isfinite(cost) && cost<=current.z+sqrt(max(params.control.x,1e-8f)))
                    current=float4(median,cost,min(0.5f,confidence/float(count)));
            }
        }
    }
    output.write(current,tile);
}

// This expensive patch comparison runs only at reference pixels changed by
// spatial impulse protection. Other pixels retain the cheap fusion path.
inline float4 uc_point_support(texture2d<float,access::sample> rawReference,
 texture2d<float,access::sample> rawSample,uint2 p,float2 q,float4 clean,
 float2 displacement,constant FusionParameters &params) {
 float4 peak=rawReference.read(p);
 if (!any(peak-clean>1e-5f)) return float4(0);
 float4 upper=float4(-INFINITY),alignedUpper=upper,alignedError=0,stationaryError=0;
 for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
  uint2 r=uint2(clamp(int2(p)+int2(x,y),int2(0),int2(rawReference.get_width()-1,rawReference.get_height()-1)));
  float4 a=rawReference.read(r),b=rawSample.sample(pixels,q+float2(x,y))*params.control.w;
  float4 fixed=rawSample.read(r)*params.control.w;
  alignedError+=(a-b)*(a-b)/9.0f;stationaryError+=(a-fixed)*(a-fixed)/9.0f;
  if(x || y) { upper=max(upper,a);alignedUpper=max(alignedUpper,b); }
 }
 float4 candidate=rawSample.sample(pixels,q)*params.control.w;
 float4 sigma=sqrt(max(params.noise.x*max(upper,0.0f)+params.noise.y,1e-8f)),result=0;
 for(uint c=0;c<4;++c) result[c]=UCTemporalPoint(peak[c],upper[c],candidate[c],alignedUpper[c],sigma[c],length(displacement),alignedError[c],stationaryError[c]) ? 1.0f:0.0f;
 return result;
}

kernel void uc_fuse_tiles(texture2d<float,access::read> reference [[texture(0)]],
                          texture2d<float,access::sample> sample [[texture(1)]],
                          texture2d<float,access::read> mean [[texture(2)]],
                          texture2d<float,access::read> weights [[texture(3)]],
                          texture2d<float,access::read> flow [[texture(4)]],
                          texture2d<float,access::write> nextMean [[texture(5)]],
                          texture2d<float,access::write> nextWeights [[texture(6)]],
                          texture2d<float,access::sample> rawReference [[texture(7)]],
                          texture2d<float,access::sample> rawSample [[texture(8)]],
                          constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=reference.get_width() || p.y>=reference.get_height()) return;
    float4 anchor=reference.read(p);
    if (params.size.w==1 && (p.x<params.roi.x || p.y<params.roi.y || p.x>=params.roi.z || p.y>=params.roi.w)) {
        nextMean.write(anchor,p);nextWeights.write(float4(1.0f),p);return;
    }
    float4 acc=mean.read(p);float oldWeight=weights.read(p).x;
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
        float4 pairAnchor=anchor;
        if(params.size.w) {
            float4 supported=uc_point_support(rawReference,rawSample,p,q,anchor,motion.xy,params);
            pairAnchor=mix(anchor,rawReference.read(p),supported);
            sensor=mix(sensor,rawSample.sample(pixels,q),supported);
            // Restore the clipped reference contribution only after temporal
            // support, including support first discovered in a later frame.
            acc=mix(acc,max(acc,pairAnchor),supported);
        }
        float4 candidate=sensor*params.control.w;
        float4 residual=candidate-pairAnchor;
        float energy=params.size.w ? dot(residual*residual,float4(0.25f)):dot(residual.rgb*residual.rgb,float3(1.0f/3));
        float variance=max(params.control.x,1e-7f);
        if (params.size.w) {
            float signal=UCRAWVarianceSignal(dot(anchor,float4(0.25f)),dot(candidate,float4(0.25f)));
            variance=max(params.noise.x*signal+params.noise.y,1e-8f);
        }
        float4 localResidual=0;float localEnergy=0;
        for (int dy=-1;dy<=1;++dy) for (int dx=-1;dx<=1;++dx) {
            uint2 rp=uint2(clamp(int2(p)+int2(dx,dy),int2(0),int2(reference.get_width()-1,reference.get_height()-1)));
            float4 delta=sample.sample(pixels,q+float2(dx,dy))*params.control.w-reference.read(rp);
            localResidual+=delta/9.0f;localEnergy+=dot(delta*delta,float4(0.25f))/9.0f;
        }
        float biasEnergy=dot(localResidual*localResidual,float4(0.25f));
        float occlusion=1.0f-smoothstep(9.0f*variance,64.0f*variance,biasEnergy);
        // A coherent moved edge remains different across its neighbourhood;
        // independent sensor noise averages out instead of becoming a ghost.
        float robust=exp(-energy/(18.0f*variance))*occlusion;
        robust*=1.0f-smoothstep(36.0f*variance,144.0f*variance,localEnergy);
        // A low-cost zero match is valid in smooth areas; a high-cost ambiguous
        // match is rejected. The reference always supplies weight one.
        float reliable=motion.z<3.0f*sqrt(variance) ? 1.0f:motion.w;
        float spatial=(corner.x ? fraction.x:1-fraction.x)*(corner.y ? fraction.y:1-fraction.y);
        float exposureWeight=1.0f;
        if (params.search.z) {
            float low=min(min(sensor.r,sensor.g),min(sensor.b,sensor.a));
            float high=max(max(sensor.r,sensor.g),max(sensor.b,sensor.a));
            // Longer exposures supply the shadow signal, even if one CFA phase is black.
            exposureWeight=UCHDRExposureWeight(low,high,params.control.w);
        }
        float weight=spatial*robust*reliable*exposureWeight;
        contribution+=candidate*weight;accepted+=weight;
    }
    float weight=oldWeight+accepted;
    float4 fused=(acc*oldWeight+contribution)/max(weight,1.0f);
    if (!params.size.w) fused.a=1;
    nextMean.write(fused,p);nextWeights.write(float4(weight),p);
}

// Compact luminance base: sixteen area samples, no full-resolution extra plane.
kernel void uc_tone_luma(texture2d<float,access::sample> input [[texture(0)]],
                         texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    float2 footprint=float2(input.get_width(),input.get_height())/float2(output.get_width(),output.get_height());
    float luminance=0;
    for (uint y=0;y<4;++y) for (uint x=0;x<4;++x) {
        float2 q=(float2(p)+(float2(x,y)+0.5f)/4.0f)*footprint;
        luminance+=max(dot(input.sample(pixels,q).rgb,float3(0.2126f,0.7152f,0.0722f)),0.0f);
    }
    output.write(float4(luminance/16.0f),p);
}

inline float uc_log_base(texture2d<float,access::sample> image,float2 uv,float logL) {
    float2 center=uv*float2(image.get_width(),image.get_height());
    float sum=0,weights=0;
    for (int y=-2;y<=2;++y) for (int x=-2;x<=2;++x) {
        float local=log2(max(image.sample(pixels,center+float2(x,y)).r,1e-6f));
        float weight=exp(-float(x*x+y*y)/3.0f-abs(local-logL)*1.2f);
        sum+=local*weight;weights+=weight;
    }
    return sum/max(weights,1e-12f);
}

kernel void uc_night_tone(texture2d<float,access::sample> input [[texture(0)]],
                          texture2d<float,access::sample> mediumBase [[texture(1)]],
                          texture2d<float,access::sample> wideBase [[texture(2)]],
                          texture2d<float,access::write> output [[texture(3)]],
                          constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    float3 rgb=max(input.sample(pixels,float2(p)+0.5f).rgb,0.0f);
    float luminance=dot(rgb,float3(0.2126f,0.7152f,0.0722f));
    if (luminance<=1e-6f) { output.write(float4(0,0,0,1),p);return; }
    float logL=log2(luminance);
    float2 uv=(float2(p)+0.5f)/float2(output.get_width(),output.get_height());
    // Two edge-aware scales: ~32 px and ~128 px radii at native 12 MP.
    float baseLog=mix(uc_log_base(mediumBase,uv,logL),uc_log_base(wideBase,uv,logL),0.7f);
    float base=exp2(baseLog),scaled=base*params.control.y;
    float white=max(params.control.z,2.0f);
    float compressed=scaled*(1.0f+scaled/(white*white))/(1.0f+scaled);
    // Recombine full-resolution luminance without flattening fine detail.
    float mapped=compressed*luminance/max(base,1e-6f);
    float toe=max(params.tone.x,0.0f);
    mapped=mapped*mapped/max(mapped+toe,1e-6f)*(0.18f+toe)/0.18f;
    // Only low-signal chroma is attenuated. Luma and hue ratios in supported
    // midtones/highlights are unchanged by the shadow chroma stage.
    float chroma=params.tone.z>params.tone.y ? smoothstep(params.tone.y,params.tone.z,luminance):1.0f;
    float3 clean=mix(float3(luminance),rgb,chroma);
    float3 result=clean*(mapped/luminance);
    result/=max(1.0f,max(result.r,max(result.g,result.b)));
    output.write(float4(result,1),p);
}

// Gather measured CFA samples onto the dense grid. Four phase-specific weights
// retain the physical half-quad offsets; no demosaicked resize is involved.
kernel void uc_fuse_super_res(texture2d<float,access::sample> reference [[texture(0)]],
 texture2d<float,access::read> sample [[texture(1)]],texture2d<float,access::read> mean [[texture(2)]],
 texture2d<float,access::read> weights [[texture(3)]],texture2d<float,access::read> flow [[texture(4)]],
 texture2d<float,access::write> nextMean [[texture(5)]],texture2d<float,access::write> nextWeights [[texture(6)]],
 texture2d<float,access::sample> rawReference [[texture(7)]],texture2d<float,access::sample> rawSample [[texture(8)]],
 constant FusionParameters &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
 if (p.x>=nextMean.get_width() || p.y>=nextMean.get_height()) return;
 float2 center=params.sr.xy+(float2(p)+0.5f)/params.sr.zw;
 uint2 tile=min(uint2(max(center,0.0f)/16),uint2(flow.get_width()-1,flow.get_height()-1));
 float4 motion=params.search.y ? flow.read(tile):float4(0,0,0,1);
 float4 sum=0,total=0,previous=mean.read(p);
 for (uint phase=0;phase<4;++phase) {
  float2 phaseOffset=float2(phase&1,phase>>1)*0.5f+0.25f;
  float2 native=float2(UCSRPosition(float(p.x),phaseOffset.x,params.sr.x,params.sr.z),UCSRPosition(float(p.y),phaseOffset.y,params.sr.y,params.sr.w));
  float2 q=native+motion.xy;int2 base=int2(floor(q));
  float4 clean=reference.sample(pixels,native+0.5f);
  uint2 rp=uint2(clamp(round(native),float2(0),float2(reference.get_width()-1,reference.get_height()-1)));
  float4 supported=params.search.y ? uc_point_support(rawReference,rawSample,rp,float2(rp)+0.5f+motion.xy,reference.read(rp),motion.xy,params):float4(0);
  float anchor=mix(clean[phase],rawReference.sample(pixels,native+0.5f)[phase],supported[phase]);
  if(supported[phase]>0.5f) previous[phase]=max(previous[phase],anchor);
  float signal=max(anchor,0.0f),variance=max(params.noise.x*signal+params.noise.y,1e-6f);
  float reliable=motion.z<3*sqrt(variance) ? 1.0f:motion.w;
  for (int y=-1;y<=2;++y) for (int x=-1;x<=2;++x) {
   int2 source=base+int2(x,y);if (any(source<0) || source.x>=int(sample.get_width()) || source.y>=int(sample.get_height())) continue;
   float sensor=mix(sample.read(uint2(source))[phase],rawSample.read(uint2(source))[phase],supported[phase]),value=sensor*params.control.w;
   float2 d=float2(source)-q;float radial=UCSRWeight(d.x,d.y);
   // Allow genuine alias detail only for a registered, low-cost tile.
   float robust=exp(-(value-anchor)*(value-anchor)/(18*variance));
   if (motion.z<sqrt(variance)) robust=max(robust,0.15f);
   float w=radial*robust*reliable;
   if (params.search.z) w*=UCHDRExposureWeight(sensor,sensor,params.control.w);
   sum[phase]+=value*w;total[phase]+=w;
  }
 }
 float4 old=weights.read(p),combined=old+total;
 nextMean.write((previous*old+sum)/max(combined,1e-8f),p);nextWeights.write(combined,p);
}
kernel void uc_clear(texture2d<float,access::write> output [[texture(0)]],uint2 p [[thread_position_in_grid]]) {
 if (p.x<output.get_width() && p.y<output.get_height()) output.write(float4(0),p);
}
