import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImportedPhotoProcessor {
    /// Explicitly selected photos only. RAW development uses embedded calibration
    /// understood by CIRAWFilter, never fabricated camera matrices.
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
        if UTType(type as String)?.conforms(to:.rawImage)==true || type as String == "com.adobe.raw-image" {
            return try developRAW(data,options:options,cancellation:cancellation)
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
                try JPEGRenderer.render(sdr, extent: sdr.extent, options: ProcessingOptions(), context: context,metadataReference:data).data
            try cancellation?.check()
            let rendered = try JPEGRenderer.render(sdr, extent: sdr.extent, options: recipe, context: context, hdrSource: hdr,metadataReference:data)
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
                options: ProcessingOptions(), context: context,metadataReference:data).data
        }
        try cancellation?.check()
        var result = try BurstProcessor().process([reference], options: recipe, cancellation: cancellation)
        let encoding = isJPEG && result.jpeg == data ? "JPEG original sin recodificar; recursos HDR incorporados sin validar." : "Acabado JPEG SDR; no conserva un gain map HDR."
        result = CaptureResult(jpeg: result.jpeg, reference: reference,
            details: "Foto importada · " + encoding + " Sin nueva captura. " + result.details,
            mergedFrames: 1, source: "imported-rendered-image", statistics: ImageStatistics.measure(result.jpeg))
        return result
    }
    private static func developRAW(_ data:Data,options:ProcessingOptions,cancellation:ProcessingCancellation?) throws -> CaptureResult {
        let recipe=try options.validated()
        guard let decoder=CIRAWFilter(imageData:data,identifierHint:nil) else { throw CameraFailure.message("El RAW no es compatible con el revelador de iOS.") }
        decoder.isGamutMappingEnabled=false
        if decoder.isLuminanceNoiseReductionSupported { decoder.luminanceNoiseReductionAmount=0.15 }
        if decoder.isColorNoiseReductionSupported { decoder.colorNoiseReductionAmount=0.5 }
        guard let image=decoder.outputImage,image.extent.width>0,image.extent.height>0,
              image.extent.width<=12000,image.extent.height<=12000,image.extent.width*image.extent.height<=24_000_000 else {
            throw CameraFailure.message("El RAW supera el límite de 24 MP o no se pudo revelar.")
        }
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(options:[.workingColorSpace:space,.cacheIntermediates:false])
        defer { context.clearCaches() }
        try cancellation?.check()
        let reference=try JPEGRenderer.render(image,extent:image.extent,options:ProcessingOptions(),context:context,metadataReference:data).data
        let mapped:CIImage,hdr:CIImage
        if recipe.nightStatic {
            let result=try nightTone(image,context:context)
            mapped=result.sdr;hdr=result.hdr
        } else { mapped=image;hdr=try AdaptiveHDR.rollOff(image,gain:1,headroom:4) }
        let prepared=try JPEGRenderer.prepare(mapped,extent:mapped.extent,options:recipe,context:context,
            hdrSource:recipe.preserveHDR ? hdr:nil,hdrHeadroom:4)
        try cancellation?.check()
        let jpeg=try JPEGRenderer.encode(prepared,options:recipe,context:context,metadataReference:data)
        return CaptureResult(jpeg:jpeg.data,reference:reference,details:"RAW importado · \(jpeg.width) × \(jpeg.height) px. \(jpeg.encodingDescription)",
            mergedFrames:1,raw:CGImageSourceCreateWithData(data as CFData,nil).flatMap { CGImageSourceGetType($0) as String? } == "com.adobe.raw-image" ? data:nil,source:"imported-RAW",statistics:ImageStatistics.measure(jpeg.data))
    }
    /// Same exposure statistic/toe as capture; a single imported frame cannot
    /// recover photons or the multi-frame denoising of a nocturnal burst.
    private static func nightTone(_ image:CIImage,context:CIContext) throws -> (sdr:CIImage,hdr:CIImage) {
        let extent=image.extent,scale=48/extent.width
        let small=image.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let w=max(1,Int(small.extent.width)),h=max(1,Int(small.extent.height))
        var pixels=[Float](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { context.render(small,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) }
        let luma=(0..<w*h).map { i in max(0,Double(pixels[i*4])*0.2126+Double(pixels[i*4+1])*0.7152+Double(pixels[i*4+2])*0.0722) }
        let plan=try NightTonePlan.make(luminances:luma,maximumGain:32)
        guard let kernel=nightKernel,let sdr=kernel.apply(extent:extent,arguments:[image,plan.gain,plan.whitePoint]) else { throw CameraFailure.message("No se pudo preparar el tono nocturno del RAW.") }
        return (sdr,try AdaptiveHDR.rollOff(image,gain:plan.gain,headroom:4))
    }
    private static let nightKernel=CIColorKernel(source:"""
        kernel vec4 importedNight(__sample p,float gain,float white) {
            vec3 rgb=max(p.rgb,vec3(0.0));float l=dot(rgb,vec3(0.2126,0.7152,0.0722));
            float x=l*gain;float m=x*(1.0+x/(white*white))/(1.0+x);
            m=m*m/max(m+0.003,0.000001)*(0.183/0.18);
            vec3 clean=mix(vec3(l),rgb,smoothstep(0.002,0.02,l));
            vec3 result=clean*m/max(l,0.000001);
            return vec4(result/max(1.0,max(result.r,max(result.g,result.b))),1.0);
        }
        """)

}
