import Foundation
import CoreImage
import ImageIO

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

    static func png(seed: UInt64, noise: Int = 0, dx: Int = 0, dy: Int = 0) throws -> Data {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let delta = noise == 0 ? 0 : Int((state >> 32) % UInt64(noise * 2 + 1)) - noise
                    pixels[(y * size + x) * 4 + channel] = UInt8(clamping: clean(x - dx, y - dy) + delta)
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

    static func main() throws {
        let processor = BurstProcessor()
        let reference = try bitmap(png(seed: 1))
        let noisy = try [png(seed: 10, noise: 24), png(seed: 20, noise: 24), png(seed: 30, noise: 24)]
        let denoised = try processor.process(noisy)
        try require(denoised.mergedFrames == 3, "Noise fixture did not merge all frames")
        let individual = rmse(try bitmap(noisy[0]), against: reference)
        let merged = rmse(try bitmap(denoised.jpeg), against: reference)
        print("Noise RMSE: individual=\(individual), merged=\(merged)")
        try require(merged < individual * 0.85, "Averaging did not reduce fixture noise sufficiently")

        let translated = try processor.process([png(seed: 1), png(seed: 1, dx: 5, dy: -3), png(seed: 1, dx: -4, dy: 2)])
        try require(translated.mergedFrames == 3, "Translation fixture did not merge all frames")
        let result = try bitmap(translated.jpeg)
        var best = Double.infinity
        // The output is cropped to the overlap; find the corresponding reference origin.
        for y in 0...10 { for x in 0...10 {
            best = min(best, rmse(result, against: reference, offsetX: x, offsetY: y))
        } }
        print("Translated fixture best RMSE=\(best), output=\(result.width)x\(result.height)")
        try require(best < 8, "Translation direction or fusion introduces ghosting in a static fixture")
        print("PROCESSOR CHECKS PASSED · synthetic fixtures only")
    }
}
