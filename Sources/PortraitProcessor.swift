import CoreImage
import Vision

/// Person matte from the system Vision model, followed by bounded normalized
/// background convolution. No depth map or Google portrait model is claimed.
enum PortraitProcessor {
    static func personMask(_ input:CIImage,extent:CGRect,context:CIContext) throws -> CIImage {
        let normalized=input.cropped(to:extent).transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
        let scale=min(1,1600/max(extent.width,extent.height))
        let small=normalized.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else {
            throw CameraFailure.message("No se pudo preparar la imagen de retrato.")
        }
        let request=VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat=kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage:cg).perform([request])
        guard let pixel=request.results?.first?.pixelBuffer else { throw CameraFailure.message("No se recibió una máscara de persona.") }
        let mask=CIImage(cvPixelBuffer:pixel)
        let average=mask.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:mask.extent)])
        var value=[Float](repeating:0,count:4)
        value.withUnsafeMutableBytes { context.render(average,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:nil) }
        guard value[0].isFinite,value[0]>0.005,value[0]<0.98 else {
            throw CameraFailure.message("Retrato necesita una persona reconocible y algo de fondo. Se conserva la referencia.")
        }
        return mask.transformed(by:CGAffineTransform(scaleX:extent.width/mask.extent.width,y:extent.height/mask.extent.height))
            .transformed(by:CGAffineTransform(translationX:extent.minX,y:extent.minY)).cropped(to:extent)
    }

    static func apply(_ input:CIImage,mask:CIImage,extent:CGRect,amount:Double) throws -> CIImage {
        guard amount.isFinite,(0...1).contains(amount),input.extent.contains(extent),mask.extent.contains(extent) else {
            throw CameraFailure.message("Parámetros de retrato no válidos.")
        }
        if amount==0 { return input.cropped(to:extent) }
        let radius=max(1,min(48,extent.width*0.012*amount))
        let soft=mask.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:min(2,extent.width/1600)]).cropped(to:extent)
        guard let weighted=weightedKernel?.apply(extent:extent,arguments:[input,soft]),
              let weight=weightKernel?.apply(extent:extent,arguments:[soft]) else { throw CameraFailure.message("No se pudo separar el fondo del retrato.") }
        let blur=weighted.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
        let blurredWeight=weight.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
        guard let background=normalizeKernel?.apply(extent:extent,arguments:[blur,blurredWeight,input]) else {
            throw CameraFailure.message("No se pudo desenfocar el fondo.")
        }
        return input.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:background,kCIInputMaskImageKey:soft]).cropped(to:extent)
    }
    private static let weightedKernel=CIColorKernel(source:"""
        kernel vec4 backgroundColor(__sample p,__sample mask) {
            return vec4(p.rgb*(1.0-clamp(mask.r,0.0,1.0)),1.0);
        }
        """)
    private static let weightKernel=CIColorKernel(source:"""
        kernel vec4 backgroundWeight(__sample mask) {
            return vec4(vec3(1.0-clamp(mask.r,0.0,1.0)),1.0);
        }
        """)
    private static let normalizeKernel=CIColorKernel(source:"""
        kernel vec4 normalizedBackground(__sample color,__sample weight,__sample original) {
            return vec4(weight.r>0.0001 ? color.rgb/weight.r : original.rgb,original.a);
        }
        """)
}
