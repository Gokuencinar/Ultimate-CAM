import Foundation
import CoreImage
import Darwin

enum LensIdentity:String,Codable,CaseIterable { case ultraWide,wide,telephoto,front }
struct LensCalibration {
    let shot:Float,read:Float,sharpenRadius:Double,chroma:Double,microContrast:Double,shadowChroma:Float
    var motionTolerance:Float=1
    var contrastRadius:Double=12
    var aperture:Double=1.8
    var opticalStabilization:Bool=true
    // Optical hardware: Apple iPhone 11 Pro specifications /111879.
    // Relative rear noise floors are anchored to D421 Sushi RAW ISO=100.
    // Front RAW noise remains an unmeasured prior; NRF colour tuning is not a
    // raw variance model and must not be reinterpreted as shot/read coefficients.
    static func profile(_ lens:LensIdentity)->Self {
        switch lens {
        case .wide:return Self(shot:1,read:1,sharpenRadius:0.8,chroma:0.08,microContrast:0,shadowChroma:0.002)
        case .ultraWide:return Self(shot:1.9556,read:2.6995,sharpenRadius:1.1,chroma:0.22,microContrast:0.08,shadowChroma:0.0045,motionTolerance:1.18,contrastRadius:10,aperture:2.4,opticalStabilization:false)
        case .telephoto:return Self(shot:1.9556,read:2.6995,sharpenRadius:0.95,chroma:0.14,microContrast:0.04,shadowChroma:0.0035,motionTolerance:1.10,contrastRadius:12,aperture:2,opticalStabilization:true)
        case .front:return Self(shot:1.45,read:1.9,sharpenRadius:1.05,chroma:0.22,microContrast:0.03,shadowChroma:0.004,motionTolerance:1.15,contrastRadius:10,aperture:2.2,opticalStabilization:false)
        }
    }
    func recipe(_ supplied:ProcessingOptions)->ProcessingOptions {
        guard supplied.lensCorrections else { return supplied };var result=supplied
        if supplied.sharpenRadius==1 { result.sharpenRadius=sharpenRadius }
        if supplied.chromaDenoise==0 { result.chromaDenoise=chroma }
        if supplied.localContrast==0 { result.localContrast=microContrast };return result
    }
    static let platform:String = {
        #if os(iOS) && !targetEnvironment(simulator)
        var count=0;sysctlbyname("hw.machine",nil,&count,nil,0)
        var bytes=[CChar](repeating:0,count:max(1,count))
        sysctlbyname("hw.machine",&bytes,&count,nil,0)
        let hardware=String(cString:bytes)
        return hardware+"/"+(ProcessInfo.processInfo.operatingSystemVersionString.contains("22H31") ? "22H31":"other")
        #else
        return "host"
        #endif
    }()
    /// Device tuning lower bound, not a claim of new per-unit sensor calibration.
    /// The plateau above analogue gain is not extrapolated as an ISO law. Keep
    /// the physical fallback estimate as a floor too; DNG NoiseProfile wins.
    static func vendorFloor(iso:Double,lens:LensIdentity,platform:String=LensCalibration.platform)->SIMD2<Float>? {
        guard platform=="iPhone12,3/22H31",lens != .front,iso.isFinite,iso>0 else { return nil }
        let x=lens == .wide ? wideISO:smallISO,a=lens == .wide ? wideShot:smallShot,b=lens == .wide ? wideRead:smallRead
        let i=x.indices.dropFirst().first(where:{x[$0]>=iso}) ?? x.count-1
        let lower=max(0,i-1),t=min(1,max(0,(log(iso)-log(x[lower]))/max(1e-9,log(x[i])-log(x[lower]))))
        return SIMD2(Float(a[lower]+(a[i]-a[lower])*t),Float(b[lower]+(b[i]-b[lower])*t))
    }
    private static let wideISO:[Double]=[25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600]
    private static let wideShot:[Double]=[2.63781878409e-05, 3.282487849e-05, 4.00830804544e-05, 4.97642771844e-05, 6.313526089289999e-05, 7.783685915040001e-05, 9.62327646289e-05, 0.00011890812024999999, 0.00015144501968999998, 0.00016813790224, 0.000167650704, 0.00016899480004000002, 0.00016792790569, 0.00016855309583999997, 0.00016910141521000001, 0.00016853751683999999, 0.000167624809, 0.00016881545041, 0.00016900780009]
    private static let wideRead:[Double]=[3.56558265625e-07, 4.3431658672899996e-07, 4.7146487668899997e-07, 7.251016378409999e-07, 8.90033749056e-07, 1.1747308225e-06, 1.3591362723999998e-06, 1.8127660321000001e-06, 2.8485000625e-06, 3.4914791025000003e-06, 3.4956659089e-06, 3.5134503363999996e-06, 3.22382025e-06, 3.2119808400000003e-06, 3.2142394089e-06, 3.2181489664000004e-06, 3.2164629025e-06, 3.2200149136e-06, 3.2231020900000003e-06]
    private static let smallISO:[Double]=[16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800]
    private static let smallShot:[Double]=[3.291546384e-05, 4.05444195025e-05, 5.0244422188900006e-05, 6.34498274916e-05, 7.824287024999998e-05, 9.762032809e-05, 0.00012383238400000003, 0.00015309607824, 0.00018819175488999997, 0.00022723753536, 0.00022654464196, 0.00022634299808999998, 0.00022725864000999998, 0.00022695422500000002, 0.00022786204401, 0.00022739433616000002, 0.00022599409561, 0.00022537215376]
    private static let smallRead:[Double]=[3.8938348803599997e-07, 4.5412503654399997e-07, 6.673092721e-07, 8.85464062081e-07, 1.1444506440999998e-06, 1.4363543104e-06, 1.8978368643999998e-06, 2.9323822564000004e-06, 3.6691019401e-06, 4.982716840000001e-06, 5.024456740899999e-06, 5.028492304900001e-06, 5.03643364e-06, 5.0170176169e-06, 5.0235153424000005e-06, 5.0311835809e-06, 5.103035820100001e-06, 5.0712337636000005e-06]

