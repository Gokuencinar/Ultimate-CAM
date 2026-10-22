import CoreImage
import ImageIO
import Vision

struct CaptureResult {
    let jpeg: Data
    let reference: Data
    let details: String
    let mergedFrames: Int
    var raw: Data? = nil
}

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

/// JPEG burst processing with a noise-aware reference selection, translational
/// alignment and conservative rejection of changed areas. No Google code.
final class BurstProcessor {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    func process(_ frames: [Data], options: ProcessingOptions = ProcessingOptions()) throws -> CaptureResult {
        guard let first = frames.first else { throw CameraFailure.message("No hay imágenes.") }
        let adjustments = options.noiseReduction > 0 || options.sharpening > 0 || options.liftShadows > 0
        if frames.count == 1 && !adjustments {
            return CaptureResult(jpeg: first, reference: first, details: "Foto individual, procesada por el sistema.", mergedFrames: 1)
        }
        // Limit the working image size to bound memory on the iPhone 11 Pro.
        func decode(_ data: Data) throws -> CIImage {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw CameraFailure.message("No se pudo leer una foto.")
            }
            // The selectable limit belongs to a multi-frame stack. Editing a
            // single photo must not silently downsample the full-resolution JPEG.
            let limit = frames.count == 1 ? max(image.extent.width, image.extent.height)
                : CGFloat(min(4096, max(1024, options.maximumDimension)))
            let factor = min(1, limit / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                           y: -scaled.extent.minY))
        }
        var referenceIndex = 0
        if options.chooseSharpestReference && frames.count > 1 {
            var best = -Double.infinity
            for (index, frame) in frames.enumerated() {
                let score = try autoreleasepool { sharpness(try decode(frame)) }
                if score > best { best = score; referenceIndex = index }
            }
        }
        let referenceData = frames[referenceIndex]
        let reference = try decode(referenceData)
        var accumulator = reference
        var common = reference.extent
        var accepted = 1
        for (index, frame) in frames.enumerated() where index != referenceIndex {
            try autoreleasepool {
                let image = try decode(frame)
                guard abs(image.extent.width - reference.extent.width) < 1,
                      abs(image.extent.height - reference.extent.height) < 1 else { return }
                // Vision maps the targeted (floating) image into the handler's reference image.
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: image)
                let handler = VNImageRequestHandler(ciImage: reference)
                do { try handler.perform([request]) } catch { return }
                guard let observation = request.results?.first,
                      observation.confidence >= 0.5 else { return }
                let transform = observation.alignmentTransform
                guard abs(transform.tx) < reference.extent.width * 0.04,
                      abs(transform.ty) < reference.extent.height * 0.04 else { return }
                var aligned = image.transformed(by: transform)
                let overlap = common.intersection(aligned.extent).integral
                    .intersection(reference.extent)
                guard overlap.width > reference.extent.width * 0.9,
                      overlap.height > reference.extent.height * 0.9 else { return }
                if options.rejectMotion {
                    let delta = aligned.cropped(to: overlap).applyingFilter("CIDifferenceBlendMode", parameters: [
                        kCIInputBackgroundImageKey: reference.cropped(to: overlap)
                    ])
                    let stable = delta.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
                    ]).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.12])
                        .applyingFilter("CIColorInvert")
                        .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0])
                        .cropped(to: overlap)
                    aligned = aligned.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: reference.cropped(to: overlap), kCIInputMaskImageKey: stable
                    ]).cropped(to: overlap)
                }
                // Maintain a running mean, forcing evaluation after every merge so the
                // filter graph does not retain a full burst of decoded images.
                let count = CGFloat(accepted)
                let mean = accumulator.cropped(to: overlap).applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: aligned.cropped(to: overlap),
                    kCIInputTimeKey: 1 / (count + 1)
                ]).cropped(to: overlap)
                guard let rendered = context.createCGImage(mean, from: overlap, format: .RGBAh,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { return }
                accumulator = CIImage(cgImage: rendered).transformed(by:
                    CGAffineTransform(translationX: overlap.minX, y: overlap.minY))
                common = overlap
                accepted += 1
            }
        }
        guard accepted > 1 || adjustments else {
            return CaptureResult(jpeg: referenceData, reference: referenceData,
                                 details: "No se pudo alinear la pila. Se conserva la referencia sin fusionar.", mergedFrames: 1)
        }
        if options.noiseReduction > 0 {
            accumulator = accumulator.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": min(0.08, options.noiseReduction), "inputSharpness": 0.4
            ])
        }
        if options.liftShadows > 0 {
            accumulator = accumulator.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": min(1, options.liftShadows), "inputHighlightAmount": 0.9
            ])
        }
        if options.sharpening > 0 {
            accumulator = accumulator.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: min(0.8, options.sharpening)
            ])
        }
        guard let cg = context.createCGImage(accumulator, from: common,
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw CameraFailure.message("No se pudo renderizar la pila.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CameraFailure.message("No se pudo crear el JPEG.")
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.message("Error al codificar el JPEG.") }
        let details: String
        if frames.count == 1 {
            details = "Foto individual con ajustes. \(cg.width) × \(cg.height) px."
        } else if accepted == 1 {
            details = "No se pudo alinear la pila. Referencia \(referenceIndex + 1) con ajustes, sin fusión. \(cg.width) × \(cg.height) px."
        } else {
            details = "Fusionadas \(accepted)/\(frames.count) fotos. Referencia \(referenceIndex + 1). \(cg.width) × \(cg.height) px. Rechazo de movimiento: \(options.rejectMotion ? "sí" : "no")."
        }
        return CaptureResult(jpeg: data as Data, reference: referenceData,
            details: details, mergedFrames: accepted)
    }

    private func sharpness(_ image: CIImage) -> Double {
        let factor = min(1, 512 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let edges = small.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1])
            .cropped(to: small.extent)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(edges, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return Double(pixel[0] + pixel[1] + pixel[2])
    }

}
