import CoreImage

/// Original RGB-domain adaptations of the controls identified in AGC's shader
/// pipeline. This is not the Android Bayer merge/demosaic implementation.
enum AdvancedProcessor {
    static func apply(_ image: CIImage, options o: ProcessingOptions) throws -> CIImage {
        let extent = image.extent
        var result = image
        if o.postExposure != 0 { result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: o.postExposure]) }
        if o.chromaDenoise > 0 {
            let blurred = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1 + 2 * o.chromaDenoise]).cropped(to: extent)
            guard let output = chromaKernel?.apply(extent: extent, arguments: [result, blurred, o.chromaDenoise]) else {
                throw CameraFailure.message("No se pudo aplicar la reducción de ruido cromático.")
            }
            result = output
        }
        if o.localContrast > 0 || o.fineDetail > 0 {
            let near = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: extent)
            let far = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: extent)
            guard let output = detailKernel?.apply(extent: extent, arguments: [result, near, far, o.fineDetail, o.localContrast]) else {
                throw CameraFailure.message("No se pudo aplicar el contraste local.")
            }
            result = output
        }
        if o.highlightCompression > 0 {
            guard let output = highlightKernel?.apply(extent: extent, arguments: [result, o.highlightCompression]) else {
                throw CameraFailure.message("No se pudieron comprimir las luces.")
            }
            result = output
        }
        if o.contrast != 1 || o.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: o.contrast, kCIInputSaturationKey: o.saturation])
        }
        if o.vibrance != 0 { result = result.applyingFilter("CIVibrance", parameters: ["inputAmount": o.vibrance]) }
        if o.gamma != 1 { result = result.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / o.gamma]) }
        if o.color.needsCube { result = try ColorRecipeLUT.make(o.color).apply(to:result,intensity:1) }
        if o.color.grain > 0 {
            guard let output = grainKernel?.apply(extent:extent,arguments:[result,o.color.grain,o.color.grainSize]) else {
                throw CameraFailure.message("No se pudo aplicar el grano.")
            }
            result = output
        }
        if let id = o.lutID, o.lutIntensity > 0 { result = try ColorLUTStore.load(id).apply(to: result, intensity: o.lutIntensity) }
        if o.vignette > 0 {
            result = result.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.6,
                kCIInputIntensityKey: o.vignette
            ])
        }
        return result.cropped(to: extent)
    }

    static func crop(_ extent: CGRect, aspect: PhotoAspect) -> CGRect {
        guard aspect != .original else { return extent }
        let ratio: CGFloat = aspect == .square ? 1 : (extent.width >= extent.height ? 16.0 / 9 : 9.0 / 16)
        let width = min(extent.width, extent.height * ratio), height = min(extent.height, extent.width / ratio)
        // Stay inside the input, with integer output pixels.
        return CGRect(x: ceil(extent.midX - width / 2), y: ceil(extent.midY - height / 2), width: floor(width), height: floor(height)).intersection(extent)
    }

    private static let grainKernel = CIColorKernel(source: """
        kernel vec4 grain(__sample p, float amount, float size) {
            vec2 q = floor(destCoord() / size);
            float a = fract(sin(dot(q, vec2(12.9898,78.233))) * 43758.5453);
            float b = fract(sin(dot(q, vec2(39.3467,11.135))) * 23421.631);
            float y = dot(p.rgb, vec3(0.2126,0.7152,0.0722));
            float n = (a+b-1.0) * amount * 0.08 * (0.4+sqrt(max(y,0.0)));
            return vec4(max(p.rgb+vec3(n),vec3(0.0)),p.a);
        }
        """)

    private static let chromaKernel = CIColorKernel(source: """
        kernel vec4 chroma(__sample p, __sample b, float amount) {
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(p.rgb, w), by = dot(b.rgb, w);
            vec3 c = vec3(y) + mix(p.rgb - vec3(y), b.rgb - vec3(by), amount);
            return vec4(max(c, vec3(0.0)), p.a);
        }
        """)
    private static let detailKernel = CIColorKernel(source: """
        kernel vec4 detail(__sample p, __sample near, __sample far, float fine, float clarity) {
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(p.rgb, w), n = dot(near.rgb, w), f = dot(far.rgb, w);
            float delta = fine * (y - n) + clarity * (n - f);
            // Attenuate tiny residuals rather than sharpening flat-field noise.
            delta *= smoothstep(0.001, 0.008, abs(delta));
            float gain = clamp((y + delta) / max(y, 0.0001), 0.5, 1.5);
            return vec4(max(p.rgb * gain, vec3(0.0)), p.a);
        }
        """)
    private static let highlightKernel = CIColorKernel(source: """
        kernel vec4 highlights(__sample p, float strength) {
            float peak = max(p.r, max(p.g, p.b));
            float mapped = peak / (1.0 + strength * max(0.0, peak - 0.25));
            return vec4(p.rgb * (peak > 0.00001 ? mapped / peak : 1.0), p.a);
        }
        """)
}
