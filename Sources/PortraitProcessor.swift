import CoreImage
import Vision

/// Vision matte refined by a fast guided filter, with optional registered
/// hardware disparity and normalized disc convolution for progressive bokeh.
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

    /// Gaussian-weighted guided filter. Coefficients are estimated on a bounded
    /// grid, then evaluated with the full-resolution guide to retain thin edges.
    static func guidedMask(_ mask:CIImage,guide:CIImage,extent:CGRect,radius:Double=4,epsilon:Double=0.001)->CIImage {
        let factor=min(1,1024/max(extent.width,extent.height))
        let transform=CGAffineTransform(translationX:-extent.minX,y:-extent.minY)
            .concatenating(CGAffineTransform(scaleX:factor,y:factor))
        let i=guide.transformed(by:transform),p=mask.transformed(by:transform),small=i.extent
        guard let moments=momentsKernel?.apply(extent:small,arguments:[i,p]),let cross=crossKernel?.apply(extent:small,arguments:[i,p]) else { return mask }
        let mean=moments.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:small)
        let meanCross=cross.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:small)
        guard let ab=coefficientsKernel?.apply(extent:small,arguments:[mean,meanCross,epsilon]) else { return mask }
        let averaged=ab.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:small)
            .transformed(by:transform.inverted())
        return guidedKernel?.apply(extent:extent,arguments:[guide,averaged]) ?? mask
    }
    static func apply(_ input:CIImage,mask:CIImage,extent:CGRect,amount:Double,depth:PortraitDepth?=nil,context:CIContext?=nil) throws -> CIImage {
        guard amount.isFinite,(0...1).contains(amount),input.extent.contains(extent),mask.extent.contains(extent) else {
            throw CameraFailure.message("Parámetros de retrato no válidos.")
        }
        if amount==0 { return input.cropped(to:extent) }
        let radius=max(1,min(48,extent.width*0.012*amount))
        let soft=guidedMask(mask,guide:input,extent:extent)
        guard let weighted=weightedKernel?.apply(extent:extent,arguments:[input,soft]),
              let weight=weightKernel?.apply(extent:extent,arguments:[soft]) else { throw CameraFailure.message("No se pudo separar el fondo del retrato.") }
        func background(_ scale:Double) throws -> CIImage {
            let parameters=[kCIInputRadiusKey:radius*scale]
            let color=weighted.clampedToExtent().applyingFilter("CIDiscBlur",parameters:parameters).cropped(to:extent)
            let density=weight.clampedToExtent().applyingFilter("CIDiscBlur",parameters:parameters).cropped(to:extent)
            guard let result=normalizeKernel?.apply(extent:extent,arguments:[color,density,input]) else { throw CameraFailure.message("No se pudo desenfocar el fondo.") }
            return result
        }
        var blurred=try background(1)
        if let depth=depth?.aligned(to:extent),let context {
            let scale=min(1,64/max(extent.width,extent.height))
            let probe=depth.disparity.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let matte=soft.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let w=max(1,Int(probe.extent.width)),h=max(1,Int(probe.extent.height)),bounds=CGRect(x:0,y:0,width:w,height:h)
            var d=[Float](repeating:0,count:w*h*4),m=d
            d.withUnsafeMutableBytes { context.render(probe,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:nil) }
            m.withUnsafeMutableBytes { context.render(matte,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:nil) }
            var values=[Float]()
            // Green stores validity in a captured depth image; synthetic maps
            // may use a separate validity image, so sample that explicitly.
            var valid=d
            let v=depth.validity.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            valid.withUnsafeMutableBytes { context.render(v,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:nil) }
            for index in 0..<w*h where m[index*4]>0.7 && valid[index*4]>0.9 && d[index*4].isFinite { values.append(d[index*4]) }
            if values.count>=8 {
                values.sort();let focal=values[values.count/2]
                let near=try background(0.25),middle=try background(0.55)
                blurred=depthBlendKernel?.apply(extent:extent,arguments:[input,near,middle,blurred,depth.disparity,depth.validity,focal]) ?? blurred
            }
        }
        return input.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:blurred,kCIInputMaskImageKey:soft]).cropped(to:extent)
    }
    private static let momentsKernel=CIColorKernel(source:"""
     kernel vec4 guidedMoments(__sample image,__sample mask) {
      float i=dot(image.rgb,vec3(0.2126,0.7152,0.0722));float p=clamp(mask.r,0.0,1.0);
      return vec4(i,i*i,0.0,1.0);
     }
     """)
    private static let crossKernel=CIColorKernel(source:"""
     kernel vec4 guidedCross(__sample image,__sample mask) {
      float i=dot(image.rgb,vec3(0.2126,0.7152,0.0722));float p=clamp(mask.r,0.0,1.0);
      return vec4(p,i*p,0.0,1.0);
     }
     """)
    private static let coefficientsKernel=CIColorKernel(source:"""
     kernel vec4 guidedCoefficients(__sample m,__sample c,float epsilon) {
      float a=(c.g-m.r*c.r)/(max(m.g-m.r*m.r,0.0)+epsilon);
      return vec4(a,c.r-a*m.r,0.0,1.0);
     }
     """)
    private static let guidedKernel=CIColorKernel(source:"""
     kernel vec4 guidedEvaluate(__sample image,__sample ab) {
      float i=dot(image.rgb,vec3(0.2126,0.7152,0.0722));
      return vec4(vec3(clamp(ab.r*i+ab.g,0.0,1.0)),1.0);
     }
     """)
    private static let depthBlendKernel=CIColorKernel(source:"""
     kernel vec4 depthBokeh(__sample sharp,__sample near,__sample middle,__sample far,__sample d,__sample valid,float focal) {
      float r=valid.r>0.9 ? clamp(abs(d.r-focal)/0.45,0.0,1.0):1.0;
      vec3 a=mix(sharp.rgb,near.rgb,smoothstep(0.0,0.25,r));
      vec3 b=mix(a,middle.rgb,smoothstep(0.25,0.55,r));
      return vec4(mix(b,far.rgb,smoothstep(0.55,1.0,r)),sharp.a);
     }
     """)
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
