import CoreImage

struct ImageStatistics {
    let histogram: [Double]
    let shadows: Double
    let highlights: Double

    /// Statistics of a bounded sRGB result preview, not sensor RAW or a live meter.
    static func measure(_ data: Data) -> ImageStatistics? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = min(1, 256 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = small.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { CIContext().render(small, toBitmap: $0.baseAddress!, rowBytes: width * 4,
            bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        var counts = [Double](repeating: 0, count: 64), dark = 0.0, bright = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2])]
            let y = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
            counts[min(63, Int(y / 4))] += 1
            if rgb.max()! <= 3 { dark += 1 }
            if rgb.max()! >= 252 { bright += 1 }
        }
        let count = Double(width * height)
        return ImageStatistics(histogram: counts.map { $0 / count }, shadows: dark / count, highlights: bright / count)
    }
}
