import CoreImage

/// Original per-pixel weighted temporal mean. Rejected samples add zero weight,
/// rather than repeatedly substituting the noisy reference into a uniform mean.
/// Uses RGB residuals; this is not Google's Bayer/Wiener noise model.
final class WeightedTemporalMerger {
    private(set) var mean: CIImage
    private var weights: CIImage
    private let reference: CIImage
    private let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    init(reference: CIImage, context: CIContext) {
        self.reference = reference; self.mean = reference; self.context = context
        self.weights = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: reference.extent)
    }

    func append(_ image: CIImage, extent: CGRect, rejectMotion: Bool, sigma: Double) throws -> CIImage {
        let threshold = rejectMotion ? NoiseAwareMerger.threshold(image, reference: reference,
            extent: extent, context: context, sigma: sigma) : 1
        func coarse(_ image: CIImage) -> CIImage {
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])
                .cropped(to: extent)
        }
        guard let nextWeights = Self.weightKernel?.apply(extent: extent, arguments: [weights,
            coarse(reference), coarse(image), threshold, rejectMotion ? 1.0 : 0.0]),
              let nextMean = Self.meanKernel?.apply(extent: extent, arguments: [mean, image, weights, nextWeights]),
              let weightBuffer = context.createCGImage(nextWeights, from: extent, format: .RGBAh, colorSpace: space),
              let meanBuffer = context.createCGImage(nextMean, from: extent, format: .RGBAh, colorSpace: space) else {
            throw CameraFailure.message("No se pudo materializar la fusión temporal ponderada.")
        }
        let offset = CGAffineTransform(translationX: extent.minX, y: extent.minY)
        weights = CIImage(cgImage: weightBuffer).transformed(by: offset)
        mean = CIImage(cgImage: meanBuffer).transformed(by: offset)
        return mean
    }

    private static let weightKernel = CIColorKernel(source: """
        kernel vec4 temporalWeight(__sample w, __sample r, __sample p, float threshold, float reject) {
            float delta = dot(abs(p.rgb-r.rgb),vec3(0.2126,0.7152,0.0722));
            float accept = 1.0-reject*smoothstep(threshold,threshold*1.8,delta);
            return vec4(vec3(w.r+accept),1.0);
        }
        """)
    private static let meanKernel = CIColorKernel(source: """
        kernel vec4 temporalMean(__sample mean, __sample p, __sample oldWeight, __sample newWeight) {
            float increment = max(0.0,newWeight.r-oldWeight.r);
            return vec4((mean.rgb*oldWeight.r+p.rgb*increment)/max(newWeight.r,1.0),1.0);
        }
        """)
}
