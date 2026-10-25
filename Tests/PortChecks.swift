import Foundation
import CoreImage
import ImageIO
import Darwin

/// Synthetic host checks exercise the production implementation. No camera or
/// device quality claims follow from passing these fixtures.
@main struct PortChecks {
    static let context = CIContext(options: [.useSoftwareRenderer: true])
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static func check(_ value: Bool, _ text: String) throws { if !value { throw CameraFailure.message(text) } }
    static func rejects(_ body: () throws -> Void, _ text: String) throws {
        do { try body() } catch { return }
        throw CameraFailure.message("Accepted invalid input: " + text)
    }
    static func cube(_ n: Int, domain: String = "") throws -> CubeLUT {
        var text = "TITLE \"Identity\"\nLUT_3D_SIZE \(n)\n" + domain
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            text += "\(Float(r)/Float(n-1)) \(Float(g)/Float(n-1)) \(Float(b)/Float(n-1))\n"
        } } }
        return try CubeLUT.parse(Data(text.utf8))
    }
    static func pixels(_ image: CIImage) -> [Float] {
        let bounds = image.extent.integral
        var result = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
            bounds: bounds, format: .RGBAf, colorSpace: space) }
        return result
    }
    static func difference(_ a: CIImage, _ b: CIImage) -> Double {
        let aa = pixels(a), bb = pixels(b)
        return zip(aa,bb).enumerated().filter { $0.offset % 4 != 3 }.map { abs(Double($0.element.0-$0.element.1)) }.reduce(0,+) / Double(aa.count / 4 * 3)
    }
    static func fixture() -> CIImage {
        var data = [UInt8](repeating: 255, count: 96*96*4)
        for y in 0..<96 { for x in 0..<96 { for c in 0..<3 {
            data[(y*96+x)*4+c] = UInt8(30 + (x*13+y*7+c*53)%190)
        } } }
        return CIImage(bitmapData: Data(data), bytesPerRow: 96*4, size: CGSize(width: 96,height:96), format: .RGBA8, colorSpace: space)
    }
    static func main() {
        do { try run(); print("PORT CHECKS PASSED") }
        catch { fputs("PORT CHECK FAILED: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let base = ProcessingOptions()
        var meterOptions=PreviewAnalysisOptions();meterOptions.peaking=true;meterOptions.zebras=true
        var luma=[UInt8](repeating:91,count:12*8)
        for y in 0..<8 { for x in 0..<8 { luma[y*12+x] = x<4 ? 0:255 } }
        let meter=luma.withUnsafeBufferPointer { PreviewLumaAnalyzer.measure($0,width:8,height:8,rowBytes:12,videoRange:false,options:meterOptions) }!
        try check(abs(meter.histogram.reduce(0,+)-1)<0.0001 && meter.shadows==0.5 && meter.highlights==0.5 && meter.mean==0.5,
                  "Preview histogram included row padding or used wrong range")
        try check(meter.overlayRGBA[(3*8+3)*4+1]>0,"Peaking missed the synthetic focus edge")
        try check(meter.overlayRGBA[(3*8+1)*4+3]==0,"Peaking painted a flat dark region")
        var limited=[UInt8](repeating:16,count:64)
        for i in 32..<64 { limited[i]=235 }
        let legal=limited.withUnsafeBufferPointer { PreviewLumaAnalyzer.measure($0,width:8,height:8,rowBytes:8,videoRange:true,options:PreviewAnalysisOptions()) }!
        try check(legal.shadows==0.5 && legal.highlights==0.5 && legal.overlayRGBA.allSatisfy {$0==0},"Video range or disabled overlay incorrect")
        try check(luma.withUnsafeBufferPointer { PreviewLumaAnalyzer.measure($0,width:8,height:8,rowBytes:7,videoRange:false,options:meterOptions) } == nil,
                  "Unsafe preview stride accepted")
        let largeLuma=[UInt8](repeating:128,count:640*480)
        let bounded=largeLuma.withUnsafeBufferPointer { PreviewLumaAnalyzer.measure($0,width:640,height:480,rowBytes:640,videoRange:false,options:meterOptions) }!
        try check(bounded.width<=160 && bounded.height<=160 && bounded.overlayRGBA.count<=160*160*4,"Preview analysis exceeded its memory bound")
        try check(PhotoCapturePolicy.priority(requested:.quality,count:1,raw:false,customExposure:false,lockedExposure:false) == .quality,"Automatic photo lost native quality request")
        try check(PhotoCapturePolicy.priority(requested:.balanced,count:1,raw:false,customExposure:false,lockedExposure:false) == .balanced,"Balanced choice ignored")
        for item in [(3,false,false,false),(1,true,false,false),(1,false,true,false),(1,false,false,true)] {
            try check(PhotoCapturePolicy.priority(requested:.quality,count:item.0,raw:item.1,customExposure:item.2,lockedExposure:item.3) == .speed,"Burst/RAW/manual exposure requested ISP fusion")
        }
        var invalidNight = base; invalidNight.nightBudget = .infinity
        try rejects({ _ = try invalidNight.validated() }, "Infinite night budget")
        try rejects({ _ = try JSONDecoder().decode(ProcessingOptions.self,from:Data("{\"nightShutterLimit\":3}".utf8)) }, "Unsafe night shutter limit")
        try check(try JSONDecoder().decode(ProcessingOptions.self, from: Data("{}".utf8)) == base, "Old profile defaults changed")
        var invalid = base; invalid.gamma = .nan
        try rejects({ _ = try invalid.validated() }, "NaN recipe")
        try rejects({ _ = try JSONDecoder().decode(ProcessingOptions.self, from: Data("{\"gamma\":8}".utf8)) }, "Out of range recipe")
        let image = fixture()
        let portraitBounds=CGRect(x:0,y:0,width:256,height:128)
        var portraitBytes=[UInt8](repeating:255,count:256*128*4)
        for y in 0..<128 { for x in 0..<256 {
            let i=(y*256+x)*4,person=(80..<176).contains(x)
            portraitBytes[i]=person ? 255:0;portraitBytes[i+1]=0
            portraitBytes[i+2]=person ? 0:(((x+y)%2==0) ? 255:40)
        } }
        let portraitInput=CIImage(bitmapData:Data(portraitBytes),bytesPerRow:256*4,size:portraitBounds.size,format:.RGBA8,colorSpace:space)
        let portraitMask=CIImage(color:.white).cropped(to:CGRect(x:80,y:0,width:96,height:128))
            .composited(over:CIImage(color:.black).cropped(to:portraitBounds))
        let bokeh=try PortraitProcessor.apply(portraitInput,mask:portraitMask,extent:portraitBounds,amount:1)
        let portraitPixels=pixels(bokeh)
        try check(portraitPixels[(64*256+128)*4]>0.99 && portraitPixels[(64*256+128)*4+2]<0.01,
                  "Portrait blurred foreground interior")
        try check(portraitPixels[(64*256+77)*4]<0.02,"Portrait blur leaked foreground red into background")
        try check(difference(bokeh.cropped(to:CGRect(x:5,y:5,width:40,height:40)),portraitInput.cropped(to:CGRect(x:5,y:5,width:40,height:40)))>0.03,
                  "Portrait did not blur the textured background")
        try check(try difference(PortraitProcessor.apply(portraitInput,mask:portraitMask,extent:portraitBounds,amount:0),portraitInput)<0.0001,
                  "Disabled portrait altered pixels")
        var portraitOptions=base;portraitOptions.portraitAmount=0.7
        try check(try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(portraitOptions))==portraitOptions,
                  "Portrait strength did not survive profile serialization")
        portraitOptions.portraitAmount = .nan
        try rejects({ _=try portraitOptions.validated() },"Nonfinite portrait strength")
        print("PORTRAIT COMPOSITING CHECKS PASSED · synthetic matte, not person model quality")
        try check(try difference(AdvancedProcessor.apply(image, options: base), image) < 0.0001, "Neutral processing modifies image")
        for n in [2,3] {
            let lut = try cube(n)
            try check(try difference(lut.apply(to: image, intensity: 1), image) < 0.02, "Identity LUT changes color: \(n)")
            try check(try difference(lut.apply(to: image, intensity: 0), image) < 0.0001, "Zero LUT intensity changes image")
        }
        let identity = try cube(2)
        var swappedValues = [Float]()
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { swappedValues.append(contentsOf: [Float(b), Float(g), Float(r), 1]) } } }
        let swap = CubeLUT(title: "Swap", dimension: 2, rgba: swappedValues.withUnsafeBufferPointer { Data(buffer: $0) }, domainMin: [0,0,0], domainMax: [1,1,1])
        let red = CIImage(color: CIColor(red: 1,green:0,blue:0)).cropped(to:image.extent)
        let blue = CIImage(color: CIColor(red:0,green:0,blue:1)).cropped(to:image.extent)
        try check(try difference(swap.apply(to:red,intensity:1),blue) < 0.01, "LUT RGB indexing is reversed")
        var broken = identity.rgba
        broken.replaceSubrange(0..<4, with: withUnsafeBytes(of: Float.nan) { Data($0) })
        try rejects({ _ = try CubeLUT(title:"Bad",dimension:2,rgba:broken,domainMin:[0,0,0],domainMax:[1,1,1]).validated() }, "Nonfinite LUT samples")
        let remapped = try cube(3, domain: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n")
        let table = remapped.resampledData()
        let lastR = table.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: table.count-16, as: Float.self) }
        try check(abs(lastR-0.5) < 0.0001, "DOMAIN_MAX resampling uses wrong coordinates")
        try rejects({ _ = try CubeLUT.parse(Data("LUT_3D_SIZE 64\n0 0 0".utf8)) }, "Truncated LUT")
        try rejects({ _ = try CubeLUT.parse(Data("LUT_3D_SIZE 9999999".utf8)) }, "Huge LUT")
        try rejects({ _ = try CubeLUT.parse(Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1".utf8)) }, "1D LUT")
        func pngTable(edge:Int, layout:PNGLUTLayout?, swapped:Bool=false, transparent:Bool=false) throws -> Data {
            let level=Int(Double(edge).squareRoot())
            let width=layout == nil ? edge*edge : edge*level
            let height=layout == nil ? edge : width
            var bytes=[UInt8](repeating:255,count:width*height*4)
            for y in 0..<height { for x in 0..<width {
                let r:Int,g:Int,b:Int
                if layout == nil { r=x%edge;g=y;b=x/edge }
                else if layout == .agcTiles { r=x%edge;g=y%edge;b=(y/edge)*level+x/edge }
                else { let index=y*width+x;r=index%edge;g=(index/edge)%edge;b=index/(edge*edge) }
                let channels=swapped ? [b,g,r] : [r,g,b]
                for c in 0..<3 { bytes[(y*width+x)*4+c]=UInt8((Double(channels[c])*255/Double(edge-1)).rounded()) }
            } }
            if transparent { bytes[3]=0 }
            let provider=CGDataProvider(data:Data(bytes) as CFData)!
            let cg=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:space,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let data=NSMutableData(),dest=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(dest,cg,nil)
            try check(CGImageDestinationFinalize(dest),"Cannot encode PNG LUT fixture")
            return data as Data
        }
        for layout in PNGLUTLayout.allCases {
            let lut=try PNGLUT.parse(pngTable(edge:9,layout:layout),layout:layout,name:"Synthetic identity")
            try check(lut.dimension==9 && difference(lut.apply(to:image,intensity:1),image)<0.02,
                      "PNG layout/profile/orientation corrupts identity: \(layout)")
            let swapPNG=try PNGLUT.parse(pngTable(edge:4,layout:layout,swapped:true),layout:layout,name:"Swapped")
            try check(difference(swapPNG.apply(to:red,intensity:1),blue)<0.01,"PNG LUT channel or slice indexing differs from .cube")
        }
        let stripLUT=try PNGLUT.parse(pngTable(edge:81,layout:nil),layout:.agcTiles,name:"Large strip")
        try check(stripLUT.dimension==64 && difference(stripLUT.apply(to:image,intensity:1),image)<0.02,
                  "PNG strip downsampling mixes unrelated blue slices")
        try rejects({ _ = try PNGLUT.parse(pngTable(edge:4,layout:.agcTiles,transparent:true),layout:.agcTiles,name:"Bad") },"Transparent PNG LUT")
        try rejects({ _ = try PNGLUT.parse(Data("not PNG".utf8),layout:.agcTiles,name:"Bad") },"Invalid PNG LUT")
        print("PNG LUT checks: AGC tiles, standard Hald, channel swap, strip, 81-to-64 interpolation and invalid files")
        var tuned = base
        tuned.chromaDenoise = 0.5; tuned.localContrast = 0.3; tuned.fineDetail = 0.2
        tuned.highlightCompression = 0.2; tuned.vibrance = 0.2; tuned.gamma = 1.1; tuned.vignette = 0.2
        let rendered = try AdvancedProcessor.apply(image, options: tuned)
        try check(pixels(rendered).allSatisfy(\.isFinite), "Nonfinite advanced processing")
        try check(difference(rendered,image) > 0.005, "Advanced controls do not affect output")
        let neutral = CIImage(color: CIColor(red: 0.25,green:0.25,blue:0.25)).cropped(to: image.extent)
        var texture = base; texture.chromaDenoise = 1; texture.localContrast = 1; texture.fineDetail = 1
        try check(try difference(AdvancedProcessor.apply(neutral,options:texture),neutral) < 0.002, "Texture controls alter a flat neutral field")
        let zeros = [CIVector](repeating: CIVector(x:0,y:0),count:9)
        try check(try difference(LocalAlignment.warp(image,extent:image.extent,offsets:zeros),image) < 0.001, "Identity warp changes pixels")
        let shift = [CIVector](repeating: CIVector(x:2,y:-1),count:9)
        let roi = CGRect(x:8,y:8,width:80,height:80)
        let warped = try LocalAlignment.warp(image,extent:image.extent,offsets:shift).cropped(to:roi)
        let expected = image.transformed(by:CGAffineTransform(translationX:2,y:-1)).cropped(to:roi)
        try check(difference(warped,expected) < 0.003, "Residual warp sign or ROI incorrect")
        let white = CIImage(color: CIColor.white).cropped(to: image.extent)
        let stable = try NoiseAwareMerger.blend(white,reference:neutral,extent:image.extent,threshold:0.05)
        try check(difference(stable,neutral) < 0.001, "Adaptive mask accepts moving bright region")
        let threshold = NoiseAwareMerger.threshold(white,reference:neutral,extent:image.extent,context:context,sigma:3)
        try check(threshold <= 0.18 && threshold >= 0.012, "Unbounded adaptive noise estimate")
        let png = context.pngRepresentation(of:image,format:.RGBA8,colorSpace:space)!
        var output = base; output.aspect = .wide; output.outputColor = .displayP3; output.jpegQuality = 0.9
        let result = try BurstProcessor().process([png],options:output)
        let large = image.transformed(by:CGAffineTransform(scaleX:32,y:32))
        let largePNG = context.pngRepresentation(of:large,format:.RGBA8,colorSpace:space)!
        let preview = PreviewDecoder.image(largePNG)!
        try check(max(preview.width,preview.height) <= 1600, "Review preview exceeds memory bound")
        try check(PreviewDecoder.image(Data("bad image".utf8)) == nil, "Invalid review data accepted")
        let cancellation = ProcessingCancellation(); cancellation.cancel()
        try rejects({ _ = try BurstProcessor().process([png],cancellation:cancellation) }, "Cancelled processing")
        let during = ProcessingCancellation()
        try rejects({
            _ = try BurstProcessor().process([png,png], options: ProcessingOptions(chooseSharpestReference:false), cancellation:during) { text in
                if text.hasPrefix("Procesando fotograma") { during.cancel() }
            }
        }, "Cancellation after processing started")
        let rotatedData = NSMutableData()
        let rotatedDestination = CGImageDestinationCreateWithData(rotatedData,"public.jpeg" as CFString,1,nil)!
        let rectangle = context.createCGImage(image,from:CGRect(x:0,y:0,width:96,height:48))!
        CGImageDestinationAddImage(rotatedDestination,rectangle,[kCGImagePropertyOrientation:6] as CFDictionary)
        try check(CGImageDestinationFinalize(rotatedDestination), "Could not encode orientation fixture")
        let rotatedPreview = PreviewDecoder.image(rotatedData as Data)!
        try check(rotatedPreview.width == 48 && rotatedPreview.height == 96, "Review preview ignored EXIF rotation")
        let source = CGImageSourceCreateWithData(result.jpeg as CFData,nil)!
        let cg = CGImageSourceCreateImageAtIndex(source,0,nil)!
        try check(cg.width == 96 && cg.height == 54, "16:9 output is not cropped correctly")
        try check(cg.colorSpace?.name == CGColorSpace.displayP3, "Display P3 JPEG lost its profile")
        let stats = ImageStatistics.measure(result.jpeg)!
        try check(abs(stats.histogram.reduce(0,+)-1) < 0.0001, "Histogram is not normalized")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file = dir.appendingPathComponent("profiles.json")
        let profiles = ProcessingProfiles(file:file)
        profiles.remember(tuned,lens:"wide")
        try profiles.save(name:"Synthetic",options:tuned)
        profiles.flush()
        let restored = ProcessingProfiles(file:file)
        try check(restored.profiles.count == 1 && restored.options(for:"wide") == tuned, "Profiles not restored from disk")
        let document = try profiles.exportDocument(name:"Test",options:tuned)
        try check(try ProfileDocumentData.decode(document).options == tuned, "Profile JSON round trip failed")
        try rejects({ _ = try ProfileDocumentData.decode(Data("{\"format\":\"Android\",\"version\":1,\"name\":\"x\",\"options\":{}}".utf8)) }, "Foreign profile schema")
        try rejects({ try profiles.save(name:"   ",options:base) }, "Empty profile name")
        let corrupt = dir.appendingPathComponent("corrupt.json")
        try Data("not JSON".utf8).write(to:corrupt)
        let unreadable = ProcessingProfiles(file:corrupt)
        unreadable.remember(base,lens:"wide")
        try rejects({ try unreadable.save(name:"Do not overwrite",options:base) }, "Saving over corrupt archive")
        unreadable.flush()
        try check(try Data(contentsOf:corrupt) == Data("not JSON".utf8), "Corrupt profile archive was overwritten")
        try check(try BurstProcessor().process([png]).jpeg == png, "Untouched single-photo passthrough changed")
        let plan = try HDRCapturePlan.make(iso:100,seconds:1.0/60,span:2,isoRange:25...3200,durationRange:(1.0/8000)...1)
        try check(plan.count == 3 && abs(log2(plan[1].product/plan[0].product)+2) < 0.001 && abs(log2(plan[2].product/plan[0].product)-2) < 0.001, "HDR planner changed target bracket")
        var hdr = base; hdr.hdrBracketing=true
        try rejects({ _ = try HDRProcessor().process([png,png,png],exposures:[FrameExposure](repeating:FrameExposure(seconds:0.01,iso:100),count:3),options:hdr) }, "Identical HDR exposures")
        try rejects({ _ = try HDRProcessor().process([png],exposures:plan,options:hdr) }, "Incomplete HDR bracket")
        let bounds = CGRect(x:0,y:0,width:8,height:8)
        let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        func field(_ value: Float) -> CIImage {
            var values = [Float](repeating:value,count:8*8*4)
            for index in stride(from:3,to:values.count,by:4) { values[index]=1 }
            return CIImage(bitmapData:values.withUnsafeBufferPointer { Data(buffer:$0) },bytesPerRow:8*16,size:CGSize(width:8,height:8),format:.RGBAf,colorSpace:linear)
        }
        let recovered = try HDRProcessor.fuse(field(1),field(2),field(0.25),scales:CIVector(x:1,y:0.25,z:4),extent:bounds)
        var radiance = [Float](repeating:0,count:8*8*4)
        radiance.withUnsafeMutableBytes { context.render(recovered,toBitmap:$0.baseAddress!,rowBytes:8*16,bounds:bounds,format:.RGBAf,colorSpace:linear) }
        try check(abs(radiance[0]-2)<0.01, "HDR did not recover unclipped short-exposure radiance")
        // Exercise real file encoding and re-expansion, not just a toggle or
        // an XMP string. The two halves have identical SDR pixels but distinct
        // HDR headroom; a flat gain map cannot satisfy these checks.
        let hdrBounds = CGRect(x:0,y:0,width:256,height:128)
        var hdrSamples = [Float](repeating:1,count:256*128*4)
        var sdrSamples = hdrSamples
        for y in 0..<128 { for x in 0..<256 { for c in 0..<3 {
            sdrSamples[(y*256+x)*4+c] = 0.5
            hdrSamples[(y*256+x)*4+c] = x < 128 ? 0.5 : 2
        } } }
        func hdrFixture(_ values: [Float]) -> CIImage {
            CIImage(bitmapData:values.withUnsafeBufferPointer { Data(buffer:$0) },bytesPerRow:256*16,
                    size:hdrBounds.size,format:.RGBAf,colorSpace:linear)
        }
        let sdrBase=hdrFixture(sdrSamples), hdrOriginal=hdrFixture(hdrSamples)
        var hdrOutput=base;hdrOutput.preserveHDR=true;hdrOutput.aspect = .wide
        let hdrFile=try JPEGRenderer.render(sdrBase,extent:hdrBounds,options:hdrOutput,context:context,hdrSource:hdrOriginal)
        try check(hdrFile.adaptiveHDR && AdaptiveHDR.hasGainMap(hdrFile.data), "Encoded JPEG has no real HDR auxiliary image")
        try check(hdrFile.width==227 && hdrFile.height==128, "HDR aspect crop differs from SDR")
        let hdrDecoded=AdaptiveHDR.expanded(hdrFile.data)!
        let sdrDecoded=CIImage(data:hdrFile.data)!
        func sampleLinear(_ image:CIImage,_ x:Int) -> Float {
            var pixel=[Float](repeating:0,count:4)
            pixel.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,
                bounds:CGRect(x:x,y:64,width:1,height:1),format:.RGBAf,colorSpace:linear) }
            return pixel[0]
        }
        let darkRatio=sampleLinear(hdrDecoded,32)/sampleLinear(sdrDecoded,32)
        let brightRatio=sampleLinear(hdrDecoded,190)/sampleLinear(sdrDecoded,190)
        print("Adaptive HDR round trip: dim ratio=\(darkRatio), highlight ratio=\(brightRatio)")
        try check(abs(darkRatio-1)<0.15 && brightRatio>2.5, "Gain map lost spatial headroom on decoding")
        try check(hdrDecoded.extent.size==sdrDecoded.extent.size,"HDR and SDR decoded geometry differs")
        var brightEdit=hdrOutput;brightEdit.postExposure=2
        let brightFile=try JPEGRenderer.render(sdrBase,extent:hdrBounds,options:brightEdit,context:context,hdrSource:hdrOriginal)
        try check(sampleLinear(AdaptiveHDR.expanded(brightFile.data)!,190)<=8.1,
                  "Super-white edits bypassed bounded SDR base and inflated HDR headroom")
        let ordinary=try JPEGRenderer.render(sdrBase,extent:hdrBounds,options:hdrOutput,context:context)
        try check(!ordinary.adaptiveHDR && !AdaptiveHDR.hasGainMap(ordinary.data),"SDR input was mislabeled HDR")
        let importedHDR=try ImportedPhotoProcessor.process(hdrFile.data,options:hdrOutput)
        try check(AdaptiveHDR.hasGainMap(importedHDR.jpeg) && importedHDR.mergedFrames==1,"HDR import discarded the auxiliary image")
        var untouchedHDR=base;untouchedHDR.preserveHDR=true
        try check(try ImportedPhotoProcessor.process(hdrFile.data,options:untouchedHDR).jpeg==hdrFile.data,
                  "Unedited HDR JPEG was needlessly recompressed")
        var editedHDR=hdrOutput;editedHDR.postExposure = -0.5
        let singleHDR=try BurstProcessor().process([hdrFile.data],options:editedHDR)
        try check(AdaptiveHDR.hasGainMap(singleHDR.jpeg),"Single-photo edits discarded HDR")
        let hdrSource=CGImageSourceCreateWithData(hdrFile.data as CFData,nil)!
        let rotatedHDRData=NSMutableData()
        let rotatedHDRDestination=CGImageDestinationCreateWithData(rotatedHDRData,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(rotatedHDRDestination,CGImageSourceCreateImageAtIndex(hdrSource,0,nil)!,
                                  [kCGImagePropertyOrientation:6] as CFDictionary)
        let auxiliaryType=CGImageSourceCopyAuxiliaryDataInfoAtIndex(hdrSource,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil ?
            kCGImageAuxiliaryDataTypeISOGainMap : kCGImageAuxiliaryDataTypeHDRGainMap
        CGImageDestinationAddAuxiliaryDataInfo(rotatedHDRDestination,auxiliaryType,
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(hdrSource,0,auxiliaryType)!)
        try check(CGImageDestinationFinalize(rotatedHDRDestination),"Cannot encode rotated HDR fixture")
        var rotatedOptions=editedHDR;rotatedOptions.aspect = .original
        let rotatedHDREdit=try ImportedPhotoProcessor.process(rotatedHDRData as Data,options:rotatedOptions)
        let orientedPreview=PreviewDecoder.image(rotatedHDREdit.jpeg)!
        try check(orientedPreview.width==128 && orientedPreview.height==227 && AdaptiveHDR.hasGainMap(rotatedHDREdit.jpeg),
                  "HDR import lost gain map or applied EXIF rotation twice")
        try rejects({ _ = try AdaptiveHDR.companion(base:sdrBase,originalSDR:sdrBase,
            originalHDR:hdrOriginal.cropped(to:bounds),extent:hdrBounds) },"Mismatched HDR geometry")
        try check(try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(hdrOutput)).preserveHDR,
                  "HDR option did not survive a profile round trip")
        let black = try HDRProcessor.fuse(field(0),field(0),field(0),scales:CIVector(x:1,y:0.25,z:4),extent:bounds)
        try check(pixels(black).allSatisfy(\.isFinite), "HDR black fallback produced NaN")
        let temporal = WeightedTemporalMerger(reference:field(0.1),context:context)
        _ = try temporal.append(field(0.15),extent:bounds,rejectMotion:true,sigma:3)
        _ = try temporal.append(field(0.95),extent:bounds,rejectMotion:true,sigma:3)
        let temporalMean = try temporal.append(field(0.2),extent:bounds,rejectMotion:true,sigma:3)
        var linearPixels = [Float](repeating:0,count:8*8*4)
        linearPixels.withUnsafeMutableBytes { context.render(temporalMean,toBitmap:$0.baseAddress!,rowBytes:8*16,bounds:bounds,format:.RGBAf,colorSpace:linear) }
        try check(abs(linearPixels[0]-0.15)<0.003,"Rejected temporal sample added reference weight or corrupted the running mean")
        let unweighted = WeightedTemporalMerger(reference:field(0.1),context:context)
        _ = try unweighted.append(field(0.15),extent:bounds,rejectMotion:false,sigma:3)
        let simpleMean = try unweighted.append(field(0.95),extent:bounds,rejectMotion:false,sigma:3)
        linearPixels.withUnsafeMutableBytes { context.render(simpleMean,toBitmap:$0.baseAddress!,rowBytes:8*16,bounds:bounds,format:.RGBAf,colorSpace:linear) }
        try check(abs(linearPixels[0]-0.4)<0.003,"Temporal mean without rejection is not an arithmetic mean")
        let imported = try ImportedPhotoProcessor.process(rotatedData as Data,options:base)
        try check(imported.jpeg == rotatedData as Data && imported.mergedFrames == 1 && imported.source == "imported-rendered-image","Untouched imported JPEG was recoded or treated as a burst")
        var importRecipe = base; importRecipe.nightStatic=true; importRecipe.hdrBracketing=false;importRecipe.postExposure=0.5
        let importedEdit = try ImportedPhotoProcessor.process(rotatedData as Data,options:importRecipe)
        let importedCG = PreviewDecoder.image(importedEdit.jpeg)!
        try check(importedCG.width == 48 && importedCG.height == 96 && importedEdit.raw == nil,"Imported image orientation/RAW handling is wrong")
        let importedPNG = try ImportedPhotoProcessor.process(png,options:base)
        let importedType=CGImageSourceGetType(CGImageSourceCreateWithData(importedPNG.reference as CFData,nil)!)! as String
        try check(importedType == "public.jpeg","Non-JPEG import was mislabeled as JPEG")
        try rejects({ _ = try ImportedPhotoProcessor.process(Data("not an image".utf8),options:base) },"Invalid imported data")
        try rejects({ _ = try ImportedPhotoProcessor.process(png,options:base,cancellation:cancellation) },"Cancelled import")
        print("NATIVE POLICY / WEIGHTED TEMPORAL / IMPORT CHECKS PASSED · synthetic host fixtures only")
        let neutralRecipe = ColorRecipe()
        let neutralCube = try ColorRecipeLUT.make(neutralRecipe,dimension:9)
        try check(try difference(neutralCube.apply(to:image,intensity:1),image)<0.02, "Neutral color recipe changes color")
        var hsl = neutralRecipe; hsl.hsl[0].saturation = -1
        let adjustedRed = ColorRecipeLUT.transform([0.8,0.1,0.1],recipe:hsl)
        try check(adjustedRed.max()!-adjustedRed.min()! < 0.5, "Red HSL control did not reduce chroma")
        let gray = ColorRecipeLUT.transform([0.3,0.3,0.3],recipe:hsl)
        try check(abs(gray[0]-gray[1])<0.0001, "Selective HSL tinted an achromatic pixel")
        var grade = neutralRecipe;grade.shadows=GradeWheel(hue:220,amount:0.6)
        let tinted = ColorRecipeLUT.transform([0.2,0.2,0.2],recipe:grade)
        try check(tinted[2]>tinted[0]+0.02, "Shadow wheel did not add blue chroma")
        var curveRecipe = neutralRecipe;curveRecipe.redCurve[2]=0.8
        try check(ColorRecipeLUT.transform([0.5,0.5,0.5],recipe:curveRecipe)[0]>0.75, "Red curve not applied")
        var invalidColor = neutralRecipe;invalidColor.hsl=[]
        try rejects({ _ = try invalidColor.validated() }, "Missing HSL bands")
        var grainOptions=base;grainOptions.color.grain=0.5
        let grainImage = try AdvancedProcessor.apply(neutral,options:grainOptions)
        try check(difference(grainImage,neutral)>0.001 && pixels(grainImage).allSatisfy(\.isFinite), "Grain kernel has no effect or produces nonfinite pixels")
        var fullColor=base;fullColor.color=grade;fullColor.color.redCurve=curveRecipe.redCurve
        fullColor.nightBudget=16; fullColor.nightShutterLimit=0.125; fullColor.nightWeightedFusion=false; fullColor.singlePhotoQuality = .balanced
        let roundTrip=try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(fullColor))
        try check(roundTrip == fullColor,"Color recipe did not survive profile serialization")
        print("Validated recipes, LUTs/domains, rendering kernels, residual mesh, adaptive rejection, crop/P3, histogram, profile persistence, bounded/oriented previews, cooperative cancellation and legacy passthrough.")
    }
}