    static func correct(_ image:CIImage,lens:LensIdentity,context:CIContext)->CIImage {
        LensChromaticPlan.estimate(image,lens:lens,context:context).apply(image)
    }
}

/// A bounded radial r²/r⁴ channel warp estimated from neutral image edges.
/// Apple's ChromaticDefringing parameters describe colour suppression, not
/// R/B displacement; they are deliberately not copied into these coefficients.
struct LensChromaticPlan {
    var red=SIMD2<Double>.zero,blue=SIMD2<Double>.zero
    var center=SIMD2<Double>(0.5,0.5)
    var active:Bool { abs(red.x)+abs(red.y)+abs(blue.x)+abs(blue.y)>1e-9 }
    var coefficients:SIMD4<Float> { SIMD4(Float(red.x),Float(red.y),Float(blue.x),Float(blue.y)) }
    func geometry(_ extent:CGRect)->SIMD4<Float> {
        let cx=extent.minX+extent.width*center.x,cy=extent.minY+extent.height*center.y
        let rx=max(abs(cx-extent.minX),abs(extent.maxX-cx)),ry=max(abs(cy-extent.minY),abs(extent.maxY-cy))
        return SIMD4(Float(cx),Float(cy),Float(hypot(rx,ry)),1)
    }
    static func estimate(_ image:CIImage,lens:LensIdentity,context:CIContext,center:SIMD2<Double>?=nil)->Self {
        var plan=Self();if let center,center.x.isFinite,center.y.isFinite { plan.center=center }
        guard lens == .wide || lens == .ultraWide else { return plan }
        let e=image.extent,factor=min(1,512/max(e.width,e.height))
        let w=max(8,Int(e.width*factor)),h=max(8,Int(e.height*factor))
        let thumbnail=image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY)).transformed(by:CGAffineTransform(scaleX:CGFloat(w)/e.width,y:CGFloat(h)/e.height))
        var pixels=[Float](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { context.render(thumbnail,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) }
        func sample(_ x:Double,_ y:Double,_ c:Int)->Double {
            let px=min(Double(w-2),max(1,x)),py=min(Double(h-2),max(1,y))
            let ix=Int(px),iy=Int(py),fx=px-Double(ix),fy=py-Double(iy)
            let top=iy*w,bottom=(iy+1)*w
            let a=Double(pixels[(top+ix)*4+c]),b=Double(pixels[(top+ix+1)*4+c])
            let d=Double(pixels[(bottom+ix)*4+c]),f=Double(pixels[(bottom+ix+1)*4+c])
            return (a*(1-fx)+b*fx)*(1-fy)+(d*(1-fx)+f*fx)*fy
        }
        let cx=Double(w)*plan.center.x,cy=Double(h)*plan.center.y
        let radius=hypot(max(abs(cx),abs(Double(w)-cx)),max(abs(cy),abs(Double(h)-cy)))
        var points=[SIMD2<Double>]()
        for y in stride(from:4,to:h-4,by:2) { for x in stride(from:4,to:w-4,by:2) {
            let g=sample(Double(x),Double(y),1),r=sample(Double(x),Double(y),0),b=sample(Double(x),Double(y),2)
            let dx=Double(x)-cx,dy=Double(y)-cy,r2=(dx*dx+dy*dy)/(radius*radius)
            let gradient=abs(sample(Double(x+1),Double(y),1)-sample(Double(x-1),Double(y),1))+abs(sample(Double(x),Double(y+1),1)-sample(Double(x),Double(y-1),1))
            if r2>0.2 && g>0.04 && g<0.85 && abs(r-g)<0.3*g && abs(b-g)<0.3*g && gradient>0.05 { points.append(SIMD2(Double(x),Double(y))) }
        } }
        guard points.count>=96 else { return plan }
        let limit=(lens == .ultraWide ? 3.0:1.5)/max(1,hypot(Double(e.width),Double(e.height))*0.5)
        func fit(_ channel:Int)->SIMD2<Double> {
            func evaluation(_ k:SIMD2<Double>,_ parity:Int)->Double {
                var sum=0.0,n=0
                for (i,p) in points.enumerated() where i%2==parity {
                    let d=p-SIMD2(cx,cy),r2=(d.x*d.x+d.y*d.y)/(radius*radius)
                    let scale=k.x*r2+k.y*r2*r2,q=p+d*scale
                    let delta=sample(q.x,q.y,channel)-sample(p.x,p.y,1)
                    sum+=min(0.01,delta*delta);n+=1
                };return sum/Double(max(1,n))
            }
            var k=SIMD2<Double>.zero
            for _ in 0..<5 {
                var aa=0.0,ab=0.0,bb=0.0,ta=0.0,tb=0.0
                for (index,p) in points.enumerated() where index%2==0 {
                    let d=p-SIMD2(cx,cy),r2=(d.x*d.x+d.y*d.y)/(radius*radius)
                    let q=p+d*(k.x*r2+k.y*r2*r2)
                    let gx=(sample(q.x+0.5,q.y,channel)-sample(q.x-0.5,q.y,channel)),gy=(sample(q.x,q.y+0.5,channel)-sample(q.x,q.y-0.5,channel))
                    let residual=sample(q.x,q.y,channel)-sample(p.x,p.y,1)
                    let derivative=gx*d.x+gy*d.y,a=derivative*r2,b=derivative*r2*r2
                    let weight=1/max(1,abs(residual)/0.02)
                    aa+=weight*a*a;ab+=weight*a*b;bb+=weight*b*b;ta-=weight*a*residual;tb-=weight*b*residual
                }
                let damping=max(1e-8,(aa+bb)*0.001);aa+=damping;bb+=damping
                let determinant=aa*bb-ab*ab
                if determinant<1e-10 { return .zero }
                let update=SIMD2((bb*ta-ab*tb)/determinant,(aa*tb-ab*ta)/determinant)
                k+=update;k.x=min(limit,max(-limit,k.x));k.y=min(limit,max(-limit,k.y))
                let magnitude=abs(k.x)+abs(k.y)
                if magnitude>limit { k*=limit/magnitude }
                if abs(update.x)+abs(update.y)<1e-7 { break }
            }
            let before=evaluation(.zero,1),after=evaluation(k,1)
            return after<before*0.9 && before>1e-7 ? k:.zero
        }
        plan.red=fit(0);plan.blue=fit(2);return plan
    }
    func apply(_ image:CIImage)->CIImage {
        guard active,let kernel=Self.kernel else { return image }
        let e=image.extent,g=geometry(e)
        return kernel.apply(extent:e,roiCallback:{_,r in r.insetBy(dx:-6,dy:-6)},arguments:[image.clampedToExtent(),CIVector(x:CGFloat(g.x),y:CGFloat(g.y)),Double(g.z),red.x,red.y,blue.x,blue.y])?.cropped(to:e) ?? image
    }
    private static let kernel=CIKernel(source:"""
     kernel vec4 lensRadialCA(sampler image,vec2 center,float radius,float r2,float r4,float b2,float b4) {
      vec2 p=destCoord(),d=p-center;float rr=dot(d,d)/(radius*radius);
      vec4 g=sample(image,samplerCoord(image));
      float r=sample(image,samplerTransform(image,p+d*(r2*rr+r4*rr*rr))).r;
      float b=sample(image,samplerTransform(image,p+d*(b2*rr+b4*rr*rr))).b;
      return vec4(r,g.g,b,g.a);
     }
     """)
}
