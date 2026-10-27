import Foundation
import CoreImage
import ImageIO
import Darwin

/// Runs the production Core Image / Vision processor on macOS without a camera.
/// These checks do not establish iPhone image quality or hardware compatibility.
@main
struct ProcessorChecks {
    static let size = 256
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CameraFailure.message(message) }
    }

    static func clean(_ x: Int, _ y: Int) -> Int {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return 0 }
        let block = ((x / 13) * 73856093) ^ ((y / 11) * 19349663)
        return 55 + abs(block % 130) + ((x + y) % 9)
    }

    static func png(seed: UInt64, noise: Int = 0, dx: Int = 0, dy: Int = 0, boxX: Int? = nil) throws -> Data {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let delta = noise == 0 ? 0 : Int((state >> 32) % UInt64(noise * 2 + 1)) - noise
                    let moving = boxX.map { x >= $0 && x < $0 + 24 && y >= 100 && y < 124 } ?? false
                    pixels[(y * size + x) * 4 + channel] = UInt8(clamping: (moving ? 250 : clean(x - dx, y - dy)) + delta)
                }
            }
        }
        let data = Data(pixels)
        let image = CIImage(bitmapData: data, bytesPerRow: size * 4,
            size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: space)
        guard let encoded = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space) else {
            throw CameraFailure.message("Cannot encode fixture")
        }
        return encoded
    }

    static func bitmap(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let image = CIImage(data: data) else { throw CameraFailure.message("Cannot decode fixture") }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                bounds: image.extent, format: .RGBA8, colorSpace: space)
        }
        return (pixels, width, height)
    }

    static func rmse(_ bitmap: (pixels: [UInt8], width: Int, height: Int),
                     against reference: (pixels: [UInt8], width: Int, height: Int),
                     offsetX: Int = 0, offsetY: Int = 0) -> Double {
        var error = 0.0, count = 0.0
        for y in 16..<(bitmap.height - 16) {
            for x in 16..<(bitmap.width - 16) {
                let rx = x + offsetX, ry = y + offsetY
                guard rx >= 0, ry >= 0, rx < reference.width, ry < reference.height else { continue }
                for c in 0..<3 {
                    let a = Double(bitmap.pixels[(y * bitmap.width + x) * 4 + c])
                    let b = Double(reference.pixels[(ry * reference.width + rx) * 4 + c])
                    error += (a - b) * (a - b)
                    count += 1
                }
            }
        }
        return sqrt(error / max(1, count))
    }

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data(("CHECK FAILED: \(error)\n").utf8))
            exit(1)
        }
    }

    static func run() throws {
        try check017()
        let plan = try NightCapturePlan.make(iso: 1600, seconds: 1.0 / 30, isoRange: 25...3200, durationRange: 0.00001...0.333)
        try require(plan.seconds == 0.25 && plan.iso < 250 && plan.count == 16, "Static night did not trade ISO for exposure")
        try require(abs(plan.iso * plan.seconds - 1600.0 / 30) < 0.001, "Night plan changed metered brightness")
        let bright = try NightCapturePlan.make(iso: 25, seconds: 0.001, isoRange: 25...3200, durationRange: 0.00001...0.333)
        try require(abs(bright.seconds - 0.001) < 0.000001, "Night plan overexposes a minimum-ISO scene")
        let long = try NightCapturePlan.make(iso: 3200, seconds: 0.06, isoRange: 25...3200, durationRange: 0.00001...1)
        try require(long.count == 8 && long.seconds == 1 && long.seconds * Double(long.count) <= 8, "Static exposure exceeds collection budget")
        let rounded = try NightCapturePlan.make(iso: 803, seconds: 1.0 / 30, isoRange: 32...3072,
            durationRange: 0.00001...1)
        try require(rounded.seconds == 0.5 && rounded.count == 16 && abs(rounded.iso * rounded.seconds - 803.0 / 30) < 0.001,
            "Night long-shutter quantization changed metered exposure or integration budget")
        let shortfall = try NightCapturePlan.make(iso: 3200, seconds: 0.06, isoRange: 25...3200,
            durationRange: 0.00001...1, targetOffset: -5)
        try require(shortfall.compensationEV == 2 && abs(shortfall.iso * shortfall.seconds - 768) < 0.001,
            "Night AE shortfall was not capped at 2 EV")
        let brightOffset = try NightCapturePlan.make(iso: 25, seconds: 0.001, isoRange: 25...3200,
            durationRange: 0.00001...1, targetOffset: -5)
        try require(brightOffset.compensationEV == 0 && abs(brightOffset.iso * brightOffset.seconds - 0.025) < 0.000001,
            "Night shortfall compensation changed a low-ISO bright scene")
        do {
            _ = try NightCapturePlan.make(iso: .nan, seconds: 0.01, isoRange: 25...3200, durationRange: 0.00001...1)
            throw CameraFailure.message("Invalid metering accepted")
        } catch CameraFailure.message(let message) {
            try require(message != "Invalid metering accepted", message)
        }
        log("NIGHT CAPTURE PLAN CHECKS PASSED · no hardware")
        let extended = try NightCapturePlan.make(iso:3200,seconds:0.06,isoRange:25...3200,durationRange:0.00001...1,budget:16)
        try require(extended.count == 16 && extended.seconds == 1,"Extended night budget was not applied")
        let capped = try NightCapturePlan.make(iso:1600,seconds:1.0/30,isoRange:25...3200,durationRange:0.00001...1,budget:2,shutterLimit:0.125)
        try require(capped.seconds <= 0.125 && Double(capped.count)*capped.seconds <= 2.0001,"Night exposure or integration limit exceeded")
        try require(abs(capped.iso*capped.seconds-1600.0/30)<0.001,"Shutter cap failed to compensate ISO within range")
        let processor = BurstProcessor()
        try autoreleasepool {
            let extent=CGRect(x:0,y:0,width:4032,height:3024)
            let scene=CIImage(color:CIColor(red:0.3,green:0.45,blue:0.6)).cropped(to:extent)
            guard let fixture=context.pngRepresentation(of:scene,format:.RGBA8,colorSpace:space) else {
                throw CameraFailure.message("Cannot encode native-resolution fixture")
            }
            var nativeOptions=ProcessingOptions()
            nativeOptions.maximumDimension=4096
            nativeOptions.sharpening=0.1 // Exercise rendering rather than passthrough.
            let nativeResult=try processor.process([fixture],options:nativeOptions)
            guard let source=CGImageSourceCreateWithData(nativeResult.jpeg as CFData,nil),
                  let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else {
                throw CameraFailure.message("Native processor output unreadable")
            }
            try require(properties[kCGImagePropertyPixelWidth as String] as? Int == 4032 &&
                        properties[kCGImagePropertyPixelHeight as String] as? Int == 3024,
                        "Processor reduced native 4032x3024 geometry")
        }
        log("NATIVE 12MP PROCESSOR CHECK PASSED")
        let reference = try bitmap(png(seed: 1))
        let noisy = try [png(seed: 10, noise: 24), png(seed: 20, noise: 24), png(seed: 30, noise: 24)]
        let fixedReference = ProcessingOptions(chooseSharpestReference: false)
        let denoised = try processor.process(noisy, options: fixedReference)
        try require(denoised.mergedFrames == 3, "Noise fixture did not merge all frames")
        let individual = rmse(try bitmap(noisy[0]), against: reference)
        let merged = rmse(try bitmap(denoised.jpeg), against: reference)
        log("Noise RMSE: individual=\(individual), merged=\(merged)")
        try require(merged < individual * 0.85, "Averaging did not reduce fixture noise sufficiently")

        let translated = try processor.process([png(seed: 1), png(seed: 1, dx: 5, dy: -3), png(seed: 1, dx: -4, dy: 2)], options: fixedReference)
        try require(translated.mergedFrames == 3, "Translation fixture did not merge all frames")
        let result = try bitmap(translated.jpeg)
        var best = Double.infinity
        // The output is cropped to the overlap; find the corresponding reference origin.
        for y in 0...10 { for x in 0...10 {
            best = min(best, rmse(result, against: reference, offsetX: x, offsetY: y))
        } }
        log("Translated fixture best RMSE=\(best), output=\(result.width)x\(result.height)")
        try require(best < 8, "Translation direction or fusion introduces ghosting in a static fixture")

        let cleanData = try png(seed: 1)
        let cleanImage = CIImage(data: cleanData)!
        let large = cleanImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let canvas = CIImage(color: .black).cropped(to: large.extent)
        let shiftedLarge = large.transformed(by: CGAffineTransform(translationX: 24, y: -16))
            .composited(over: canvas).cropped(to: large.extent)
        let largeData = context.pngRepresentation(of: large, format: .RGBA8, colorSpace: space)!
        let shiftedData = context.pngRepresentation(of: shiftedLarge, format: .RGBA8, colorSpace: space)!
        var largeOptions = fixedReference
        largeOptions.maximumDimension = 4096
        largeOptions.rejectMotion = false
        let largeFusion = try processor.process([largeData, shiftedData], options: largeOptions)
        let largePixels = try bitmap(largeFusion.jpeg), largeReference = try bitmap(largeData)
        log("Large translation: \(largeFusion.details)")
        try require(largeFusion.mergedFrames == 2 && largePixels.width > 2000 && largePixels.height > 2000,
            "Reduced registration lost full-resolution fusion")
        var largeError = Double.infinity
        // CGImage row order and the crop can put the retained origin at either edge.
        for y in 0...18 { for x in 0...2 {
            largeError = min(largeError, rmse(largePixels, against: largeReference, offsetX: x, offsetY: y))
        } }
        log("Large registration RMSE=\(largeError)")
        try require(largeError < 8, "Reduced registration did not rescale translation correctly")
        log("Reduced registration/full resolution RMSE=\(largeError)")
        let blurredImage = cleanImage.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: cleanImage.extent)
        let blurredData = context.pngRepresentation(of: blurredImage, format: .RGBA8, colorSpace: space)!
        let selected = try processor.process([blurredData, cleanData])
        try require(selected.reference == cleanData, "Reference selection preferred a blurred frame")
        log("Sharpness reference selection passed")

        let moving = try [cleanData, png(seed: 1, boxX: 40), png(seed: 1, boxX: 170)]
        var noRejection = fixedReference
        noRejection.rejectMotion = false
        let naive = try bitmap(processor.process(moving, options: noRejection).jpeg)
        let robust = try bitmap(processor.process(moving, options: fixedReference).jpeg)
        func croppedError(_ image: (pixels: [UInt8], width: Int, height: Int)) -> Double {
            var best = Double.infinity
            for y in 0...3 { for x in 0...3 { best = min(best, rmse(image, against: reference, offsetX: x, offsetY: y)) } }
            return best
        }
        let naiveError = croppedError(naive), robustError = croppedError(robust)
        log("Motion fixture RMSE: naive=\(naiveError), rejected=\(robustError)")
        try require(robustError < naiveError * 0.7, "Motion rejection did not suppress displaced objects")
        let adjusted = try processor.process([cleanData], options: ProcessingOptions(noiseReduction: 0.02, sharpening: 0.2, liftShadows: 0.2))
        try require(!adjusted.jpeg.isEmpty && adjusted.reference == cleanData, "Single-image adjustments lost reference")
        let fullImage = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 3200, height: 800))
        let fullData = context.pngRepresentation(of: fullImage, format: .RGBA8, colorSpace: space)!
        let fullResult = try processor.process([fullData], options: ProcessingOptions(maximumDimension: 1024, noiseReduction: 0.01))
        let source = CGImageSourceCreateWithData(fullResult.jpeg as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        try require((properties[kCGImagePropertyPixelWidth] as? Int) == 3200 &&
                    (properties[kCGImagePropertyPixelHeight] as? Int) == 800,
                    "Single-photo adjustments incorrectly applied the burst resolution limit")
        log("Single-photo full resolution preserved")
        var night = ProcessingOptions()
        night.nightStatic = true
        night.chooseSharpestReference = false
        let darkImage = cleanImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -4])
        let darkData = context.pngRepresentation(of: darkImage, format: .RGBA8, colorSpace: space)!
        let brightened = try bitmap(processor.process([darkData], options: night).jpeg)
        let darkBitmap = try bitmap(darkData)
        let before = darkBitmap.pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0,+)
        let after = brightened.pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0,+)
        try require(after > before * 1.3 && after.isFinite, "Night tone mapping did not brighten the dark fixture")
        try require(brightened.width == size && brightened.height == size, "Night tone mapping changed dimensions")
        let shadowField = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let screen = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
            .cropped(to: CGRect(x: 96, y: 96, width: 64, height: 64))
            .composited(over: shadowField)
        let screenData = context.pngRepresentation(of: screen, format: .RGBA8, colorSpace: space)!
        let screenBefore = try bitmap(screenData)
        let screenAfter = try bitmap(processor.process([screenData], options: night).jpeg)
        let center = ((size / 2) * size + size / 2) * 4
        try require(abs(Int(screenAfter.pixels[center]) - Int(screenBefore.pixels[center])) <= 6,
            "Night shadow lift washed out an already exposed highlight")
        try require(Double(screenAfter.pixels[0]) > Double(screenBefore.pixels[0]) * 1.3,
            "Highlight protection also prevented shadow recovery")
        log("Night highlight retention and simultaneous shadow lift passed")
        let cleanNight = try bitmap(processor.process([cleanData],options:night).jpeg)
        let noisyNight = try bitmap(processor.process([noisy[0]],options:night).jpeg)
        let weightedNightResult = try processor.process(noisy,options:night)
        let weightedNight = try bitmap(weightedNightResult.jpeg)
        func nightError(_ image: (pixels:[UInt8],width:Int,height:Int)) -> Double {
            var error = Double.infinity
            for y in 0...3 { for x in 0...3 { error = min(error,rmse(image,against:cleanNight,offsetX:x,offsetY:y)) } }
            return error
        }
        let singleNightError=nightError(noisyNight), weightedNightError=nightError(weightedNight)
        try require(weightedNightResult.mergedFrames>=2 && weightedNightError<singleNightError*0.85,"Weighted night pipeline failed to reduce synthetic static noise")
        log("WEIGHTED NIGHT PIPELINE CHECKS PASSED · synthetic RMSE \(singleNightError) -> \(weightedNightError), not optical quality")
        do {
            _ = try processor.process([cleanData], options: night, rawFrames: [])
            throw CameraFailure.message("Mismatched RAW/JPEG accepted")
        } catch CameraFailure.message(let message) {
            try require(message != "Mismatched RAW/JPEG accepted", message)
        }
        log("NIGHT TONE CHECKS PASSED · PNG fixture only, not DNG or optical quality")
        var hdrOptions=ProcessingOptions();hdrOptions.hdrBracketing=true
        var bracket=[Data]()
        let hdrExposures=[FrameExposure(seconds:0.01,iso:100),FrameExposure(seconds:0.0025,iso:100),FrameExposure(seconds:0.04,iso:100)]
        for gain in [1.0,0.25,4.0] {
            let brightPatch=CIImage(color:CIColor(red:2,green:1.5,blue:1.2)).cropped(to:CGRect(x:80,y:80,width:64,height:64))
            let scene=brightPatch.composited(over:cleanImage.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-2]))
                .applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:log2(gain)])
                .applyingFilter("CIColorClamp",parameters:["inputMinComponents":CIVector(x:0,y:0,z:0,w:0),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
            bracket.append(context.pngRepresentation(of:scene,format:.RGBA16,colorSpace:space)!)
        }
        let hdrResult=try HDRProcessor().process(bracket,exposures:hdrExposures,options:hdrOptions)
        try require(hdrResult.mergedFrames>=2 && hdrResult.source=="HDR-JPEG-radiance", "HDR pipeline did not merge a valid synthetic bracket")
        let hdrBitmap=try bitmap(hdrResult.jpeg)
        try require(hdrBitmap.width>size*9/10 && hdrBitmap.height>size*9/10,"HDR registration lost excessive field of view")
        log("HDR BRACKET CHECKS PASSED · synthetic clipped PNG bracket, not physical exposure validation")
        var edit=ProcessingOptions()
        edit.sharpening=0.3;edit.fineDetail=0.5;edit.localContrast=0.3;edit.chromaDenoise=0.2;edit.liftShadows=0.2
        let prepared=try JPEGRenderer.prepare(cleanImage,extent:cleanImage.extent,options:edit,context:context)
        let direct=try JPEGRenderer.encode(prepared,options:edit,context:context)
        let wrapper=try JPEGRenderer.render(cleanImage,extent:cleanImage.extent,options:edit,context:context)
        let directBitmap=try bitmap(direct.data),wrapperBitmap=try bitmap(wrapper.data)
        try require(rmse(directBitmap,against:reference)>0.5,"Shared Metal preparation ignored detail/shadow edits")
        try require(rmse(directBitmap,against:wrapperBitmap)<0.05,"Shared renderer applied the preparation a second time")
        let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        var previous:Float=0
        for level in [Float(0.25),1,4,64] {
            let components:[Float]=[level,level/2,level/4,1]
            let bytes=components.withUnsafeBufferPointer { Data(buffer:$0) }
            let input=CIImage(bitmapData:bytes,bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:linear)
            let output=try AdaptiveHDR.rollOff(input,gain:16,headroom:4)
            var pixel=[Float](repeating:0,count:4)
            pixel.withUnsafeMutableBytes { context.render(output,toBitmap:$0.baseAddress!,rowBytes:16,bounds:input.extent,format:.RGBAf,colorSpace:linear) }
            try require(pixel[0].isFinite && pixel[0]>previous && pixel[0]<4,"HDR roll-off clipped highlight ordering or exceeded its headroom")
            try require(abs(pixel[1]/pixel[0]-0.5)<0.002 && abs(pixel[2]/pixel[0]-0.25)<0.002,"HDR roll-off changed highlight chromaticity")
            previous=pixel[0]
        }
        log("METAL FINISHING / HDR ROLL-OFF CHECKS PASSED · synthetic host images")

        let calibration=BayerCalibration(pattern:[0,1,1,2],matrix:[3.2406,-1.5372,-0.4986,-0.9689,1.8758,0.0415,0.0557,-0.204,1.057],neutral:[1,1,1],illuminant:21,orientation:1)
        let halves=(0..<128*128*4).map { Float16(0.04+Double($0%128)/1500).bitPattern.littleEndian }
        let quads=halves.withUnsafeBufferPointer { Data(buffer:$0) }
        let dng=try FusedDNG.encode(quads:quads,width:128,height:128,calibration:calibration,capture:DNGCaptureInfo(exposure:FrameExposure(seconds:0.25,iso:800)))
        let neutralRAW=try ImportedPhotoProcessor.process(dng,options:ProcessingOptions())
        var rawEdit=ProcessingOptions();rawEdit.nightStatic=true;rawEdit.postExposure=0.7;rawEdit.saturation=0.4;rawEdit.fineDetail=0.3
        let editedRAW=try ImportedPhotoProcessor.process(dng,options:rawEdit)
        try require(editedRAW.source=="imported-RAW" && editedRAW.raw==dng,"Synthetic DNG import was rejected or lost its original")
        try require(editedRAW.reference==neutralRAW.reference && editedRAW.jpeg != editedRAW.reference,"RAW comparator reference was edited or adjustments ignored")
        try require(rmse(try bitmap(editedRAW.jpeg),against:try bitmap(neutralRAW.jpeg))>0.5,"RAW import bypassed tone/detail/color finishing")
        log("CALIBRATED RAW IMPORT CHECK PASSED · synthetic DNG")
        log("PROCESSOR CHECKS PASSED · synthetic fixtures only")
    }
    static func check017() throws {
        let w=192,h=128,e=CGRect(x:0,y:0,width:w,height:h)
        let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let ctx=CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
        var pixels=[Float](repeating:1,count:w*h*4),matte=pixels,disparity=pixels
        for y in 0..<h { for x in 0..<w {
            let i=(y*w+x)*4,person=(x>=70 && x<122) || (x>=121 && x<125 && y>32 && y<96)
            let value:Float=person ? 0.8:0.08
            for c in 0..<3 { pixels[i+c]=value;matte[i+c]=person ? 1:0;disparity[i+c]=x<96 ? 0.7:0.2 }
        } }
        func image(_ p:[Float])->CIImage { CIImage(bitmapData:p.withUnsafeBufferPointer{Data(buffer:$0)},bytesPerRow:w*16,size:e.size,format:.RGBAf,colorSpace:linear) }
        func read(_ image:CIImage)->[Float] {
            var values=[Float](repeating:0,count:w*h*4)
            values.withUnsafeMutableBytes { ctx.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:e,format:.RGBAf,colorSpace:linear) };return values
        }
        let guide=image(pixels),mask=image(matte)
        let soft=mask.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:3]).cropped(to:e)
        let refined=read(PortraitProcessor.guidedMask(soft,guide:guide,extent:e,radius:3,epsilon:0.0001)),blurred=read(soft)
        let inside=(64*w+123)*4,outside=(64*w+127)*4
        try require(refined[inside]-refined[outside]>blurred[inside]-blurred[outside]+0.15,"Guided filter failed to restore the fine foreground boundary")
        try require(refined.allSatisfy(\.isFinite),"Guided mask generated non-finite values")
        let depth=PortraitDepth(disparity:image(disparity),validity:CIImage(color:.white).cropped(to:e))
        try require(depth.aligned(to:CGRect(x:0,y:0,width:384,height:256)) != nil && depth.aligned(to:CGRect(x:0,y:0,width:256,height:384))==nil,"Depth was stretched across incompatible orientation")
        let bokeh=try PortraitProcessor.apply(guide,mask:mask,extent:e,amount:1,depth:depth,context:ctx)
        let rendered=read(bokeh)
        try require(rendered.allSatisfy(\.isFinite) && abs(rendered[(64*w+90)*4]-0.8)<0.02,"Hybrid depth bokeh damaged foreground / generated invalid pixels")
        var textured=pixels,layered=disparity
        for y in 0..<h { for x in 0..<w {
            let i=(y*w+x)*4,person=matte[i]>0.5
            for c in 0..<3 {
                textured[i+c]=person ? 0.8:((x+y)%2==0 ? 0.6:0.1)
                layered[i+c]=person || x<70 ? 0.7:0.1
            }
        } }
        let texturedImage=image(textured),layeredDepth=PortraitDepth(disparity:image(layered),validity:CIImage(color:.white).cropped(to:e))
        let progressive=read(try PortraitProcessor.apply(texturedImage,mask:mask,extent:e,amount:1,depth:layeredDepth,context:ctx))
        var nearError:Float=0,farError:Float=0
        for y in 24..<104 { for x in 12..<44 {
            let near=(y*w+x)*4,far=(y*w+x+132)*4
            nearError+=abs(progressive[near]-textured[near]);farError+=abs(progressive[far]-textured[far])
        } }
        try require(farError>nearError+100,"Depth bokeh ignored distance from the focal plane")
        // A native 12 MP anchor keeps its fine spatial detail: support supplies
        // only a low-frequency correction, never the final output dimensions.
        let nativeExtent=CGRect(x:0,y:0,width:4032,height:3024)
        let native=CIImage(color:CIColor(red:0.1,green:0.12,blue:0.14)).cropped(to:nativeExtent)
        let support=CIImage(color:CIColor(red:0.11,green:0.13,blue:0.15)).cropped(to:CGRect(x:0,y:0,width:1280,height:960))
        let hybrid=HybridZSL.inject(native:native,support:support)
        try require(hybrid.extent==nativeExtent,"Hybrid ZSL lost the native 12 MP geometry")
        let unchanged=HybridZSL.inject(native:guide,support:guide)
        let same=read(unchanged)
        try require(zip(same,read(guide)).allSatisfy{abs($0-$1)<0.002},"Zero ZSL correction changed native high-frequency detail")
        log("Guided edges, registered disparity and native-anchor ZSL passed")
    }

}
