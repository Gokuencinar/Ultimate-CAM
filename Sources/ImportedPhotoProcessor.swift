import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImportedPhotoProcessor {
    /// Import an explicitly selected rendered image. RAW needs a separate,
    /// calibrated development flow. No claim is made about its capture mode.
    static func process(_ data: Data, options: ProcessingOptions,
                        cancellation: ProcessingCancellation? = nil) throws -> CaptureResult {
        try cancellation?.check()
        guard !data.isEmpty, data.count <= 48 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12000, height <= 12000,
              Int64(width) * Int64(height) <= 24_000_000 else {
            throw CameraFailure.message("Importa una imagen completa de hasta 24 MP y 48 MB.")
        }
        guard UTType(type as String)?.conforms(to: .rawImage) != true else {
            throw CameraFailure.message("Importa el JPEG/HEIF revelado; la importación DNG no está calibrada.")
        }
        var recipe = try options.validated()
        // Never capture or treat an imported image as a burst, HDR bracket or RAW.
        recipe.nightStatic = false; recipe.nightRAW = false; recipe.hdrBracketing = false
        let isJPEG = UTType(type as String)?.conforms(to: .jpeg) == true
        let edits = recipe.advancedRendering || recipe.noiseReduction > 0 || recipe.sharpening > 0 || recipe.liftShadows > 0
        if recipe.preserveHDR, (!isJPEG || edits), let hdr = AdaptiveHDR.expanded(data),
           let sdr = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .cacheIntermediates: false])
            defer { context.clearCaches() }
            let reference = isJPEG ? data :
                try JPEGRenderer.render(sdr, extent: sdr.extent, options: ProcessingOptions(), context: context).data
            try cancellation?.check()
            let rendered = try JPEGRenderer.render(sdr, extent: sdr.extent, options: recipe, context: context, hdrSource: hdr)
            try cancellation?.check()
            return CaptureResult(jpeg: rendered.data, reference: reference,
                details: "Foto importada · \(rendered.width) × \(rendered.height) px. \(rendered.encodingDescription) Sin nueva captura.",
                mergedFrames: 1, source: "imported-rendered-image", statistics: ImageStatistics.measure(rendered.data))
        }
        let reference: Data
        if isJPEG { reference = data }
        else {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw CameraFailure.message("No se pudo leer la foto seleccionada.")
            }
            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            reference = try JPEGRenderer.render(image, extent: image.extent,
                options: ProcessingOptions(), context: context).data
        }
        try cancellation?.check()
        var result = try BurstProcessor().process([reference], options: recipe, cancellation: cancellation)
        let encoding = isJPEG && result.jpeg == data ? "JPEG original sin recodificar; recursos HDR incorporados sin validar." : "Acabado JPEG SDR; no conserva un gain map HDR."
        result = CaptureResult(jpeg: result.jpeg, reference: reference,
            details: "Foto importada · " + encoding + " Sin nueva captura. " + result.details,
            mergedFrames: 1, source: "imported-rendered-image", statistics: ImageStatistics.measure(result.jpeg))
        return result
    }
}
