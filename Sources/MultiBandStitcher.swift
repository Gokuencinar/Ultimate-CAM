import CoreImage
import Foundation

/// Two-band, exposure-matched seam compositing. Registration stays the job of
/// the panorama homography / spherical projection; a seam cannot solve 3D pose.
enum MultiBandStitcher {
    struct Result { let image:CIImage,coverage:CIImage,gain:SIMD3<Float>;let seam:[Float] }
    private static let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    static func blend(_ a:CIImage,coverage ac:CIImage,_ b:CIImage,coverage bc:CIImage,
                      extent:CGRect,context:CIContext,wrapX:Bool=false,
                      cancellation:ProcessingCancellation?=nil) throws -> Result {
        try cancellation?.check()
        let e=extent.integral,w=Int(e.width),h=Int(e.height)
        guard w>0,h>0,w<=8192,h<=8192,w*h<=16_777_216 else { throw CameraFailure.message("Unión fuera de límites.") }
        let local=CGRect(x:0,y:0,width:w,height:h),move=CGAffineTransform(translationX:-e.minX,y:-e.minY)
        var aa=a.transformed(by:move).cropped(to:local),bb=b.transformed(by:move).cropped(to:local)
        var ca=ac.transformed(by:move).cropped(to:local),cb=bc.transformed(by:move).cropped(to:local)
        let scale=min(1,512/Double(max(w,h))),gw=max(1,Int(Double(w)*scale)),gh=max(1,Int(Double(h)*scale))
        func samples(_ image:CIImage)->[Float] {
            let small=image.transformed(by:CGAffineTransform(scaleX:CGFloat(gw)/CGFloat(w),y:CGFloat(gh)/CGFloat(h)))
            var values=[Float](repeating:0,count:gw*gh*4)
            values.withUnsafeMutableBytes { context.render(small,toBitmap:$0.baseAddress!,rowBytes:gw*16,bounds:CGRect(x:0,y:0,width:gw,height:gh),format:.RGBAf,colorSpace:linear) };return values
        }
        var aw=samples(ca),bw=samples(cb),roll=0.0
        if wrapX {
            // Place the incoming view in the middle before finding its seam;
            // otherwise a patch spanning ±pi is incorrectly treated as two.
            var sx=0.0,sy=0.0,total=0.0
            for y in 0..<gh { for x in 0..<gw {
                let v=Double(bw[(y*gw+x)*4]),angle=2*Double.pi*(Double(x)+0.5)/Double(gw)
                sx+=cos(angle)*v;sy+=sin(angle)*v;total+=v
            } }
            if total>0 && hypot(sx,sy)>total*0.01 { roll=(Double(w)*0.5-atan2(sy,sx)*Double(w)/(2*Double.pi)).rounded() }
            aa=try shifted(aa,by:roll,extent:local);bb=try shifted(bb,by:roll,extent:local)
            ca=try shifted(ca,by:roll,extent:local);cb=try shifted(cb,by:roll,extent:local)
            aw=samples(ca);bw=samples(cb)
        }
        let ap=samples(aa),bp=samples(bb)
        let gain=photometricGain(ap,bp,coverageA:aw,coverageB:bw)
        bb=bb.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:CGFloat(gain.x),y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:CGFloat(gain.y),z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:CGFloat(gain.z),w:0)])
        // Direction is inferred from newly covered pixels, not camera order.
        var ax=0.0,ay=0.0,bx=0.0,by=0.0,na=0.0,nb=0.0
        for y in 0..<gh { for x in 0..<gw {
            let j=(y*gw+x)*4,av=Double(aw[j]),bv=Double(bw[j])
            let onlyA=max(0,av-bv),onlyB=max(0,bv-av)
            ax+=Double(x)*onlyA;ay+=Double(y)*onlyA;na+=onlyA
            bx+=Double(x)*onlyB;by+=Double(y)*onlyB;nb+=onlyB
        } }
        let dx=bx/max(1,nb)-ax/max(1,na),dy=by/max(1,nb)-ay/max(1,na)
        let horizontal=abs(dx)>=abs(dy),positive=horizontal ? dx>=0:dy>=0
        let columns=horizontal ? gw:gh,rows=horizontal ? gh:gw
        var cost=[Float](repeating:.infinity,count:columns*rows)
        for row in 0..<rows { for col in 0..<columns {
            let x=horizontal ? col:row,y=horizontal ? row:col,j=(y*gw+x)*4
            guard aw[j]>0.02,bw[j]>0.02 else { continue }
            var error:Float=0
            for c in 0..<3 { error+=abs(ap[j+c]-bp[j+c]*gain[c]) }
            // A tiny centre tie-breaker prevents a zero-error seam clinging to
            // low-coverage edges. Real photometric differences dominate it.
            cost[row*columns+col]=error/3+0.00001*abs(Float(col)-Float(columns)/2)/Float(columns)
        } }
        let seam=minimumSeam(cost,width:columns,height:rows)
        let data=seam.withUnsafeBufferPointer { Data(buffer:$0) }
        let path=CIImage(bitmapData:data,bytesPerRow:4,size:CGSize(width:1,height:rows),format:.Rf,colorSpace:nil)
        guard let masks=maskKernel?.apply(extent:local,roiCallback:{i,_ in i==0 ? path.extent:local},arguments:[path,ca,cb,CIVector(x:CGFloat(w),y:CGFloat(h)),Double(columns),Double(rows),horizontal ? 1.0:0.0,positive ? 1.0:0.0,max(12,Double(max(w,h))*0.025)]),
              let coverage=coverageKernel?.apply(extent:local,arguments:[ca,cb]) else { throw CameraFailure.message("No se pudo preparar la costura.") }
        let radius=max(2,min(24,Double(max(w,h))*0.008))
        func low(_ color:CIImage,_ coverage:CIImage) throws -> CIImage {
            guard let premult=productKernel?.apply(extent:local,arguments:[color,coverage]) else { throw CameraFailure.message("No se pudo separar la luminancia de la unión.") }
            // Gaussian low bands live on a quarter-size pyramid. Keeping
            // several full 16 MP blurred planes alive would waste phone RAM.
            let down=CGAffineTransform(scaleX:0.25,y:0.25),up=CGAffineTransform(scaleX:4,y:4)
            let small=local.applying(down)
            let support=coverage.transformed(by:down).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*0.25])
            let blurred=premult.transformed(by:down).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*0.25])
            guard let normalized=divideKernel?.apply(extent:small,arguments:[blurred,support]) else { throw CameraFailure.message("No se pudo normalizar la unión.") }
            return normalized.transformed(by:up).cropped(to:local)
        }
        let al=try low(aa,ca),bl=try low(bb,cb)
        guard var combined=blendKernel?.apply(extent:local,arguments:[aa,bb,al,bl,masks,ca,cb]) else { throw CameraFailure.message("No se pudo fusionar la costura.") }
        var union=coverage
        if wrapX { combined=try shifted(combined,by:-roll,extent:local);union=try shifted(union,by:-roll,extent:local) }
        try cancellation?.check()
        // Retire the lazy graph after each frame; no growing full-sequence CI
        // pyramid is retained. Intermediates remain bounded by one join.
        guard let color=context.createCGImage(combined,from:local,format:.RGBAh,colorSpace:linear) else { throw CameraFailure.message("No se pudo terminar la unión.") }
        // Coverage is a scalar mask, not four HDR colour channels (8 MB rather
        // than 67 MB for a 4096×2048 sphere). This also retires its lazy graph.
        let pointer=UnsafeMutableRawPointer.allocate(byteCount:w*h,alignment:16)
        context.render(union,toBitmap:pointer,rowBytes:w,bounds:local,format:.L8,colorSpace:nil)
        let bytes=Data(bytesNoCopy:pointer,count:w*h,deallocator:.custom{p,_ in p.deallocate()})
        let cover=CIImage(bitmapData:bytes,bytesPerRow:w,size:local.size,format:.L8,colorSpace:nil)
        let restore=CGAffineTransform(translationX:e.minX,y:e.minY)
        return Result(image:CIImage(cgImage:color).transformed(by:restore),coverage:cover.transformed(by:restore),gain:gain,seam:seam)
    }
    static func photometricGain(_ a:[Float],_ b:[Float],coverageA:[Float],coverageB:[Float])->SIMD3<Float> {
        guard a.count==b.count,a.count==coverageA.count,a.count==coverageB.count else { return SIMD3(repeating:1) }
        var ratios=[[Float](),[Float](),[Float]()]
        for j in stride(from:0,to:a.count,by:4) {
            guard coverageA[j]>0.5,coverageB[j]>0.5 else { continue }
            // Reject clipped, black and highly coloured samples: gain fitting
            // must not neutralise different objects on opposite sides of a seam.
            let av=SIMD3(a[j],a[j+1],a[j+2]),bv=SIMD3(b[j],b[j+1],b[j+2])
            guard min(av.x,av.y,av.z)>0.01,min(bv.x,bv.y,bv.z)>0.01,max(av.x,av.y,av.z)<0.95,max(bv.x,bv.y,bv.z)<0.95 else { continue }
            for c in 0..<3 { ratios[c].append(log(av[c]/bv[c])) }
        }
        guard ratios[0].count>=24 else { return SIMD3(repeating:1) }
        var logs=SIMD3<Float>.zero
        for c in 0..<3 { ratios[c].sort();logs[c]=ratios[c][ratios[c].count/2] }
        let common=max(-log(Float(4)),min(log(Float(4)),(logs.x+logs.y+logs.z)/3))
        let limit=log(Float(1.35))
        return SIMD3(exp(common+max(-limit,min(limit,logs.x-common))),exp(common+max(-limit,min(limit,logs.y-common))),exp(common+max(-limit,min(limit,logs.z-common))))
    }
    /// Minimum-error connected path with |dx|<=1. Holes split the path into
    /// independent valid segments; invalid coverage is never assigned a cost.
    static func minimumSeam(_ costs:[Float],width:Int,height:Int)->[Float] {
        guard width>0,height>0,width<=512,height<=512,costs.count==width*height else { return [] }
        var result=[Float](repeating:Float(width)/2,count:height),previous=[Float](repeating:.infinity,count:width)
        var parent=[Int16](repeating:-1,count:width*height),lastRow = -1
        func finish(_ end:Int,_ scores:[Float]) {
            guard end>=0,let col=scores.indices.min(by:{scores[$0]<scores[$1]}),scores[col].isFinite else { return }
            var x=col,y=end
            while y>=0 { result[y]=Float(x)+0.5;let p=Int(parent[y*width+x]);if p<0 { break };x=p;y-=1 }
        }
        for y in 0..<height {
            var next=[Float](repeating:.infinity,count:width)
            for x in 0..<width where costs[y*width+x].isFinite {
                var best=Float.infinity,index = -1
                for q in max(0,x-1)...min(width-1,x+1) where previous[q]<best { best=previous[q];index=q }
                if index>=0 { next[x]=best+costs[y*width+x];parent[y*width+x]=Int16(index) }
                else if lastRow<0 { next[x]=costs[y*width+x] }
            }
            if !next.contains(where:{$0.isFinite}) {
                if lastRow>=0 { finish(lastRow,previous) };lastRow = -1
                for x in 0..<width where costs[y*width+x].isFinite { next[x]=costs[y*width+x] }
            }
            if next.contains(where:{$0.isFinite}) { lastRow=y }
            previous=next
        }
        if lastRow>=0 { finish(lastRow,previous) };return result
    }
    private static func shifted(_ image:CIImage,by offset:Double,extent:CGRect) throws -> CIImage {
        guard abs(offset)>0.0001 else { return image }
        guard let result=rollKernel?.apply(extent:extent,roiCallback:{_,_ in extent},arguments:[image,offset,Double(extent.width)]) else { throw CameraFailure.message("No se pudo unir el meridiano.") };return result
    }
    private static let rollKernel=CIKernel(source:"""
     kernel vec4 roll(sampler image,float offset,float width) {
      vec2 p=destCoord();p.x=mod(p.x-offset,width);return sample(image,samplerTransform(image,p));
     }
     """)
    private static let maskKernel=CIKernel(source:"""
     kernel vec4 seamMasks(sampler path,sampler a,sampler b,vec2 size,float cols,float rows,float horizontal,float positive,float radius) {
      vec2 p=destCoord();float along=mix(p.x/size.x,p.y/size.y,horizontal);
      float across=mix(p.y,p.x,horizontal),length=mix(size.y,size.x,horizontal);
      float cut=sample(path,samplerTransform(path,vec2(0.5,clamp(along*rows,0.5,rows-0.5)))).r*length/cols;
      float distance=(across-cut)*(positive>0.5 ? 1.0:-1.0);
      float av=sample(a,samplerCoord(a)).r,bv=sample(b,samplerCoord(b)).r;
      float lo=smoothstep(-radius,radius,distance),hi=smoothstep(-1.5,1.5,distance);
      if(av<0.001) {lo=1.0;hi=1.0;} if(bv<0.001) {lo=0.0;hi=0.0;}
      return vec4(lo,hi,0.0,1.0);
     }
     """)
    private static let coverageKernel=CIColorKernel(source:"kernel vec4 coverage(__sample a,__sample b) {return vec4(vec3(max(a.r,b.r)),1.0);}")
    private static let productKernel=CIColorKernel(source:"kernel vec4 weighted(__sample a,__sample w) {return vec4(unpremultiply(a).rgb*w.r,1.0);}")
    private static let divideKernel=CIColorKernel(source:"kernel vec4 normalized(__sample a,__sample w) {return vec4(a.rgb/max(w.r,0.00001),1.0);}")
    private static let blendKernel=CIColorKernel(source:"""
     kernel vec4 twoBand(__sample a,__sample b,__sample al,__sample bl,__sample m,__sample aw,__sample bw) {
      vec3 av=unpremultiply(a).rgb,bv=unpremultiply(b).rgb;
      vec3 color=mix(al.rgb,bl.rgb,m.r)+mix(av-al.rgb,bv-bl.rgb,m.g);
      if(aw.r<0.001) color=bv;if(bw.r<0.001) color=av;
      float valid=max(aw.r,bw.r)>0.001 ? 1.0:0.0;return vec4(max(color,vec3(0.0))*valid,valid);
     }
     """)
}
