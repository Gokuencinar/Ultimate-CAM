import CoreImage
import Foundation
import ImageIO
import Darwin

@main struct ComputationalChecks {
    static func require(_ condition:Bool,_ message:String) throws {
        if !condition { throw CameraFailure.message(message) }
    }
    static func main() {
        setbuf(stdout,nil)
        do {
            print("Core format: bounded ring")
            let ring=TemporalFrameBuffer<Int>(capacity:4,maximumBytes:10)
            ring.append(1,time:1,bytes:4);ring.append(2,time:1.1,bytes:4);ring.append(3,time:1.2,bytes:4)
            try require(ring.snapshot(at:1.15).map(\.value)==[2],"Pre-shutter ownership/budget failed")
            try require(ring.snapshot(at:2).isEmpty,"Expired frames survived")
            ring.append(4,time:1.05,bytes:4)
            try require(ring.snapshot(at:1.1).map(\.value)==[4],"Clock regression mixed capture generations")
            ring.reset();try require(ring.snapshot(at:2).isEmpty,"Reset retained frames")
            print("Core format: motion")
            let meter=PreviewMotionMeter()
            meter.append([Float](repeating:0.2,count:64*48),time:1)
            meter.append([Float](repeating:0.2,count:64*48),time:1.1)
            try require(meter.estimate(at:1.2)==nil,"Textureless metering claimed stability")
            print("Core format: exposure")
            let plan=try NightCapturePlan.make(iso:400,seconds:1.0/30,isoRange:25...6400,durationRange:0.0001...1,budget:8,shutterLimit:1,motionLimit:1.0/250)
            try require(plan.seconds<=1.0/250 && plan.count<=16,"Motion cap did not constrain night exposure")
            var options=ProcessingOptions();options.zeroShutterLagFusion=true;options.nightStatic=true;options.nightRAW=true;options.nightMetalRAW=true
            try require(try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(options))==options,"New recipe fields did not persist")
            _=try options.validated()
            options.nightRAW=false
            var refused=false;do { _=try options.validated() } catch { refused=true }
            try require(refused,"Metal accepted a non-RAW recipe")
            print("Core format: DNG writer")
            let calibration=BayerCalibration(pattern:[0,1,1,2],matrix:[3.2406,-1.5372,-0.4986,-0.9689,1.8758,0.0415,0.0557,-0.204,1.057],neutral:[1,1,1],illuminant:21,orientation:1)
            let values=(0..<256*192*4).map { Float16(0.18+Double($0%64)/1000).bitPattern.littleEndian }
            print("Core format: half values",values.count)
            let quadData=values.withUnsafeBufferPointer { Data(buffer:$0) }
            print("Core format: half bytes",quadData.count)
            let dng=try FusedDNG.encode(quads:quadData,width:256,height:192,calibration:calibration)
            print("Core format: DNG ImageIO reader",dng.count)
            guard let source=CGImageSourceCreateWithData(dng as CFData,[kCGImageSourceTypeIdentifierHint:"com.adobe.raw-image"] as CFDictionary),
                  let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { throw CameraFailure.message("Working DNG is unreadable") }
            try require((props[kCGImagePropertyPixelWidth as String] as? Int) != nil,"DNG properties missing")
            print("Core format: DNG developer")
            guard let decoder=CIRAWFilter(imageData:dng,identifierHint:"com.adobe.raw-image"),let image=decoder.outputImage else { throw CameraFailure.message("CIRAWFilter refused the fused working mosaic") }
            print("Developed DNG:",decoder.nativeSize,image.extent,decoder.scaleFactor)
            try require(image.extent.width==512 && image.extent.height==384,"Working mosaic did not develop")
            var calibrated=calibration
            calibrated.extraColor[50722]=calibration.matrix
            calibrated.extraColor[50964]=[0.4361,0.3851,0.1431,0.2225,0.7169,0.0606,0.0139,0.0971,0.7141]
            calibrated.extraColor[50965]=calibrated.extraColor[50964]
            calibrated.illuminant2=17;calibrated.baselineExposure = -0.25
            calibrated.geometry=DNGSensorGeometry(width:512,height:384,activeArea:[0,0,384,512],cropOrigin:[0,0],cropSize:[512,384])
            func be32(_ value:UInt32)->Data { var bits=value.bigEndian;return withUnsafeBytes(of:&bits) { Data($0) } }
            func be64(_ value:Double)->Data { var bits=value.bitPattern.bigEndian;return withUnsafeBytes(of:&bits) { Data($0) } }
            var gainMap=[UInt32(0),0,384,512,0,1,1,1,2,2].reduce(Data()) { $0+be32($1) }
            gainMap+=be64(1)+be64(1)+be64(0)+be64(0)+be32(1)
            gainMap+=[Float(1),1,1,1].reduce(Data()) { $0+be32($1.bitPattern) }
            calibrated.opcodeList2=be32(1)+be32(9)+be32(0x01030000)+be32(0)+be32(UInt32(gainMap.count))+gainMap
            let richer=try FusedDNG.encode(quads:quadData,width:256,height:192,calibration:calibrated,noiseProfile:[0.001,0.00002])
            let metadata=try DNGMetadata.read(richer)
            try require(metadata[50722]==calibration.matrix && metadata[50779]==[17],"Second illuminant/color matrix lost")
            try require(metadata[50964]==calibrated.extraColor[50964]! && metadata[50965]==calibrated.extraColor[50965]!,"Forward matrices lost")
            try require(metadata[50730]==[-0.25] && metadata[51041]==[0.001,0.00002],"Exposure/noise calibration lost")
            try require(metadata[50719]==[0,0] && metadata[50720]==[512,384] && metadata[50829]==[0,0,384,512],"Original geometry metadata lost")
            try require(metadata.fields[51009]?.data==calibrated.opcodeList2,"Lens shading opcode payload changed")
            guard let richerDecoder=CIRAWFilter(imageData:richer,identifierHint:"com.adobe.raw-image"),let richerImage=richerDecoder.outputImage else { throw CameraFailure.message("Calibrated DNG could not develop") }
            try require(richerImage.extent.width==512 && richerImage.extent.height==384,"Lens shading changed output geometry")
            var badGeometry=calibrated;badGeometry.geometry=nil
            var rejectedGeometry=false
            do { _=try FusedDNG.encode(quads:quadData,width:256,height:192,calibration:badGeometry) } catch { rejectedGeometry=true }
            try require(rejectedGeometry,"Forwarded gain map without original geometry")
            var rejectedOpcodes=false
            do { _=try DNGMetadata.validatedOpcodes(Data([0,0,0,1])) } catch { rejectedOpcodes=true }
            try require(rejectedOpcodes,"Truncated lens shading metadata accepted")
            print("Core format: native 12MP packing")
            try require(BayerQuadPacking.phaseIndices(originX:0,originY:0,anchorX:1,anchorY:1)==[3,2,1,0],"Black pattern origin did not follow ActiveArea")
            var sensor=[UInt16](repeating:1000,count:4032*3024)
            sensor[0]=1100;sensor[1]=1200;sensor[4032]=1300;sensor[4033]=1400
            let native=try sensor.withUnsafeBufferPointer { try BayerQuadPacking.pack($0,rowElements:4032,originX:0,originY:0,cropWidth:4032,cropHeight:3024,step:1,black:[100,100,100,100],white:16000) }
            try require(native.count==4032*3024*2,"Native Bayer data was downsampled")
            try native.withUnsafeBytes { bytes in
                for phase in 0..<4 {
                    let value=Float(Float16(bitPattern:bytes.loadUnaligned(fromByteOffset:phase*2,as:UInt16.self)))
                    try require(abs(value-Float(1000+phase*100)/15900)<0.0001,"Bayer phase or black normalization mismatch")
                }
            }
            let mapped=try BayerScratchStorage.store(native)
            mapped.storage.discardResidentPages()
            try require(mapped.data==native,"Mapped burst payload changed after page discard")
            let nativeDNG=try FusedDNG.encode(quads:mapped.data,width:2016,height:1512,calibration:calibration)
            guard let nativeSource=CGImageSourceCreateWithData(nativeDNG as CFData,[kCGImageSourceTypeIdentifierHint:"com.adobe.raw-image"] as CFDictionary),
                  let nativeProps=CGImageSourceCopyPropertiesAtIndex(nativeSource,0,nil) as? [String:Any] else { throw CameraFailure.message("Native DNG unreadable") }
            try require((nativeProps[kCGImagePropertyPixelWidth as String] as? Int) != nil,"Native DNG properties missing")
            guard let nativeDecoder=CIRAWFilter(imageData:nativeDNG,identifierHint:"com.adobe.raw-image"),let nativeImage=nativeDecoder.outputImage else { throw CameraFailure.message("Native Bayer DNG did not develop") }
            try require(nativeImage.extent.width==4032 && nativeImage.extent.height==3024,"Native DNG lost 12MP geometry")
            let low=SensorNoiseModel.coefficients(iso:100,profile:[])
            let high=SensorNoiseModel.coefficients(iso:1600,profile:[])
            try require(high.x>low.x && high.y>low.y,"ISO does not scale fallback shot/read noise")
            let profile=[0.001,0.00002]
            try require(SensorNoiseModel.coefficients(iso:100,profile:profile)==SensorNoiseModel.coefficients(iso:1600,profile:profile),"DNG noise profile applied ISO twice")
            try require(SensorNoiseModel.validProfile([Double.nan,0])==nil,"Invalid noise profile accepted")
            let pair=SensorNoiseModel.pair(reference:FrameExposure(seconds:0.01,iso:100),referenceProfile:profile,sample:FrameExposure(seconds:0.04,iso:100),sampleProfile:profile,scale:0.25)
            try require(abs(pair.x-0.00125)<1e-8 && abs(pair.y-0.00002125)<1e-9,"Exposure-normalized noise variance is wrong")
            try checkLuckyImaging(calibration:calibration)
            try checkModeRecipes()
            try checkNightMetering()
            try checkImpulseProtection()
            try checkZoomAndFusedExport(calibration:calibrated,quads:quadData,original:dng)
            try checkQuickRAWControls()
            try checkOpticalProgress()
            try checkZSLReference()
            print("Computational source checks passed; no capture session, app launch or GPU execution.")
        } catch { fputs("\(error)\n",stderr);exit(1) }
    }

    static func checkLuckyImaging(calibration:BayerCalibration) throws {
        let width=256,height=192,qw=width/2,qh=height/2
        func signal(_ x:Int,_ y:Int)->Double { 0.18+0.06*sin(Double(x)*Double.pi/4)+0.03*sin(Double(y)*Double.pi/5) }
        func fixture(blurred:Bool) throws -> Data {
            var pixels=[UInt16](repeating:0,count:width*height)
            for y in 0..<height { for x in 0..<width {
                let qx=x/2,qy=y/2,phase=(y%2)*2+x%2
                var value=signal(qx,qy)
                if blurred {
                    value=0
                    for dy in -3...3 { for dx in -3...3 { value+=signal(qx+dx,qy+dy)/49 } }
                }
                // Non-green phases have unrelated fine texture. A green-only
                // metric must rank true green detail rather than that texture.
                if phase==0 || phase==3 { value=0.2+(x%4==0 ? 0.08:-0.08) }
                pixels[y*width+x]=UInt16((100+value*15900).rounded())
            } }
            return try pixels.withUnsafeBufferPointer {
                try BayerQuadPacking.pack($0,rowElements:width,originX:0,originY:0,cropWidth:width,cropHeight:height,step:1,black:[100,100,100,100],white:16000)
            }
        }
        let sharp=try fixture(blurred:false),blurred=try fixture(blurred:true)
        let sharpness=BayerQuadPacking.sharpness(quads:sharp,width:qw,height:qh,pattern:calibration.pattern)
        let softness=BayerQuadPacking.sharpness(quads:blurred,width:qw,height:qh,pattern:calibration.pattern)
        try require(sharpness>softness*2 && softness>=0,"Green-phase metric cannot distinguish sharp from blurred Bayer")
        let exposure=FrameExposure(seconds:0.01,iso:100)
        var frames=[
            SensorBayerFrame(width:qw,height:qh,quads:blurred,calibration:calibration,exposure:exposure,timestamp:1,sharpness:softness),
            SensorBayerFrame(width:qw,height:qh,quads:sharp,calibration:calibration,exposure:exposure,timestamp:2,sharpness:sharpness),
            SensorBayerFrame(width:qw,height:qh,quads:sharp,calibration:calibration,exposure:FrameExposure(seconds:0.01,iso:3200),timestamp:3,sharpness:sharpness*10)
        ]
        try require(SensorBayerFrame.referenceIndex(in:frames,hdr:false)==1,"Lucky imaging selected a blurred frame or exposure outlier")
        try require(SensorBayerFrame.referenceIndex(in:frames,hdr:true)==0,"HDR stopped using the short-exposure reference")
        frames[1].sharpness = .nan
        try require(SensorBayerFrame.referenceIndex(in:frames,hdr:false)==0,"Non-finite sharpness influenced reference selection")
        print("Lucky imaging: green sharp/blur scores",sharpness,softness)
    }

    static func checkModeRecipes() throws {
        var original=ProcessingOptions()
        original.nightMetalRAW=true;original.nightRAW=true;original.hdrMetalRAW=true
        original.lutID="8F1EC45C-875B-47A7-BDB9-4EE541334C66";original.lutIntensity=0.6;original.saturation=1.2;original.postExposure=0.3
        original.color.hsl[0].saturation=0.2
        let natural=PhotoModePolicy.preset(.natural,from:original,supportsRAW:true)
        let night=PhotoModePolicy.preset(.night,from:natural,supportsRAW:true)
        let hdr=PhotoModePolicy.hdr(from:night,supportsRAW:true)
        let nightAgain=PhotoModePolicy.preset(.night,from:hdr,supportsRAW:true)
        for recipe in [natural,night,hdr,nightAgain] {
            _=try recipe.validated()
            try require(recipe.nightMetalRAW && recipe.nightRAW && recipe.hdrMetalRAW,"Mode transition reset Metal RAW preferences")
            try require(recipe.lutID==original.lutID && recipe.lutIntensity==original.lutIntensity && recipe.color==original.color &&
                        recipe.saturation==original.saturation && recipe.postExposure==original.postExposure,"Mode transition reset the active color/LUT profile")
        }
        try require(night.nightStatic && !night.hdrBracketing && hdr.hdrBracketing && !hdr.nightStatic,"Capture mode flags overlap")
        let jpeg=PhotoModePolicy.preset(.night,from:original,supportsRAW:false)
        try require(!jpeg.nightMetalRAW && !jpeg.nightRAW && !jpeg.hdrMetalRAW,"Unsupported lens requested RAW")
        let disabled=PhotoModePolicy.preset(.night,from:ProcessingOptions(),supportsRAW:true)
        try require(!disabled.nightMetalRAW && !disabled.hdrMetalRAW,"Explicitly disabled Metal preference was overridden")
        print("Photo mode recipe checks passed")
    }

    static func checkNightMetering() throws {
        let subject=[Double](repeating:0.18,count:400)
        let exposed=try NightTonePlan.make(luminances:subject,maximumGain:32)
        let sky=try NightTonePlan.make(luminances:[Double](repeating:0.00001,count:600)+subject,maximumGain:32)
        try require(sky.gain<2 && abs(sky.gain-exposed.gain)<0.1,"Black sky drove exposure gain despite exposed subjects")
        let dark=try NightTonePlan.make(luminances:[Double](repeating:0.004,count:1000),maximumGain:32)
        try require(dark.gain>8 && dark.gain<=32,"Dim scene no longer receives bounded exposure lift")
        let black=try NightTonePlan.make(luminances:[Double](repeating:0,count:1000),maximumGain:32)
        try require(black.gain==1,"Empty black scene was amplified")
        var invalid=false
        do { _=try NightTonePlan.make(luminances:[.nan],maximumGain:32) } catch { invalid=true }
        try require(invalid,"Invalid tonal measurement accepted")
        print("Night metering checks passed")
    }

    static func checkImpulseProtection() throws {
        let noise=SensorNoiseModel.coefficients(iso:100,profile:[])
        let center=SIMD4<Float>(0.95,0.15,0.18,0.7)
        let low=SIMD4<Float>(0.19,0.14,0.17,0.1),high=SIMD4<Float>(0.21,0.16,0.19,0.8)
        var clean=center
        for phase in 0..<4 { clean[phase]=BayerImpulseProtection.value(center[phase],minimum:low[phase],maximum:high[phase],noise:noise) }
        try require(abs(clean.x-0.21)<1e-6,"Isolated Bayer hot pixel survived")
        try require(clean.y==center.y && clean.z==center.z && clean.w==center.w,"Impulse correction mixed or changed unaffected phases/edges")
        let cold=BayerImpulseProtection.value(-0.6,minimum:-0.02,maximum:0.02,noise:noise)
        try require(abs(cold+0.02)<1e-6,"Cold impulse survived or negative sensor noise was clipped to zero")
        let noisy=BayerImpulseProtection.value(0.22,minimum:0.19,maximum:0.20,noise:SIMD2<Float>(0,0.001))
        try require(noisy==0.22,"Expected high-ISO noise was erased as an impulse")
        // A corrected initial anchor can now accept a clean frame and converge;
        // the original contaminated mean must not be retained at weight one.
        let candidate:Float=0.2,variance=max(1e-8,noise.x*0.2+noise.y)
        let residual=candidate-clean.x,weight=exp(-(residual*residual)/(18*variance))
        let fused=(clean.x+candidate*weight)/(1+weight)
        try require(weight>0.1 && fused<clean.x,"Corrected anchor still rejected clean aligned samples")
        print("Bayer impulse checks passed")
    }

    static func checkZoomAndFusedExport(calibration:BayerCalibration,quads:Data,original:Data) throws {
        let zoomed=try FusedDNG.encode(quads:quads,width:256,height:192,calibration:calibration,zoom:2)
        let metadata=try DNGMetadata.read(zoomed)
        try require(metadata[50719]==[128,96] && metadata[50720]==[256,192],"RAW zoom crop does not match 2x framing")
        try require(metadata[50829]==[0,0,384,512] && metadata.fields[51009]?.data==calibration.opcodeList2,"Zoom moved the lens-shading coordinate system")
        let native=try BayerZoomCrop.geometry(width:4032,height:3024,original:nil,zoom:3)
        try require(native.cropSize==[1344,1008] && native.cropOrigin==[1344,1008],"Native RAW 3x crop is wrong")
        try require((native.cropOrigin+native.cropSize).allSatisfy { Int($0)%2==0 },"Zoom split Bayer phase pairs")
        let already=try BayerZoomCrop.geometry(width:512,height:384,original:DNGSensorGeometry(width:512,height:384,activeArea:[0,0,384,512],cropOrigin:[128,96],cropSize:[256,192]),zoom:2)
        try require(already.cropOrigin==[128,96] && already.cropSize==[256,192],"Camera-supplied digital crop was zoomed twice")
        guard let decoder=CIRAWFilter(imageData:zoomed,identifierHint:"com.adobe.raw-image"),let image=decoder.outputImage else { throw CameraFailure.message("Zoomed DNG did not develop") }
        try require(image.extent.width==256 && image.extent.height==192,"RAW developer ignored the viewfinder zoom")
        var options=ProcessingOptions()
        try require(options.selectedRAW(original:original,fused:zoomed)==original,"Original DNG changed when fused export was off")
        options.saveFusedDNG=true
        let saved=options.selectedRAW(original:original,fused:zoomed)
        let savedMetadata=try DNGMetadata.read(saved)
        try require(saved==zoomed && savedMetadata[50720]==[256,192],"Computational DNG export lost zoom/calibration")
        let decoded=try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(options))
        try require(decoded.saveFusedDNG,"Computational DNG preference did not persist")
        var old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(options)) as! [String:Any]
        old.removeValue(forKey:"saveFusedDNG")
        let oldOptions=try JSONDecoder().decode(ProcessingOptions.self,from:JSONSerialization.data(withJSONObject:old))
        try require(!oldOptions.saveFusedDNG,"Older profiles enabled computational RAW unexpectedly")
        print("RAW zoom and computational DNG checks passed")
    }

    static func checkQuickRAWControls() throws {
        var options=ProcessingOptions();options.nightStatic=true;options.nightSpectralFusion=true
        let night=PhotoModePolicy.toggledRAW(options,photoRAW:false,supportsRAW:true)
        try require(night.options.nightMetalRAW && night.options.nightRAW && !night.options.nightSpectralFusion && !night.photoRAW,"Night quick RAW did not enable a coherent Metal recipe")
        _=try night.options.validated()
        try require(PhotoModePolicy.formatLabel(night.options,photoRAW:night.photoRAW)=="RAW*","Night quick format label is wrong")
        let jpeg=PhotoModePolicy.toggledRAW(night.options,photoRAW:false,supportsRAW:true)
        try require(!jpeg.options.nightMetalRAW && !jpeg.options.nightRAW && PhotoModePolicy.formatLabel(jpeg.options,photoRAW:false)=="JPEG","Night quick RAW did not disable both RAW paths")
        let hdrRecipe=PhotoModePolicy.hdr(from:jpeg.options,supportsRAW:true)
        let hdr=PhotoModePolicy.toggledRAW(hdrRecipe,photoRAW:false,supportsRAW:true)
        try require(hdr.options.hdrMetalRAW && !hdr.options.nightStatic && !hdr.photoRAW,"HDR quick RAW toggled the wrong mode")
        let unsupported=PhotoModePolicy.toggledRAW(options,photoRAW:false,supportsRAW:false)
        try require(unsupported.options==options && !unsupported.photoRAW,"Unsupported RAW control changed the recipe")
        var photo=ProcessingOptions();photo.zeroShutterLagFusion=true
        let raw=PhotoModePolicy.toggledRAW(photo,photoRAW:false,supportsRAW:true)
        try require(raw.photoRAW && !raw.options.zeroShutterLagFusion,"Photo RAW remained combined with preview ZSL")
        print("Quick RAW mode checks passed")
    }

    static func checkOpticalProgress() throws {
        var state=OpticalCaptureProgress();state.begin(total:3)
        state.exposed(id:1);state.exposed(id:1)
        try require(state.capturing && state.completed==1 && abs(state.fraction-1.0/3)<1e-8,"Duplicate photo callback advanced sensor progress")
        state.exposed(id:2);state.exposed(id:3)
        try require(!state.capturing && state.fraction==1,"Sensor progress did not end at the final exposure")
        state.reset();try require(!state.capturing && state.fraction==0,"Failed capture retained optical progress")
    }

    static func checkZSLReference() throws {
        let context=CIContext(options:[.useSoftwareRenderer:true])
        let extent=CGRect(x:0,y:0,width:256,height:192)
        let image=CIImage.empty().applyingFilter("CICheckerboardGenerator",parameters:["inputWidth":8]).cropped(to:extent)
        let soft=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:4]).cropped(to:extent)
        guard let sharp=context.createCGImage(image,from:extent),let blur=context.createCGImage(soft,from:extent) else { throw CameraFailure.message("Could not create ZSL reference fixture") }
        try require(PreviewReferenceSelector.index(in:[sharp,blur,sharp,blur],context:context)==2,"ZSL chose the shutter-shaken last frame or a frame outside the latest three")
        print("Recent ZSL reference check passed")
    }
}
