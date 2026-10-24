import CoreImage

/// Robust RGB residual estimate, not a calibrated Bayer shot/read-noise model.
enum NoiseAwareMerger {
    static func threshold(_ image: CIImage, reference: CIImage, extent: CGRect, context: CIContext, sigma: Double) -> Double {
        let factor = min(1, 256 / max(extent.width, extent.height))
        let difference = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: reference])
            .cropped(to: extent).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let bounds = difference.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return 0.12 }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(difference, toBitmap: $0.baseAddress!, rowBytes: width * 16,
            bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) }
        var residuals = [Float](); residuals.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let y = pixels[i] * 0.2126 + pixels[i+1] * 0.7152 + pixels[i+2] * 0.0722
            if y.isFinite { residuals.append(y) }
        }
        guard !residuals.isEmpty else { return 0.12 }
        residuals.sort()
        // Median is robust only while most sampled pixels are static. Bounds
        // deliberately prevent a moving/exposure-changed scene accepting everything.
        return min(0.18, max(0.012, Double(residuals[residuals.count / 2]) * sigma / 0.67449))
    }

    static func blend(_ image: CIImage, reference: CIImage, extent: CGRect, threshold: Double) throws -> CIImage {
        guard let result = kernel?.apply(extent: extent, arguments: [image, reference, threshold]) else {
            throw CameraFailure.message("No se pudo aplicar el rechazo adaptativo.")
        }
        return result
    }

    private static let kernel = CIColorKernel(source: """
        kernel vec4 stable(__sample p, __sample r, float threshold) {
            float delta = dot(abs(p.rgb - r.rgb), vec3(0.2126, 0.7152, 0.0722));
            float weight = 1.0 - smoothstep(threshold, threshold * 1.8, delta);
            return mix(r, p, weight);
        }
        """)
}
