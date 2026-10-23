import CoreImage
import ImageIO
import Vision

struct CaptureResult {
    let jpeg: Data
    let reference: Data
    let details: String
    let mergedFrames: Int
    var raw: Data? = nil
    var source = "JPEG"
}

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

/// RAW / JPEG burst processing with a noise-aware reference selection, translational
/// alignment and conservative rejection of changed areas. No Google code.
final class BurstProcessor {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    func process(_ frames: [Data], options: ProcessingOptions = ProcessingOptions(), rawFrames: [Data]? = nil) throws -> CaptureResult {
        guard let first = frames.first else { throw CameraFailure.message("No hay imágenes.") }
        if let rawFrames, rawFrames.count != frames.count {
            throw CameraFailure.message("La pila RAW está incompleta.")
        }
        let inputFrames = rawFrames ?? frames
        let isRAW = rawFrames != nil
        let adjustments = options.nightStatic || options.noiseReduction > 0 || options.sharpening > 0 || options.liftShadows > 0
        if frames.count == 1 && !adjustments && !isRAW {
            return CaptureResult(jpeg: first, reference: first, details: "Foto individual, procesada por el sistema.", mergedFrames: 1)
        }
        // Limit the working image size to bound memory on the iPhone 11 Pro.
        func decode(_ data: Data) throws -> CIImage {
            let image: CIImage
            if isRAW {
                guard let filter = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else {
                    throw CameraFailure.message("No se pudo abrir el DNG para la fusión nocturna.")
                }
                // Gamut mapping is nonlinear and clips noisy negative components
                // before temporal averaging, producing colored shadow bias here.
                filter.isGamutMappingEnabled = false
                filter.shadowBias = 0
                filter.boostShadowAmount = 0
                filter.boostAmount = 0
                filter.baselineExposure = 0
                filter.exposure = 0
                if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
                if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
                if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
                   let value = CGImagePropertyOrientation(rawValue: orientation) { filter.orientation = value }
                guard let decoded = filter.outputImage else {
                    throw CameraFailure.message("El revelado RAW no ha devuelto imagen.")
                }
                image = decoded
            } else {
                guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                    throw CameraFailure.message("No se pudo leer una foto.")
                }
                image = decoded
            }
            // The selectable limit belongs to a multi-frame stack. Editing a
            // single photo must not silently downsample the full-resolution JPEG.
            let limit = frames.count == 1 ? max(image.extent.width, image.extent.height)
                : CGFloat(min(4096, max(1024, options.maximumDimension)))
            let factor = min(1, limit / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            let normalized = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                           y: -scaled.extent.minY))
            if isRAW {
                // Decode each DNG once. Registration, rejection and averaging
                // reuse this linear buffer instead of evaluating a RAW graph repeatedly.
                guard let rendered = context.createCGImage(normalized, from: normalized.extent, format: .RGBAh,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else {
                    throw CameraFailure.message("No se pudo materializar el revelado RAW.")
                }
                return CIImage(cgImage: rendered)
            }
            return normalized
        }
        var referenceIndex = 0
        if options.chooseSharpestReference && frames.count > 1 {
            var best = -Double.infinity
            for (index, frame) in inputFrames.enumerated() {
                let score = try autoreleasepool { () throws -> Double in
                    if isRAW {
                        guard let preview = CIImage(data: frames[index], options: [.applyOrientationProperty: true]) else {
                            throw CameraFailure.message("No se pudo leer la referencia de cámara.")
                        }
                        return sharpness(preview)
                    }
                    return sharpness(try decode(frame))
                }
                if score > best { best = score; referenceIndex = index }
            }
        }
        let referenceData = frames[referenceIndex]
        let reference = try decode(inputFrames[referenceIndex])
        var accumulator = reference
        var common = reference.extent
        // Register reduced images; retain full resolution for all fusion/render operations.
        let registrationScale = min(1, 1024 / max(reference.extent.width, reference.extent.height))
        func registrationImage(_ image: CIImage) throws -> CGImage {
            let reduced = image.transformed(by: CGAffineTransform(scaleX: registrationScale, y: registrationScale))
            guard let rendered = context.createCGImage(reduced, from: reduced.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw CameraFailure.message("No se pudo preparar la imagen de alineación.")
            }
            return rendered
        }
        let registrationReference = try registrationImage(reference)
        var accepted = 1
        for (index, frame) in inputFrames.enumerated() where index != referenceIndex {
            try autoreleasepool {
                let image = try decode(frame)
                guard abs(image.extent.width - reference.extent.width) < 1,
                      abs(image.extent.height - reference.extent.height) < 1 else { return }
                // Vision maps the targeted (floating) image into the handler's reference image.
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: try registrationImage(image))
                let handler = VNImageRequestHandler(cgImage: registrationReference)
                do { try handler.perform([request]) } catch {
                    #if os(macOS)
                    print("registration failure: \(error)")
                    #endif
                    return
                }
                #if os(macOS)
                if ProcessInfo.processInfo.environment["ULTIMATECAM_PROCESSOR_TRACE"] == "1" {
                    print("registration extent=\(reference.extent) scale=\(registrationScale) result=\(String(describing: request.results?.first))")
                }
                #endif
                guard let observation = request.results?.first,
                      observation.confidence >= 0.5 else { return }
                var transform = CGAffineTransform(translationX: observation.alignmentTransform.tx / registrationScale,
                    y: observation.alignmentTransform.ty / registrationScale)
                // Vision's reduced estimate is quantized in reduced pixels. Refine a
                // central full-resolution patch so a one-pixel estimate does not
                // become several pixels of blur in the final photograph.
                if registrationScale < 1 {
                    let overlap = reference.extent.intersection(image.transformed(by: transform).extent)
                    let side = min(768, min(overlap.width, overlap.height) - 16)
                    if side > 128 {
                        let patch = CGRect(x: overlap.midX - side / 2, y: overlap.midY - side / 2,
                            width: side, height: side).integral
                        let aligned = image.transformed(by: transform)
                        if let target = context.createCGImage(aligned, from: patch, format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                           let anchor = context.createCGImage(reference, from: patch, format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                            let refinement = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
                            do { try VNImageRequestHandler(cgImage: anchor).perform([refinement]) }
                            catch { return }
                            if let residual = refinement.results?.first, residual.confidence >= 0.5,
                               abs(residual.alignmentTransform.tx) <= max(4, 2 / registrationScale),
                               abs(residual.alignmentTransform.ty) <= max(4, 2 / registrationScale) {
                                transform.tx += residual.alignmentTransform.tx
                                transform.ty += residual.alignmentTransform.ty
                            }
                        }
                    }
                }
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
        if options.nightStatic { accumulator = try nightTone(accumulator.cropped(to: common), maximumGain: isRAW ? 32 : 8) }
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
        let prefix = options.nightStatic ? "Noche estática · \(isRAW ? "DNG revelados" : "JPEG") · " : ""
        return CaptureResult(jpeg: data as Data, reference: referenceData,
            details: prefix + details, mergedFrames: accepted,
            raw: rawFrames?[referenceIndex], source: isRAW ? "developed-RAW" : "JPEG")
    }

    /// Explicit SSH export only. Compare Apple's DNG defaults with our linear decode;
    /// these diagnostic previews are never substituted for a captured result.
    func exportRAWDiagnostics(_ data: Data, to directory: URL) throws {
        guard let filter = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else {
            throw CameraFailure.message("No se pudo inspeccionar el DNG.")
        }
        let info: [String: Any] = ["temperature": filter.neutralTemperature, "tint": filter.neutralTint,
            "baselineExposure": filter.baselineExposure, "boost": filter.boostAmount,
            "shadowBias": filter.shadowBias, "boostShadows": filter.boostShadowAmount,
            "colorNR": filter.colorNoiseReductionAmount, "lumaNR": filter.luminanceNoiseReductionAmount]
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: directory.appendingPathComponent("raw-settings.json"))
        func write(_ image: CIImage?, _ name: String) throws {
            guard let image else { throw CameraFailure.message("Revelado de diagnóstico vacío.") }
            let factor = min(1, 1600 / max(image.extent.width, image.extent.height))
            let preview = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            try context.writeJPEGRepresentation(of: preview, to: directory.appendingPathComponent(name),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        }
        try write(filter.outputImage, "raw-default.jpg")
        filter.boostAmount = 0; filter.baselineExposure = 0; filter.exposure = 0
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
        try write(filter.outputImage, "raw-linear.jpg")
        if let linear = filter.outputImage { try write(nightTone(linear), "raw-linear-toned.jpg") }
        filter.isGamutMappingEnabled = false
        filter.shadowBias = 0
        filter.boostShadowAmount = 0
        if let linear = filter.outputImage { try write(nightTone(linear, maximumGain: 32), "raw-no-gamut-toned.jpg") }
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0.72 }
        if let linear = filter.outputImage { try write(nightTone(linear, maximumGain: 32), "raw-denoised-toned.jpg") }
    }

