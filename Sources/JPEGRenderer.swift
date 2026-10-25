import CoreImage
import ImageIO

struct RenderedJPEG {
    let data: Data; let width: Int; let height: Int
    var adaptiveHDR = false
    var encodingDescription: String { adaptiveHDR ? "JPEG con mapa HDR adaptativo." : "JPEG SDR." }
}

/// Shared finishing path for a single frame, a temporal stack, and HDR.
enum JPEGRenderer {
    static func render(_ input: CIImage, extent inputExtent: CGRect, options: ProcessingOptions, context: CIContext,
                       hdrSource: CIImage? = nil) throws -> RenderedJPEG {
        var baseInput=input.cropped(to:inputExtent),hdrInput=hdrSource
        if options.portraitAmount>0 {
            let mask=try PortraitProcessor.personMask(baseInput,extent:inputExtent,context:context)
            baseInput=try PortraitProcessor.apply(baseInput,mask:mask,extent:inputExtent,amount:options.portraitAmount)
            if let hdrSource { hdrInput=try PortraitProcessor.apply(hdrSource,mask:mask,extent:inputExtent,amount:options.portraitAmount) }
        }
        let image = try finish(baseInput,options:options)
        let extent = AdvancedProcessor.crop(inputExtent, aspect: options.aspect)
        let outputSpace = CGColorSpace(name: options.outputColor == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: extent,
                    format: .RGBA8, colorSpace: outputSpace) else {
            throw CameraFailure.message("No se pudo renderizar la pila.")
        }
        if options.preserveHDR, let hdrSource=hdrInput {
            let base = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            let data = try AdaptiveHDR.encode(base: base, originalSDR: baseInput, originalHDR: hdrSource,
                extent: extent, colorSpace: outputSpace, quality: options.jpegQuality ?? 0.95, context: context)
            return RenderedJPEG(data: data, width: Int(extent.width), height: Int(extent.height), adaptiveHDR: true)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CameraFailure.message("No se pudo crear el JPEG.")
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: options.jpegQuality ?? 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.message("Error al codificar el JPEG.") }
        return RenderedJPEG(data:data as Data,width:cg.width,height:cg.height)
    }

    /// Same finishing operators for export and the bounded live look. Preparing
    /// LUTs on settings changes avoids file I/O and table construction per frame.
    static func finish(_ input:CIImage,options:ProcessingOptions,
                       colorTable:CubeLUT?=nil,customTable:CubeLUT?=nil) throws -> CIImage {
        var image = input
        let extent = input.extent
        if options.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": min(0.08, options.noiseReduction), "inputSharpness": 0.4
            ])
        }
        if options.liftShadows > 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": min(1, options.liftShadows), "inputHighlightAmount": 0.9
            ])
        }
        if options.sharpening > 0 {
            if options.sharpenRadius == 1 {
                image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: options.sharpening])
            } else {
                image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: options.sharpenRadius, kCIInputIntensityKey: options.sharpening])
            }
        }
        return try AdvancedProcessor.apply(image.cropped(to:extent),options:options,colorTable:colorTable,customTable:customTable)
    }
}
