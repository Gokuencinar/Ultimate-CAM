import Foundation
import CoreImage

enum LensIdentity:String,Codable,CaseIterable { case ultraWide,wide,telephoto,front }
struct LensCalibration {
    let shot:Float,read:Float,sharpenRadius:Double,chroma:Double,microContrast:Double,shadowChroma:Float
    // Conservative unmeasured priors. Embedded DNG NoiseProfile takes priority;
    // these numbers are not presented as a laboratory calibration of this unit.
    static func profile(_ lens:LensIdentity)->Self {
        switch lens {
        case .wide:return Self(shot:1,read:1,sharpenRadius:0.8,chroma:0.08,microContrast:0,shadowChroma:0.002)
        case .ultraWide:return Self(shot:1.35,read:1.8,sharpenRadius:1.15,chroma:0.18,microContrast:0.08,shadowChroma:0.0035)
        case .telephoto:return Self(shot:1.2,read:1.4,sharpenRadius:0.95,chroma:0.12,microContrast:0.04,shadowChroma:0.0028)
        case .front:return Self(shot:1.45,read:1.9,sharpenRadius:1.05,chroma:0.2,microContrast:0.03,shadowChroma:0.004)
        }
    }
    func recipe(_ supplied:ProcessingOptions)->ProcessingOptions {
        guard supplied.lensCorrections else { return supplied }
        var result=supplied
        if supplied.sharpenRadius==1 { result.sharpenRadius=sharpenRadius }
        if supplied.chromaDenoise==0 { result.chromaDenoise=chroma }
        if supplied.localContrast==0 { result.localContrast=microContrast }
        return result
    }
    static func correct(_ image:CIImage,lens:LensIdentity,context:CIContext)->CIImage {
        guard lens == .ultraWide else { return image }
        let e=image.extent,s=min(1,384/e.width),w=max(4,Int(e.width*s)),h=max(4,Int(e.height*s))
        let small=image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY)).transformed(by:CGAffineTransform(scaleX:CGFloat(w)/e.width,y:CGFloat(h)/e.height))
        var rgb=[Float](repeating:0,count:w*h*4)
        rgb.withUnsafeMutableBytes { context.render(small,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!) }
        func sample(_ x:Double,_ y:Double,_ c:Int)->Double {
            let x=min(Double(w-2),max(0,x)),y=min(Double(h-2),max(0,y)),ix=Int(x),iy=Int(y),fx=x-Double(ix),fy=y-Double(iy)
            let a=Double(rgb[(iy*w+ix)*4+c]),b=Double(rgb[(iy*w+ix+1)*4+c]),d=Double(rgb[((iy+1)*w+ix)*4+c]),f=Double(rgb[((iy+1)*w+ix+1)*4+c])
            return (a*(1-fx)+b*fx)*(1-fy)+(d*(1-fx)+f*fx)*fy
        }
        func cost(_ scale:Double,_ c:Int)->(Double,Int) {
            var total=0.0,count=0
            for y in stride(from:4,to:h-4,by:3) { for x in stride(from:4,to:w-4,by:3) {
                let nx=(Double(x)-Double(w)/2)/(Double(w)/2),ny=(Double(y)-Double(h)/2)/(Double(h)/2)
                if nx*nx+ny*ny<0.3 { continue }
                let g=sample(Double(x),Double(y),1),v=sample(Double(x),Double(y),c)
                if g<0.04 || g>0.9 || abs(v-g)>g*0.25 { continue }
                let gg=sample(Double(x+1),Double(y),1)-sample(Double(x-1),Double(y),1)
                let gy=sample(Double(x),Double(y+1),1)-sample(Double(x),Double(y-1),1)
                if abs(gg)+abs(gy)<0.03 { continue }
                let qx=Double(w)/2+(Double(x)-Double(w)/2)*(1+scale),qy=Double(h)/2+(Double(y)-Double(h)/2)*(1+scale)
                let cg=sample(qx+1,qy,c)-sample(qx-1,qy,c),cy=sample(qx,qy+1,c)-sample(qx,qy-1,c)
                total+=min(0.05,(cg-gg)*(cg-gg)+(cy-gy)*(cy-gy));count+=1
            } }
            return (total/Double(max(1,count)),count)
        }
        func fit(_ c:Int)->Double {
            let baseline=cost(0,c);guard baseline.1>=64 else { return 0 }
            var best=baseline.0,choice=0.0
            for index in -3...3 { let scale=Double(index)*0.0005,value=cost(scale,c)
                if value.1==baseline.1 && value.0<best { best=value.0;choice=scale }
            }
            return best<baseline.0*0.92 ? choice:0
        }
        let red=fit(0),blue=fit(2)
        guard red != 0 || blue != 0,let kernel=caKernel,
              let output=kernel.apply(extent:e,roiCallback:{_,r in r.insetBy(dx:-12,dy:-12)},arguments:[image.clampedToExtent(),CIVector(x:e.midX,y:e.midY),red,blue]) else { return image }
        return output.cropped(to:e)
    }
    private static let caKernel=CIKernel(source:"""
     kernel vec4 lateralCA(sampler image,vec2 center,float red,float blue) {
      vec2 p=destCoord();vec4 g=sample(image,samplerCoord(image));
      float r=sample(image,samplerTransform(image,center+(p-center)*(1.0+red))).r;
      float b=sample(image,samplerTransform(image,center+(p-center)*(1.0+blue))).b;
      return vec4(r,g.g,b,g.a);
     }
     """)
}