    /// Monotone shadow lift after fusion. Preserve exposed lights and bound shadow gain.
    private func nightTone(_ image: CIImage, maximumGain: Double = 8) throws -> CIImage {
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        ])
        let histogram = luma.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent), "inputCount": 128,
            kCIInputScaleKey: 1
        ])
        var bins = [Float](repeating: 0, count: 128 * 4)
        bins.withUnsafeMutableBytes { bytes in
            context.render(histogram, toBitmap: bytes.baseAddress!, rowBytes: 128 * 16,
                bounds: CGRect(x: 0, y: 0, width: 128, height: 1), format: .RGBAf, colorSpace: nil)
        }
        let total = stride(from: 0, to: bins.count, by: 4).reduce(Float(0)) { $0 + max(0, bins[$1]) }
        var cumulative: Float = 0
        var percentile = 0.5
        if total > 0 {
            for index in 0..<128 {
                cumulative += max(0, bins[index * 4])
                if cumulative >= total * 0.6 { percentile = (Double(index) + 0.5) / 128; break }
            }
        }
        let gain = min(maximumGain, max(1, 0.12 / max(0.004, percentile)))
        guard let kernel = Self.nightKernel,
              let result = kernel.apply(extent: image.extent, arguments: [image, gain]) else {
            throw CameraFailure.message("No se pudo aplicar el mapeo tonal nocturno.")
        }
        return result
    }

    private static let nightKernel = CIColorKernel(source: """
        kernel vec4 nightTone(__sample p, float gain) {
            vec3 c = max(p.rgb, vec3(0.0));
            float peak = max(c.r, max(c.g, c.b));
            float mapped = peak;
            if (peak > 0.000001 && peak < 0.25) {
                float gamma = 1.0 / (1.0 + 0.4 * log2(max(gain, 1.0)));
                mapped = min(peak * gain, 0.25 * pow(peak / 0.25, gamma));
            } else if (peak > 0.85) {
                mapped = 0.85 + 0.15 * (1.0 - exp(-(peak - 0.85) / 0.15));
            }
            float ratio = peak > 0.000001 ? mapped / peak : 1.0;
            return vec4(c * ratio, p.a);
        }
        """)

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
