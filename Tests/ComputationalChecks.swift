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
            try check016(calibration:calibration,quads:quadData)
            try check017(calibration:calibration,quads:quadData)
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
        guard let image=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8])?.outputImage?.cropped(to:extent) else { throw CameraFailure.message("Could not create ZSL pattern") }
        let soft=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:4]).cropped(to:extent)
        guard let sharp=context.createCGImage(image,from:extent),let blur=context.createCGImage(soft,from:extent) else { throw CameraFailure.message("Could not create ZSL reference fixture") }
        try require(PreviewReferenceSelector.index(in:[sharp,blur,sharp,blur],context:context)==2,"ZSL chose the shutter-shaken last frame or a frame outside the latest three")
        print("Recent ZSL reference check passed")
    }
    static func check016(calibration:BayerCalibration,quads:Data) throws {
        try require(UCHDRExposureWeight(0,0.2,0.25)==1,"Long HDR exposure discarded deep shadows/black CFA channel")
        try require(UCHDRExposureWeight(0,0.2,2)==0,"Short HDR exposure accepted its noise floor")
        try require(UCHDRExposureWeight(0,1,0.25)==0,"Long HDR exposure accepted saturated highlights")
        try require(UCHDRExposureWeight(0,0.95,0.25)>0 && UCHDRExposureWeight(0,0.95,0.25)<1,"HDR highlight ramp lost its shoulder")
        try require(abs(UCRAWVarianceSignal(-0.001,0.02)-0.01)<1e-6,"Negative anchor underestimated RAW signal variance")
        let full=try BayerFusionRegion.make(width:2016,height:1512,geometry:nil,zoom:1)
        let region=try BayerFusionRegion.make(width:2016,height:1512,geometry:nil,zoom:2)
        try require(full==BayerFusionRegion(minX:0,minY:0,maxX:2016,maxY:1512),"Native ROI clipped the full sensor")
        let crop=try BayerZoomCrop.geometry(width:4032,height:3024,original:nil,zoom:2)
        try require(region.minX<=Int(crop.cropOrigin[0])/2-32 && region.minY<=Int(crop.cropOrigin[1])/2-32,"Zoom ROI lost warp margin")
        try require(region.maxX>=Int(crop.cropOrigin[0]+crop.cropSize[0])/2+32 && region.maxY>=Int(crop.cropOrigin[1]+crop.cropSize[1])/2+32,"Zoom ROI lost far-side warp margin")
        try require((region.maxX-region.minX)*(region.maxY-region.minY)<2016*1512/2,"2x zoom still fuses the entire sensor")
        let coarse=region.level(2)
        try require(coarse.minX*4<=region.minX && coarse.maxX*4>=region.maxX,"Pyramid ROI rounded inward")
        var archive=BayerReferenceArchive(),frames=[SensorBayerFrame](),jpegs=[Data]()
        for i in 0..<6 {
            let exposure=FrameExposure(seconds:i<2 ? 0.01:0.02,iso:400)
            let frame=SensorBayerFrame(width:256,height:192,quads:quads,calibration:calibration,exposure:exposure,timestamp:Double(i),sharpness:Double(i))
            frames.append(frame);jpegs.append(Data([UInt8(i),0x4a]))
            try archive.append(Data([UInt8(i),0x44]),index:i)
        }
        guard let anchor=SensorBayerFrame.referenceIndex(in:frames,hdr:false),let original=archive.original(at:anchor) else { throw CameraFailure.message("Lost Lucky Imaging reference") }
        try require(anchor==5 && original[0]==jpegs[anchor][0],"DNG/JPEG do not share the final dominant-cohort sharp anchor")
        let hdr=SensorBayerFrame.referenceIndex(in:frames,hdr:true)!
        try require(hdr==0 && archive.original(at:hdr)==Data([0,0x44]),"HDR original no longer matches its shortest exposure")
        let info=DNGCaptureInfo(exposure:frames[anchor].exposure,aperture:1.8,focalLength:4.25,lensModel:"Synthetic lens",make:"Apple",model:"iPhone")
        let encoded=try FusedDNG.encode(quads:quads,width:256,height:192,calibration:calibration,capture:info)
        let tags=try DNGMetadata.read(encoded)
        try require(abs((tags[33434].first ?? 0)-0.02)<1e-6 && tags[34855]==[400],"Computational DNG lost anchor EXIF exposure/ISO")
        try require(tags.fields[42036] != nil && tags[37386]==[4.25],"Computational DNG lost lens metadata")
        var options=ProcessingOptions();options.zeroShutterLagFusion=true
        try require(options.usesPreviewZSL,"Hybrid native-anchor ZSL was disabled at quality priority")
        options.singlePhotoQuality = .balanced
        try require(options.usesPreviewZSL,"Hybrid ZSL path unavailable")
        archive.reset();try require(archive.original(at:anchor)==nil,"RAW archive did not release its mappings")
        var base=ProcessingOptions();base.nightStatic=true;base.nightMetalRAW=true;base.nightRAW=true;base.color.grain=0.2
        let native=PhotoModePolicy.nativeNight(from:base)
        _=try native.validated()
        try require(native.nativeNight && !native.nightStatic && !native.hdrBracketing && !native.usesPreviewZSL,"Native night remained mixed with app-managed fusion")
        try require(native.color==base.color && native.nightMetalRAW,"Native night erased the user's look/RAW preference")
        let nativeRoundTrip=try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(native))
        try require(nativeRoundTrip==native,"Native night settings did not persist")
        try require(PhotoModePolicy.toggledRAW(native,photoRAW:false,supportsRAW:true).options==native,"Native night requested incompatible Bayer RAW")
        try require(!PhotoModePolicy.hdr(from:native,supportsRAW:true).nativeNight && !PhotoModePolicy.preset(.night,from:native,supportsRAW:true).nativeNight,"Photo modes did not leave native night")
        print("Native night mode policy checks passed")
        print("0.16 HDR weights, ROI, indexed references, capture EXIF and native-quality ZSL checks passed")
    }

    static func check017(calibration:BayerCalibration,quads:Data) throws {
        var frame=SensorBayerFrame(width:2016,height:1512,quads:Data(),calibration:calibration,exposure:FrameExposure(seconds:0.02,iso:400),timestamp:1,zoom:2)
        guard let sr=try SuperResolutionPlan.make(frame,count:4) else { throw CameraFailure.message("2x SR did not activate") }
        try require(sr.width==2016 && sr.height==1512 && sr.scaleX==2 && sr.scaleY==2,"SR failed to restore the 12 MP Bayer raster")
        try require(sr.originX==504 && sr.originY==378,"SR changed the requested viewfinder framing")
        try require(try SuperResolutionPlan.make(frame,count:3)==nil,"SR invented samples from an insufficient burst")
        frame.zoom=1.1
        try require(try SuperResolutionPlan.make(frame,count:4)==nil,"SR changed ordinary native photography")
        let w=40,h=24
        let shifts:[SIMD2<Float>]=[SIMD2(0,0),SIMD2(0.5,0),SIMD2(0,0.5),SIMD2(0.5,0.5)]
        func scene(_ x:Float,_ y:Float)->Float { 0.4+0.2*cos(2*Float.pi*(0.65*x+0.08*y)) }
        let samples=shifts.map { shift in (0..<w*h).map { scene(Float($0%w)-shift.x,Float($0/w)-shift.y) } }
        let result=SuperResolutionReference.reconstruct(samples:samples,width:w,height:h,shifts:shifts)
        var srError:Float=0,resizeError:Float=0
        for y in 6..<h*2-6 { for x in 6..<w*2-6 {
            let px=UCSRPosition(Float(x),0.25,0,2),py=UCSRPosition(Float(y),0.25,0,2)
            let ix=Int(floor(px)),iy=Int(floor(py)),fx=px-Float(ix),fy=py-Float(iy)
            let top=samples[0][iy*w+ix]*(1-fx)+samples[0][iy*w+ix+1]*fx
            let bottom=samples[0][(iy+1)*w+ix]*(1-fx)+samples[0][(iy+1)*w+ix+1]*fx
            let resized=top*(1-fy)+bottom*fy,truth=scene(px,py)
            srError+=pow(result[y*w*2+x]-truth,2);resizeError+=pow(resized-truth,2)
        } }
        try require(srError<resizeError*0.75,"Shifted SR did not recover the synthetic 0.65-cycle/quad signal better than a single-frame resize")
        let small=SensorBayerFrame(width:256,height:192,quads:quads,calibration:calibration,exposure:frame.exposure,timestamp:1,zoom:2)
        let plan=try SuperResolutionPlan.make(small,count:4)!
        let encoded=try FusedDNG.encode(quads:quads,width:plan.width,height:plan.height,calibration:plan.calibration(calibration),zoom:1)
        let decoder=CIRAWFilter(imageData:encoded,identifierHint:"com.adobe.raw-image")
        try require(decoder?.outputImage?.extent.size==CGSize(width:512,height:384),"Reconstructed DNG retained the low-resolution crop")
        func be32(_ value:UInt32)->Data { var v=value.bigEndian;return withUnsafeBytes(of:&v){Data($0)} }
        func be64(_ value:Double)->Data { var v=value.bitPattern.bigEndian;return withUnsafeBytes(of:&v){Data($0)} }
        let radial=be32(1)+be32(3)+be32(0x01030000)+be32(0)+be32(56)+[0.5,0.1,0,0,0,0.5,0.5].reduce(Data()){$0+be64($1)}
        var optics=calibration;optics.opcodeList3=radial
        let native=try FusedDNG.encode(quads:quads,width:256,height:192,calibration:optics)
        try require(try DNGMetadata.read(native).fields[51022]?.data==radial,"Apple radial vignetting was dropped from a native DNG")
        let opticalFrame=SensorBayerFrame(width:256,height:192,quads:quads,calibration:optics,exposure:frame.exposure,timestamp:1,zoom:2)
        let opticalPlan=try SuperResolutionPlan.make(opticalFrame,count:4)!
        let remapped=try DNGMetadata.validatedOpcodes(opticalPlan.vignette!)
        func double(_ o:Int)->Double { Double(bitPattern:remapped[o..<o+8].reduce(UInt64(0)){($0<<8)|UInt64($1)}) }
        try require(abs(double(20)-0.125)<1e-9 && abs(double(28)-0.00625)<1e-9 && double(60)==0.5,"SR radial shading was not transformed into the crop coordinates")
        let opticalDNG=try FusedDNG.encode(quads:quads,width:256,height:192,calibration:opticalPlan.calibration(optics))
        try require(try DNGMetadata.read(opticalDNG).fields[51022]?.data==remapped,"SR DNG lost transformed optical shading")
        guard let opticalDecoder=CIRAWFilter(imageData:opticalDNG,identifierHint:"com.adobe.raw-image"),opticalDecoder.outputImage != nil else { throw CameraFailure.message("Transformed optical DNG did not develop") }
        let map=BayerGainMap(top:0,left:0,bottom:384,right:512,rowPitch:1,colPitch:1,rows:2,cols:2,spacingY:1,spacingX:1,originY:0,originX:0,gains:[1,2,3,4])
        let operation=map.transformed(plan)!
        let mapped=try BayerGainMap.read(be32(1)+operation)[0]
        for y in [0,40,191,383] { for x in [0,100,256,511] {
            let ox=plan.originX*2+(Double(x)+0.5)/plan.scaleX,oy=plan.originY*2+(Double(y)+0.5)/plan.scaleY
            let before=map.gain(x:ox,y:oy,phase:0,sensorWidth:512,sensorHeight:384)
            let after=mapped.gain(x:Double(x)+0.5,y:Double(y)+0.5,phase:0,sensorWidth:512,sensorHeight:384)
            try require(abs(before-after)<1e-5,"SR changed the original lens GainMap / highlight headroom")
        } }
        let vendor=LensCalibration.vendorFloor(iso:100,lens:.wide,platform:"iPhone12,3/22H31")!
        try require(abs(vendor.x-0.0000962327646289)<1e-9 && abs(vendor.y-0.0000013591362724)<1e-10,"D421 ISO noise floor was not preserved")
        try require(LensCalibration.vendorFloor(iso:100,lens:.front,platform:"iPhone12,3/22H31")==nil && LensCalibration.vendorFloor(iso:100,lens:.wide,platform:"iPhone12,3/other")==nil,"Unmeasured front / different firmware was labelled calibrated")
        try require(LensCalibration.profile(.ultraWide).aperture==2.4 && !LensCalibration.profile(.ultraWide).opticalStabilization && LensCalibration.profile(.telephoto).aperture==2,"Physical lens profile is inconsistent")
        for lens in LensIdentity.allCases {
            let prior=LensCalibration.profile(lens)
            try require(prior.shot>0 && prior.read>0 && prior.sharpenRadius>0,"Invalid lens profile")
            let model=SensorNoiseModel.coefficients(iso:800,profile:[],lens:lens)
            let measured=SensorNoiseModel.coefficients(iso:800,profile:[0.001,0.00002],lens:lens)
            try require(abs(measured.x-0.001)<1e-7 && abs(measured.y-0.00002)<1e-8,"Lens prior overwrote measured DNG noise")
            if lens != .wide { try require(model.y>SensorNoiseModel.coefficients(iso:800,profile:[],lens:.wide).y,"Lens read-noise prior was ignored") }
            var recipe=ProcessingOptions();recipe.lens=lens;recipe.chromaDenoise=0.8;recipe.localContrast=1.2;recipe.sharpenRadius=3
            let kept=prior.recipe(recipe)
            try require(kept.chromaDenoise==0.8 && kept.localContrast==1.2 && kept.sharpenRadius==3,"Automatic lens recipe overwrote manual settings")
        }
        try require(UCTemporalPoint(0.7,0.01,0.68,0.01,0.001,0.5,0.0001,0.03)==1,"Aligned real point was clipped as an impulse")
        try require(UCTemporalPoint(0.7,0.01,0.01,0.01,0.001,0.5,0.1,0)==0,"Isolated hot pixel gained temporal support")
        try require(UCTemporalPoint(0.7,0.01,0.5,0.01,0.001,0.5,0.02,0)==0,"Sensor-fixed hot pixel was accepted under measurable motion")
        try require(UCTemporalPoint(0.7,0.01,0.7,0.01,0.001,0,0,0)==1,"Indistinguishable stationary point was erased")
        let meter=PreviewMotionMeter()
        let texture=(0..<64*48).map { i -> Float in Float((i*7381^(i/64)*193)%239)/300 }
        for index in 0..<18 { meter.append(texture,time:10+Double(index)*0.1) }
        try require(meter.estimate(at:11.71)?.tripodStable==true,"Stable textured tripod did not qualify")
        meter.reset();try require(meter.estimate(at:11.71)==nil,"Motion reset retained tripod state")
        let astro=try NightCapturePlan.make(iso:1600,seconds:1.0/30,isoRange:25...3200,durationRange:0.0001...0.8,budget:16,tripodStable:true)
        try require(astro.astro && astro.count==16 && astro.seconds==0.8,"Astro did not use the physical exposure limit")
        let bounded=try NightCapturePlan.make(iso:1600,seconds:1.0/30,isoRange:25...3200,durationRange:0.0001...1,budget:8,tripodStable:true)
        try require(bounded.astro && bounded.seconds==1 && bounded.count==8 && bounded.seconds*Double(bounded.count)<=8,"Astro shortened integrations unnecessarily / exceeded the integration budget")
        let blocked=try NightCapturePlan.make(iso:1600,seconds:1.0/30,isoRange:25...3200,durationRange:0.0001...1,budget:16,tripodStable:true,astroEnabled:false)
        try require(!blocked.astro,"Disabled Astro still altered exposure scheduling")
        let daylight=try NightCapturePlan.make(iso:25,seconds:0.001,isoRange:25...3200,durationRange:0.0001...1,budget:16,tripodStable:true)
        try require(!daylight.astro && abs(daylight.iso*daylight.seconds-0.025)<1e-6,"Tripod scheduling overexposed a bright minimum-ISO scene")
        let hdrScene=HDRSceneMeter(shadow:0.002,median:0.15,highlight:0.999,timestamp:1)
        let adaptive=try HDRCapturePlan.make(iso:200,seconds:0.02,span:1,isoRange:25...3200,durationRange:0.0001...1,scene:hdrScene)
        try require(adaptive[0].seconds==0.01 && adaptive[2].product/adaptive[0].product>4,"HDR ignored clipped highlights / scene span")
        var temporal=ProcessingOptions();temporal.zeroShutterLagFusion=true;temporal.nightStatic=true
        try require(!temporal.usesPreviewZSL,"ZSL changed the manual night capture priority")
        temporal.nightStatic=false;temporal.hdrBracketing=true
        try require(!temporal.usesPreviewZSL,"ZSL changed HDR exposure scheduling")
        print("0.17 SR recovery, lens priors, temporal points, tripod scheduling and adaptive HDR passed")
    }

}
