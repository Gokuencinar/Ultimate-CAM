import CoreImage
import ImageIO

struct RenderedJPEG { let data: Data; let width: Int; let height: Int }

/// Shared finishing path for a single frame, a temporal stack, and HDR.
enum JPEGRenderer {
    static func render(_ input: CIImage, extent inputExtent: CGRect, options: ProcessingOptions, context: CIContext) throws -> RenderedJPEG {
        var image = input
        var extent = inputExtent
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
        image = try AdvancedProcessor.apply(image.cropped(to: extent), options: options)
        extent = AdvancedProcessor.crop(extent, aspect: options.aspect)
        let outputSpace = CGColorSpace(name: options.outputColor == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: extent,
                    format: .RGBA8, colorSpace: outputSpace) else {
            throw CameraFailure.message("No se pudo renderizar la pila.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CameraFailure.message("No se pudo crear el JPEG.")
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: options.jpegQuality ?? 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.message("Error al codificar el JPEG.") }
        return RenderedJPEG(data:data as Data,width:cg.width,height:cg.height)
    }
}
