import CoreImage
import Vision

/// Original RGB radiance fusion of a metered/short/long JPEG bracket. Camera
/// JPEG tone processing means this is only an approximation to sensor radiance.
/// It is not Google's RAW HDR+ / HDRnet pipeline. Optional Adaptive HDR output
/// uses the system encoder with the fused radiance and an SDR base.
final class HDRProcessor {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options:[.workingColorSpace:space,.cacheIntermediates:false])

    func process(_ frames: [Data], exposures: [FrameExposure], options: ProcessingOptions,
                 cancellation: ProcessingCancellation? = nil, progress: ((String) -> Void)? = nil) throws -> CaptureResult {
        _ = try options.validated()
        guard frames.count == 3, exposures.count == 3, exposures.allSatisfy(\.isValid), options.hdrBracketing else {
            throw CameraFailure.message("Horquillado HDR incompleto o sin metadatos de exposición.")
        }
        defer { context.clearCaches() }
        let scales = exposures.map { $0.product/exposures[0].product }
        guard scales.allSatisfy({ $0.isFinite && (1.0/16...16).contains($0) }),
              log2(scales.max()!/scales.min()!) >= 1 else {
            throw CameraFailure.message("Las exposiciones recibidas no forman un horquillado HDR válido.")
        }
        try cancellation?.check()
        func decode(_ data: Data, scale: Double) throws -> CIImage {
            guard let source = CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("No se pudo leer el fotograma HDR.") }
            let factor = min(1,CGFloat(options.maximumDimension)/max(source.extent.width,source.extent.height))
            var image = source.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
            image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                .applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-log2(scale)])
            guard let cg = context.createCGImage(image,from:image.extent,format:.RGBAh,colorSpace:space) else { throw CameraFailure.message("No se pudo preparar la radiancia HDR.") }
            return CIImage(cgImage:cg)
        }
        let reference = try decode(frames[0],scale:1)
        let smallScale = min(1,1024/max(reference.extent.width,reference.extent.height))
        func registration(_ image: CIImage) throws -> CGImage {
            let small = image.transformed(by:CGAffineTransform(scaleX:smallScale,y:smallScale))
            guard let cg = context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { throw CameraFailure.message("No se pudo registrar HDR.") }
            return cg
        }
        let anchor = try registration(reference)
        var images = [reference,reference,reference], valid = [1.0,0,0], extent = reference.extent
        for index in 1..<3 {
            try cancellation?.check(); progress?("Alineando HDR \(index+1) de 3…")
            let image = try decode(frames[index],scale:scales[index])
            guard abs(image.extent.width-reference.extent.width)<1, abs(image.extent.height-reference.extent.height)<1 else { continue }
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage:try registration(image))
            try VNImageRequestHandler(cgImage:anchor).perform([request])
            guard let observation = request.results?.first, observation.confidence >= 0.5 else { continue }
            let dx = observation.alignmentTransform.tx/smallScale, dy = observation.alignmentTransform.ty/smallScale
            guard abs(dx)<reference.extent.width*0.04, abs(dy)<reference.extent.height*0.04 else { continue }
            var aligned = image.transformed(by:CGAffineTransform(translationX:dx,y:dy))
            let overlap = extent.intersection(aligned.extent).integral.intersection(reference.extent)
            guard overlap.width>reference.extent.width*0.9,overlap.height>reference.extent.height*0.9 else { continue }
            if options.localAlignment { aligned = try LocalAlignment.align(aligned,reference:reference,extent:overlap,context:context) }
            images[index]=aligned;valid[index]=1;extent=overlap
        }
        let accepted = Int(valid.reduce(0,+))
        guard accepted>=2 else { throw CameraFailure.message("No se alinearon exposiciones distintas; se conserva la referencia sin HDR.") }
        try cancellation?.check(); progress?("Fusionando radiancia HDR…")
        guard let merged = Self.mergeKernel?.apply(extent:extent,arguments:[images[0],images[1],images[2],
            CIVector(x:scales[0],y:scales[1],z:scales[2]),CIVector(x:valid[0],y:valid[1],z:valid[2]),options.rejectMotion ? 1.0 : 0.0]),
              let mapped = Self.toneKernel?.apply(extent:extent,arguments:[merged]) else { throw CameraFailure.message("No se pudo ejecutar la fusión HDR.") }
        let rendered = try JPEGRenderer.render(mapped,extent:extent,options:options,context:context,hdrSource:merged)
        try cancellation?.check()
        return CaptureResult(jpeg:rendered.data,reference:frames[0],
            details:"HDR experimental · \(accepted)/3 exposiciones · \(String(format:"%.1f",log2(scales.max()!/scales.min()!))) EV recibidos · \(rendered.width) × \(rendered.height) px. \(rendered.encodingDescription)",
            mergedFrames:accepted,source:"HDR-JPEG-radiance")
    }

    // These kernels also back host fixtures with known linear radiance/exposure.
    static func fuse(_ reference: CIImage,_ short: CIImage,_ long: CIImage,scales: CIVector,extent: CGRect) throws -> CIImage {
        guard let result = mergeKernel?.apply(extent:extent,arguments:[reference,short,long,scales,CIVector(x:1,y:1,z:1),0.0]) else { throw CameraFailure.message("Kernel HDR no disponible.") }
        return result
    }
    private static let mergeKernel = CIColorKernel(source:"""
        float weight(vec3 normalized, float scale) {
            vec3 observed = normalized * scale;
            float peak = max(observed.r,max(observed.g,observed.b));
            float y = dot(observed,vec3(0.2126,0.7152,0.0722));
            return smoothstep(0.003,0.03,peak) * (1.0-smoothstep(0.85,0.995,peak)) * exp(-5.0*(y-0.35)*(y-0.35));
        }
        kernel vec4 radiance(__sample r, __sample s, __sample l, vec3 scales, vec3 valid, float reject) {
            float wr = weight(r.rgb,scales.x)*valid.x;
            float ws = weight(s.rgb,scales.y)*valid.y;
            float wl = weight(l.rgb,scales.z)*valid.z;
            float peak = max(r.r,max(r.g,r.b));
            float reliable = smoothstep(0.01,0.04,peak)*(1.0-smoothstep(0.9,0.99,peak))*reject;
            float ds = dot(abs(s.rgb-r.rgb),vec3(0.2126,0.7152,0.0722));
            float dl = dot(abs(l.rgb-r.rgb),vec3(0.2126,0.7152,0.0722));
            ws *= 1.0-reliable*smoothstep(0.08,0.22,ds);
            wl *= 1.0-reliable*smoothstep(0.08,0.22,dl);
            float total = wr+ws+wl;
            return vec4(total>0.00001 ? (r.rgb*wr+s.rgb*ws+l.rgb*wl)/total : r.rgb,1.0);
        }
        """)
    private static let toneKernel = CIColorKernel(source:"""
        kernel vec4 hdrTone(__sample p) {
            float peak = max(p.r,max(p.g,p.b));
            float mapped = peak/(1.0+max(0.0,peak-0.75));
            return vec4(p.rgb*(peak>0.00001 ? mapped/peak : 1.0),p.a);
        }
        """)
}
