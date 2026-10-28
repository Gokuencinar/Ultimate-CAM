import Foundation
import CoreImage
import ImageIO
import Metal
import Darwin

/// Executes the shipping RAW pipeline, including real flow estimation, fusion,
/// DNG, demosaic, tone and JPEG. Optical metrics use the linear fused mosaic,
/// before tone/gamma/sharpening can hide lost detail or inflate a PSNR result.
@main struct MetalGPUChecks {
    static let w=160,h=128
    static let calibration=BayerCalibration(pattern:[0,1,1,2],matrix:[3.2406,-1.5372,-0.4986,-0.9689,1.8758,0.0415,0.0557,-0.204,1.057],neutral:[1,1,1],illuminant:21,orientation:1)
    static func require(_ value:Bool,_ message:String) throws { if !value { throw CameraFailure.message(message) } }
    struct Random {
        var state:UInt64
        mutating func uniform()->Double { state=state &* 6364136223846793005 &+ 1442695040888963407;return (Double(state>>11)+0.5)/9007199254740992 }
        mutating func normal()->Double { sqrt(-2*log(uniform()))*cos(2*Double.pi*uniform()) }
        // Exact Poisson: inversion for small means, transformed rejection for
        // large means (Hörmann PTRS); no Gaussian approximation of photon count.
        mutating func poisson(_ lambda:Double)->Double {
            if lambda<=0 { return 0 }
            if lambda<10 { let limit=exp(-lambda);var product=1.0,k=0;repeat { k+=1;product*=uniform() } while product>limit;return Double(k-1) }
            let root=sqrt(lambda),b=0.931+2.53*root,a = -0.059+0.02483*b
            let inverse=1.1239+1.1328/(b-3.4),quick=0.9277-3.6224/(b-2)
            while true {
                let u=uniform()-0.5,v=uniform(),us=0.5-abs(u)
                let k=floor((2*a/us+b)*u+lambda+0.43)
                if k>=0 && us>=0.07 && v<=quick { return k }
                if k<0 || (us<0.013 && v>us) { continue }
                if log(v*inverse/(a/(us*us)+b))<=(-lambda+k*log(lambda)-lgamma(k+1)) { return k }
            }
        }
    }
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("Full RAW GPU check failed: \(error)\n",stderr);exit(1) }
    }
    static func run() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw CameraFailure.message("A real Metal GPU is required; these checks cannot be reported as passed without execution.") }
        let header=try String(contentsOfFile:"Sources/FusionMath.h",encoding:.utf8)
        let source=try String(contentsOfFile:"Sources/ComputationalCamera.metal",encoding:.utf8).replacingOccurrences(of:"#include \"FusionMath.h\"",with:header)
        let library=try device.makeLibrary(source:source,options:nil)
        try sensorStages(device,library)
        let processor=try MetalBurstProcessor(device:device,library:library)
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        print("Full processRAW GPU:",device.name)
        var options=ProcessingOptions();options.nightStatic=true;options.nightRAW=true;options.nightMetalRAW=true;options.saveFusedDNG=true;options.lensCorrections=false
        let reference=try JPEGRenderer.render(CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:w*2,height:h*2)),extent:CGRect(x:0,y:0,width:w*2,height:h*2),options:options,context:context).data
        func result(_ frames:[SensorBayerFrame],_ recipe:ProcessingOptions,engine:MetalBurstProcessor?=nil) throws -> CaptureResult {
            let original=try FusedDNG.encode(quads:frames[0].quads,width:w,height:h,calibration:calibration)
            let output=try (engine ?? processor).processRAW(frames,referenceJPEG:reference,originalDNG:original,options:recipe,cancellation:nil,progress:nil)
            try require(output.source=="Bayer-Metal" && output.mergedFrames==frames.count && output.rawIsFused && !output.jpeg.isEmpty,"The full RAW pipeline fell back or bypassed fusion")
            return output
        }
        func execute(_ frames:[SensorBayerFrame],_ recipe:ProcessingOptions,engine:MetalBurstProcessor?=nil) throws -> Mosaic {
            guard let data=try result(frames,recipe,engine:engine).raw else { throw CameraFailure.message("Missing GPU-produced DNG") };return try Mosaic(data)
        }
        let edge:(Double,Double)->Double={ x,y in 0.055+0.24*(0.5+0.5*tanh((x-Double(w)*0.51-0.18*(y-Double(h)/2))/0.65)) }
        let noise=[0.0001,0.000002]
        let night=makeFrames(count:8,noise:noise,scene:edge)
        let merged=try execute(night,options)
        let original=halfValues(night[0].quads)
        let singleError=mse(original,width:w,height:h,scene:edge,x:12..<52,y:12..<h-12)
        let fusedError=mse(merged.values,width:w,height:h,scene:edge,x:12..<52,y:12..<h-12)
        let improvement=10*log10(singleError/fusedError)
        let sourceMTF=mtf50(original),fusedMTF=mtf50(merged.values)
        print(String(format:"8-frame PSNR gain %.3f dB; slanted-edge MTF50 %.4f -> %.4f cycles/quad",improvement,sourceMTF,fusedMTF))
        try require(improvement>=6,"Eight-frame physical-noise RAW fusion gained only \(improvement) dB")
        try require(fusedMTF>=sourceMTF*0.9,"Night fusion degraded slanted-edge MTF50")
        let shifts:[SIMD2<Double>]=[SIMD2(0,0),SIMD2(0.25,0.5),SIMD2(0.5,0.25),SIMD2(0.75,0.75),SIMD2(0.5,0.75),SIMD2(0.75,0.25)]
        let lines:(Double,Double)->Double={ x,y in 0.32+0.13*cos(2*Double.pi*(0.61*x+0.13*y))+0.04*sin(x*0.37)*cos(y*0.41) }
        let burst=makeFrames(count:6,noise:[0.000002,0.0000001],shifts:shifts,zoom:2,scene:lines)
        let isotropicEngine=try MetalBurstProcessor(device:device,library:library,directionalSuperResolution:false)
        let isotropic=try execute(burst,options,engine:isotropicEngine)
        let superRes=try execute(burst,options),plan=try SuperResolutionPlan.make(burst[0],count:6)!
        try require(superRes.width==w && superRes.height==h,"2x reconstruction did not exceed the simple crop resolution")
        let baseline=halfValues(burst[0].quads)
        var srError=0.0,isotropicError=0.0,bilinearError=0.0,srContrast=0.0,isotropicContrast=0.0,bilinearContrast=0.0,energy=0.0
        for y in 8..<h-8 { for x in 8..<w-8 {
            let px=plan.originX+(Double(x)+0.25)/plan.scaleX,py=plan.originY+(Double(y)+0.25)/plan.scaleY
            let truth=lines(px,py),i=(y*w+x)*4
            let resized=bilinear(baseline,x:px-0.25,y:py-0.25)
            let value=Double(superRes.values[i]),carrier=cos(2*Double.pi*(0.61*px+0.13*py))
            srError+=pow(value-truth,2);isotropicError+=pow(Double(isotropic.values[i])-truth,2);bilinearError+=pow(resized-truth,2)
            srContrast+=(value-0.32)*carrier;isotropicContrast+=(Double(isotropic.values[i])-0.32)*carrier;bilinearContrast+=(resized-0.32)*carrier;energy+=carrier*carrier
        } }
        print(String(format:"Full SR MSE ratio %.4f; recovered HF contrast %.4f vs bilinear %.4f",srError/bilinearError,srContrast/energy,bilinearContrast/energy))
        try require(srError<bilinearError && srContrast>bilinearContrast,"Full RAW alignment + SR did not beat a single-frame bilinear crop")
        print(String(format:"Directional SR MSE / isotropic %.4f; HF contrast %.4f / %.4f",srError/isotropicError,srContrast/energy,isotropicContrast/energy))
        try require(srError<=isotropicError*1.05 && srContrast>=isotropicContrast*0.98,"Directional reconstruction regressed against the isotropic production path")
        let edgeBurst=makeFrames(count:6,noise:[0.000002,0.0000001],shifts:shifts,zoom:2,scene:edge)
        let sharpEdge=try execute(edgeBurst,options),roundEdge=try execute(edgeBurst,options,engine:isotropicEngine)
        let edgeDirectional=mtf50(sharpEdge.values),edgeIsotropic=mtf50(roundEdge.values)
        print(String(format:"SR diagonal-edge MTF50 directional %.4f / isotropic %.4f",edgeDirectional,edgeIsotropic))
        try require(edgeDirectional>=edgeIsotropic*1.025,"Directional SR did not improve slanted-edge acutance")
        var hdr=options;hdr.nightStatic=false;hdr.nightRAW=false;hdr.nightMetalRAW=false;hdr.hdrBracketing=true;hdr.hdrMetalRAW=true
        let hdrScene:(Double,Double)->Double={ x,y in x<Double(w)*0.45 ? 0.003:0.65+0.08*sin(y*0.3) }
        let bracket=makeFrames(count:3,noise:noise,exposures:[1,4,16],scene:hdrScene)
        let radiance=try execute(bracket,hdr),short=halfValues(bracket[0].quads)
        let rawShadow=mse(short,width:w,height:h,scene:hdrScene,x:10..<55,y:12..<h-12)
        let hdrShadow=mse(radiance.values,width:w,height:h,scene:hdrScene,x:10..<55,y:12..<h-12)
        let lightError=mse(radiance.values,width:w,height:h,scene:hdrScene,x:100..<w-12,y:12..<h-12)
        print(String(format:"HDR shadow PSNR gain %.3f dB; highlight RMSE %.6f",10*log10(rawShadow/hdrShadow),sqrt(lightError)))
        try require(hdrShadow<rawShadow*0.65 && sqrt(lightError)<0.02,"HDR failed simultaneous shadows / non-clipped highlights")
        // Compare residual mean across adjacent tiles, away from a real edge.
        var worstSeam=0.0
        for x in stride(from:24,to:56,by:16) {
            var left=0.0,right=0.0
            for y in 12..<h-12 { left+=Double(radiance.values[(y*w+x-1)*4])-0.003;right+=Double(radiance.values[(y*w+x)*4])-0.003 }
            worstSeam=max(worstSeam,abs(left-right)/Double(h-24))
        }
        try require(worstSeam<0.002,"HDR created a systematic tile seam")
        let sky:(Double,Double)->Double={ x,y in
            let star=0.55*exp(-(pow(x-41.25,2)+pow(y-61.25,2))/(2*0.32*0.32))
            return 0.015+star+0.015*exp(-(pow(x-110.25,2)+pow(y-83.25,2))/2)
        }
        var stars=makeFrames(count:8,noise:[0.000001,0.00000001],scene:sky)
        var first=halfValues(stars[0].quads);first[(40*w+100)*4]=0.9
        stars[0]=SensorBayerFrame(width:w,height:h,quads:pack(first),calibration:calibration,exposure:stars[0].exposure,timestamp:1,noiseProfile:stars[0].noiseProfile,sharpness:100)
        var astro=options;astro.astroCapture=true
        let celestial=try execute(stars,astro)
        let star=celestial.values[(61*w+41)*4],hot=celestial.values[(40*w+100)*4]
        print("Full Astro star / single-frame hot pixel:",star,hot)
        try require(star>0.4 && hot<0.05,"End-to-end Astro erased a consistent point or preserved an isolated hot pixel")
        var moving=makeFrames(count:4,noise:[1e-6,4e-6],scene:{_,_ in 0.15})
        for index in 1..<moving.count {
            let old=moving[index];var values=halfValues(old.quads)
            for y in 35..<65 { for x in 50..<80 { values[(y*w+x)*4]+=0.02 } }
            moving[index]=SensorBayerFrame(width:w,height:h,quads:pack(values),calibration:calibration,exposure:old.exposure,timestamp:old.timestamp,noiseProfile:old.noiseProfile,sharpness:old.sharpness)
        }
        var strict=options;strict.motionSigma=1.5;var tolerant=options;tolerant.motionSigma=6
        let low=try execute(moving,strict),high=try execute(moving,tolerant)
        var lowMean=0.0,highMean=0.0
        for y in 42..<58 { for x in 58..<72 { let j=(y*w+x)*4;lowMean+=Double(low.values[j]);highMean+=Double(high.values[j]) } }
        let motionDifference=(highMean-lowMean)/Double(16*14)
        try require(motionDifference>0.0015,"motionSigma did not control real temporal Bayer rejection")
        let toneBurst=makeFrames(count:4,noise:[1e-7,1e-8],scene:{ x,y in 0.025+0.008*sin(x*0.8)*cos(y*0.3) })
        let neutral=try result(toneBurst,options)
        var shadows=options;shadows.liftShadows=0.8
        let lifted=try result(toneBurst,shadows)
        var detail=options;detail.fineDetail=1
        let detailed=try result(toneBurst,detail)
        let a=try jpegPixels(neutral.jpeg,context),b=try jpegPixels(lifted.jpeg,context),c=try jpegPixels(detailed.jpeg,context)
        var shadowDelta=0.0,detailDelta=0.0
        for j in stride(from:0,to:a.count,by:4) {
            shadowDelta+=Double(b[j+1]-a[j+1]);detailDelta+=abs(Double(c[j+1]-a[j+1]))
        }
        shadowDelta/=Double(a.count/4);detailDelta/=Double(a.count/4)
        print("GPU patcher motion / shadows / detail deltas",motionDifference,shadowDelta,detailDelta)
        try require(shadowDelta>0.015 && detailDelta>0.0005,"RAW GPU shadow/detail controls were not reflected in the developed export")
        try clippedNight(processor,context:context,options:options,reference:reference)
        print("FULL RAW GPU QUANTITATIVE CHECKS PASSED (synthetic sensor; no physical camera opened)")
    }
    static func clippedNight(_ processor:MetalBurstProcessor,context:CIContext,options:ProcessingOptions,reference:Data) throws {
        // A physically consistent D65 sensor with non-unit camera WB: the
        // color-matrix rows and AsShotNeutral describe the same CFA response.
        let n:[Double]=[0.5,1,0.65]
        var c=calibration
        c=BayerCalibration(pattern:c.pattern,matrix:c.matrix.enumerated().map{$0.element*n[$0.offset/3]},neutral:n,illuminant:21,orientation:1)
        let phase:[Float]=[0.5,1,1,0.65]
        let burst=(0..<4).map { i -> SensorBayerFrame in
            var values=[Float](repeating:0,count:w*h*4)
            for y in 0..<h { for x in 0..<w { for channel in 0..<4 {
                let j=(y*w+x)*4+channel
                values[j]=(x>90 && x<145 && y>30 && y<95) ? 1:phase[channel]*0.025
            } } }
            return SensorBayerFrame(width:w,height:h,quads:pack(values),calibration:c,exposure:FrameExposure(seconds:0.1,iso:400),timestamp:Double(i+1),noiseProfile:[1e-7,1e-8],sharpness:i==0 ? 100:1)
        }
        let original=try FusedDNG.encode(quads:burst[0].quads,width:w,height:h,calibration:c)
        let result=try processor.processRAW(burst,referenceJPEG:reference,originalDNG:original,options:options,cancellation:nil,progress:nil)
        try require(result.source=="Bayer-Metal" && result.rawIsFused,"Clipped-night test bypassed the production RAW pipeline")
        let pixels=try jpegPixels(result.jpeg,context),width=w*2
        func mean(_ xs:Range<Int>,_ ys:Range<Int>)->SIMD3<Float> {
            var sum=SIMD3<Float>.zero
            for y in ys { for x in xs { let j=(y*width+x)*4;sum+=SIMD3(pixels[j],pixels[j+1],pixels[j+2]) } }
            return sum/Float(xs.count*ys.count)
        }
        let white=mean(205..<265,85..<165),dark=mean(30..<110,50..<200)
        print("Non-unit camera WB night white / midtone",white,dark)
        try require(abs(white.x-white.y)<0.05 && abs(white.z-white.y)<0.05,"Saturated night whites developed pink/magenta")
        try require(white.y>0.4 && dark.y<0.35 && dark.y>0.005,"Night tone washed dark midtones to white or crushed them")
        try require(abs(dark.x-dark.y)<0.025 && abs(dark.z-dark.y)<0.025,"Night tone introduced a magenta shadow cast")
        guard let raw=result.raw else { throw CameraFailure.message("Missing bounded night DNG") }
        let mosaic=try Mosaic(raw)
        try require(mosaic.values.allSatisfy{$0>=0 && $0<=1},"Fused DNG exceeded declared sensor white")
    }
    static func jpegPixels(_ data:Data,_ context:CIContext) throws -> [Float] {
        guard let image=CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("Cannot read GPU tone fixture") }
        let e=image.extent,w=Int(e.width),h=Int(e.height);var values=[Float](repeating:0,count:w*h*4)
        values.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:e,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) };return values
    }
    static func sensorStages(_ device:MTLDevice,_ library:MTLLibrary) throws {
        let queue=device.makeCommandQueue()!,width=64,height=48
        func texture()->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite];return device.makeTexture(descriptor:d)!
        }
        func execute(_ name:String,_ values:[Float],_ params:MetalFusionParameters) throws -> [Float] {
            let input=texture(),output=texture(),halves=values.map{Float16($0).bitPattern}
            halves.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*8) }
            let state=try device.makeComputePipelineState(function:library.makeFunction(name:name)!)
            let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(state);encoder.setTexture(input,index:0);encoder.setTexture(output,index:1)
            var p=params;encoder.setBytes(&p,length:MemoryLayout<MetalFusionParameters>.stride,index:0)
            encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            try require(command.status == .completed,"Sensor stage failed on the GPU")
            var result=[UInt16](repeating:0,count:width*height*4)
            result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*8,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            return result.map{Float(Float16(bitPattern:$0))}
        }
        var p=MetalFusionParameters();p.size.w=1;p.flags.w=1;p.luma=SIMD4(0,0.5,0.5,0);p.sensorNoise=SIMD4(0,1e-5,0,1e-5)
        var bayer=[Float](repeating:0,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let j=(y*width+x)*4,base:Float=x<32 ? 0.2:0.6
            bayer[j]=base*0.8;bayer[j+1]=base+0.004;bayer[j+2]=base-0.004;bayer[j+3]=base*0.6
        } }
        let green=try execute("uc_protect_bayer",bayer,p),flat=(24*width+16)*4,edge=(24*width+31)*4
        try require(abs(green[flat+1]-green[flat+2])<0.001,"Uniform green phases were not balanced")
        try require(abs(green[edge+1]-green[edge+2])>0.006 && abs(green[edge+1]-bayer[edge+1])<0.001,"Green equilibration erased an edge")
        var rgb=[Float](repeating:1,count:width*height*4)
        for j in stride(from:0,to:rgb.count,by:4) { rgb[j]=0.5;rgb[j+1]=0.4;rgb[j+2]=0.25 }
        let center=(24*width+32)*4;rgb[center]=1;rgb[center+1]=0.9;rgb[center+2]=0.5625
        let recovered=try execute("uc_reconstruct_highlights",rgb,p)
        try require(recovered[center]<=1 && abs(recovered[center]-1)<0.001 && recovered.allSatisfy{$0>=0 && $0<=1},"Highlight protection invented unsupported red/blue energy")
        try require(abs(recovered[center+1]-0.9)<0.001 && recovered[flat]==Float(Float16(0.5)),"Highlight reconstruction changed supported channels / shadows")
        print("GPU green phases / edge preservation / bounded highlights passed")
    }
    static func makeFrames(count:Int,noise:[Double],shifts:[SIMD2<Double>]=[],exposures:[Double]=[],zoom:Double=1,scene:(Double,Double)->Double)->[SensorBayerFrame] {
        (0..<count).map { index in
            var random=Random(state:UInt64(index+1)*9348721),values=[Float](repeating:0,count:w*h*4)
            let shift=shifts.isEmpty ? SIMD2<Double>.zero:shifts[index],scale=exposures.isEmpty ? 1:exposures[index]
            for y in 0..<h { for x in 0..<w { for c in 0..<4 {
                let px=Double(x)+Double(c%2)*0.5+0.25-shift.x,py=Double(y)+Double(c/2)*0.5+0.25-shift.y
                let signal=min(1,max(0,scene(px,py)*scale))
                let measured=noise[0]*random.poisson(signal/noise[0])+sqrt(noise[1])*random.normal()
                values[(y*w+x)*4+c]=Float(min(1,measured))
            } } }
            return SensorBayerFrame(width:w,height:h,quads:pack(values),calibration:calibration,exposure:FrameExposure(seconds:0.01*scale,iso:400),timestamp:Double(index+1),noiseProfile:noise,sharpness:index==0 ? 100:1,zoom:zoom)
        }
    }
    static func pack(_ values:[Float])->Data { values.map{Float16($0).bitPattern.littleEndian}.withUnsafeBufferPointer{Data(buffer:$0)} }
    static func halfValues(_ data:Data)->[Float] { data.withUnsafeBytes { $0.bindMemory(to:UInt16.self).map { Float(Float16(bitPattern:UInt16(littleEndian:$0))) } } }
    static func mse(_ values:[Float],width:Int,height:Int,scene:(Double,Double)->Double,x:Range<Int>,y:Range<Int>)->Double {
        var error=0.0,count=0.0
        for row in y { for col in x { for c in 0..<4 {
            let expected=scene(Double(col)+Double(c%2)*0.5+0.25,Double(row)+Double(c/2)*0.5+0.25)
            error+=pow(Double(values[(row*width+col)*4+c])-expected,2);count+=1
        } } };return error/count
    }
    static func bilinear(_ values:[Float],x:Double,y:Double)->Double {
        let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-Double(ix),fy=y-Double(iy)
        let a=Double(values[(iy*w+ix)*4]),b=Double(values[(iy*w+ix+1)*4])
        let c=Double(values[((iy+1)*w+ix)*4]),d=Double(values[((iy+1)*w+ix+1)*4])
        return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
    }
    static func mtf50(_ values:[Float])->Double {
        let bins=160,step=0.1
        var esf=[Double](repeating:0,count:bins),counts=esf
        for y in 10..<h-10 { for x in 0..<w {
            let distance=Double(x)+0.25-Double(w)*0.51-0.18*(Double(y)+0.25-Double(h)/2)
            let bin=Int(floor(distance/step))+bins/2
            if bin>=0 && bin<bins { esf[bin]+=Double(values[(y*w+x)*4]);counts[bin]+=1 }
        } }
        for i in 0..<bins { esf[i]=counts[i]>0 ? esf[i]/counts[i]:(i>0 ? esf[i-1]:0) }
        var lsf=[Double]()
        for i in 1..<(bins-1) { let low:Double=esf[i-1],high:Double=esf[i+1];lsf.append((high-low)*0.5) }
        let dc=lsf.reduce(0,+)
        guard dc>0.1 else { return 0 }
        for index in 1...200 {
            let f=Double(index)/200
            var re=0.0,im=0.0
            for i in lsf.indices { let phase=2*Double.pi*f*Double(i)*step;re+=lsf[i]*cos(phase);im+=lsf[i]*sin(phase) }
            if hypot(re,im)/dc<0.5 { return f }
        };return 1
    }
    struct Mosaic {
        let width:Int,height:Int,values:[Float]
        init(_ data:Data) throws {
            // FusedDNG writes bounded classic TIFF, one contiguous Bayer strip.
            let little=data[0]==0x49
            func u(_ offset:Int,_ count:Int)->Int { (0..<count).reduce(0){$0 | Int(data[offset+$1]) << (8*(little ? $1:count-1-$1))} }
            var pending=[u(4,4)],fields=[Int:(Int,Int,Int)](),visited=Set<Int>()
            while let offset=pending.popLast() {
                guard visited.insert(offset).inserted,visited.count<=8 else { throw CameraFailure.message("Invalid test DNG graph") }
                let count=u(offset,2);var local=[Int:(Int,Int,Int)]()
                for i in 0..<count {
                    let e=offset+2+i*12,tag=u(e,2),type=u(e+2,2),n=u(e+4,4),size=type==3 ? 2:(type==5 ? 8:4)
                    let position=n*size<=4 ? e+8:u(e+8,4)
                    local[tag]=(type,n,position)
                    if tag==330 { pending.append(u(position,4)) }
                }
                if let p=local[262],u(p.2,p.0==3 ? 2:4)==32803 { fields=local }
            }
            func integer(_ tag:Int)->Int { let f=fields[tag]!;return u(f.2,f.0==3 ? 2:4) }
            guard fields[256] != nil,fields[257] != nil,fields[273] != nil,fields[50714] != nil,fields[50717] != nil else { throw CameraFailure.message("Missing fused mosaic tags") }
            width=integer(256)/2;height=integer(257)/2
            let blackOffset=fields[50714]!.2,black=Double(u(blackOffset,4))/Double(u(blackOffset+4,4)),white=Double(integer(50717)),strip=integer(273)
            var pixels=[Float](repeating:0,count:width*height*4)
            for y in 0..<height { for x in 0..<width { for c in 0..<4 {
                let row=y*2+c/2,col=x*2+c%2,value=u(strip+(row*width*2+col)*2,2)
                pixels[(y*width+x)*4+c]=Float((Double(value)-black)/(white-black))
            } } };values=pixels
        }
    }
}
