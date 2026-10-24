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
        try check(try JSONDecoder().decode(ProcessingOptions.self, from: Data("{}".utf8)) == base, "Old profile defaults changed")
        var invalid = base; invalid.gamma = .nan
        try rejects({ _ = try invalid.validated() }, "NaN recipe")
        try rejects({ _ = try JSONDecoder().decode(ProcessingOptions.self, from: Data("{\"gamma\":8}".utf8)) }, "Out of range recipe")
        let image = fixture()
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
        print("Validated recipes, LUTs/domains, rendering kernels, residual mesh, adaptive rejection, crop/P3, histogram, profile persistence and legacy passthrough.")
    }
}
