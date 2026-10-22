import CoreImage
import ImageIO
import Vision

struct CaptureResult {
    let jpeg: Data
    let reference: Data
    let details: String
    let mergedFrames: Int
}

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

/// First experiment: global translation and equal-weight mean in linear RGB.
/// No HDR merge, local motion correction, RAW processing or Google code.
final class BurstProcessor {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    func process(_ frames: [Data]) throws -> CaptureResult {
        guard let first = frames.first else { throw CameraFailure.message("No hay imágenes.") }
        if frames.count == 1 {
            return CaptureResult(jpeg: first, reference: first, details: "Foto individual, procesada por el sistema.", mergedFrames: 1)
        }
        // Limit the working image size to bound memory on the iPhone 11 Pro.
        func decode(_ data: Data) throws -> CIImage {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw CameraFailure.message("No se pudo leer una foto.")
            }
            let factor = min(1, 2560 / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                           y: -scaled.extent.minY))
        }
        let reference = try decode(first)
        var accumulator = reference
        var common = reference.extent
        var accepted = 1
        for frame in frames.dropFirst() {
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
                let aligned = image.transformed(by: transform)
                let overlap = common.intersection(aligned.extent).integral
                    .intersection(reference.extent)
                guard overlap.width > reference.extent.width * 0.9,
                      overlap.height > reference.extent.height * 0.9 else { return }
                // Maintain a running mean, forcing evaluation after every merge so the
                // filter graph does not retain a full burst of decoded images.
                let count = CGFloat(accepted)
                let a = scale(accumulator.cropped(to: overlap), by: count / (count + 1))
                let b = scale(aligned.cropped(to: overlap), by: 1 / (count + 1))
                let mean = a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
                    .cropped(to: overlap)
                guard let rendered = context.createCGImage(mean, from: overlap, format: .RGBAh,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { return }
                accumulator = CIImage(cgImage: rendered).transformed(by:
                    CGAffineTransform(translationX: overlap.minX, y: overlap.minY))
                common = overlap
                accepted += 1
            }
        }
        guard accepted > 1 else {
            return CaptureResult(jpeg: first, reference: first,
                                 details: "No se pudo alinear la pila. Se conserva la primera foto sin fusionar.", mergedFrames: 1)
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
        return CaptureResult(jpeg: data as Data, reference: first,
            details: "Fusionadas \(accepted)/\(frames.count) fotos. \(cg.width) × \(cg.height) px. Alineación por traslación; puede producir dobles contornos si algo se mueve.", mergedFrames: accepted)
    }

    private func scale(_ image: CIImage, by weight: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
        ])
    }
}
