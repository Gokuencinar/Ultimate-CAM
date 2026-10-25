import CoreImage
import Vision
import simd

enum CoveredRectangle {
    /// Largest fully covered rectangle in a bounded binary mask. Returns cell
    /// coordinates, with the same bottom-left row ordering as Core Image.
    static func largest(_ mask:[UInt8],width:Int,height:Int) -> CGRect? {
        guard width>0,height>0,width<=1024,height<=1024,mask.count==width*height else { return nil }
        var columns=[Int](repeating:0,count:width),best=CGRect.zero,area=0
        for y in 0..<height {
            for x in 0..<width { columns[x]=mask[y*width+x]>=250 ? columns[x]+1:0 }
            var stack=[Int]()
            for x in 0...width {
                let current=x==width ? 0:columns[x]
                while let last=stack.last,columns[last]>current {
                    _=stack.removeLast();let left=(stack.last ?? -1)+1,w=x-left,h=columns[last]
                    if w*h>area { area=w*h;best=CGRect(x:left,y:y-h+1,width:w,height:h) }
                }
                if x<width { stack.append(x) }
            }
        }
        return area>0 ? best:nil
    }
}

final class PanoramaProcessor {
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context=CIContext(options:[.workingColorSpace:space,.cacheIntermediates:false])
    func process(_ frames:[Data],options:ProcessingOptions,cancellation:ProcessingCancellation?=nil,
                 progress:((String)->Void)?=nil) throws -> CaptureResult {
        guard (2...10).contains(frames.count) else { throw CameraFailure.message("Panorama necesita entre 2 y 10 fotos solapadas.") }
        _=try options.validated();defer { context.clearCaches() }
        func decode(_ data:Data) throws -> CIImage {
            guard let image=CIImage(data:data,options:[.applyOrientationProperty:true]),image.extent.width>0,image.extent.height>0 else { throw CameraFailure.message("Fotograma panorámico no válido.") }
            let scale=min(1,1600/max(image.extent.width,image.extent.height))
            let scaled=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            return scaled.transformed(by:CGAffineTransform(translationX:-scaled.extent.minX,y:-scaled.extent.minY))
        }
        var previous=try decode(frames[0]),mean=previous,extent=previous.extent
        var weight=try feather(previous.extent),previousTransform=matrix_identity_float3x3
        for index in 1..<frames.count {
            try cancellation?.check();progress?("Uniendo panorama \(index+1) de \(frames.count)…")
            let next=try decode(frames[index])
            guard abs(next.extent.width-previous.extent.width)<1,abs(next.extent.height-previous.extent.height)<1 else { throw CameraFailure.message("Mantén la misma lente, orientación y zoom durante el panorama.") }
            let pair=try registration(reference:previous,floating:next)
            let transform=previousTransform*pair
            let warped=try Self.warp(next,matrix:transform)
            let warpedWeight=try Self.warp(feather(next.extent),matrix:transform)
            let union=extent.union(warped.extent).integral
            guard union.width*union.height-extent.width*extent.height>next.extent.width*next.extent.height*0.03 else {
                throw CameraFailure.message("El nuevo fotograma apenas añade escena. Desplázate antes de hacer la siguiente foto.")
            }
            guard union.width<=8192,union.height<=8192,union.width*union.height<=16_000_000 else { throw CameraFailure.message("El panorama supera el límite de 16 MP. Termina antes o usa menos fotos.") }
            let overlap=extent.intersection(warped.extent)
            guard overlap.width*overlap.height>next.extent.width*next.extent.height*0.2 else { throw CameraFailure.message("Falta solapamiento entre las fotos.") }
            guard let combined=Self.meanKernel?.apply(extent:union,arguments:[mean,weight,warped,warpedWeight]),
                  let combinedWeight=Self.weightKernel?.apply(extent:union,arguments:[weight,warpedWeight]),
                  let color=context.createCGImage(combined,from:union,format:.RGBAh,colorSpace:space),
                  let w=context.createCGImage(combinedWeight,from:union,format:.RGBAh,colorSpace:space) else { throw CameraFailure.message("No se pudo fusionar el panorama.") }
            mean=CIImage(cgImage:color).transformed(by:CGAffineTransform(translationX:union.minX,y:union.minY))
            weight=CIImage(cgImage:w).transformed(by:CGAffineTransform(translationX:union.minX,y:union.minY))
            extent=union;previous=next;previousTransform=transform
        }
        try cancellation?.check()
        let scale=min(1,256/max(extent.width,extent.height))
        let normalized=weight.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
            .applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.01])
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let w=max(1,Int(floor(extent.width*scale))),h=max(1,Int(floor(extent.height*scale)))
        var mask=[UInt8](repeating:0,count:w*h)
        mask.withUnsafeMutableBytes { context.render(normalized,toBitmap:$0.baseAddress!,rowBytes:w,bounds:CGRect(x:0,y:0,width:w,height:h),format:.L8,colorSpace:nil) }
        guard let cells=CoveredRectangle.largest(mask,width:w,height:h) else { throw CameraFailure.message("El panorama no tiene una región completa para guardar.") }
        let crop=CGRect(x:ceil(extent.minX+cells.minX/scale),y:ceil(extent.minY+cells.minY/scale),
                        width:floor(cells.width/scale),height:floor(cells.height/scale)).intersection(extent)
        guard crop.width*crop.height>=extent.width*extent.height*0.5 else { throw CameraFailure.message("Las fotos dejan demasiados huecos. Mantén el horizonte y repite la unión con más solapamiento.") }
        var outputOptions=options;outputOptions.preserveHDR=false;outputOptions.portraitAmount=0
        let rendered=try JPEGRenderer.render(mean,extent:crop,options:outputOptions,context:context)
        try cancellation?.check()
        return CaptureResult(jpeg:rendered.data,reference:frames[0],details:"Panorama guiado · \(frames.count) fotos · \(rendered.width) × \(rendered.height). JPEG SDR; sin profundidad ni corrección de paralaje.",mergedFrames:frames.count,source:"guided-projective-panorama")
    }
    func registration(reference:CIImage,floating:CIImage) throws -> simd_float3x3 {
        let scale=min(1,1024/max(reference.extent.width,reference.extent.height))
        func low(_ image:CIImage) throws -> CGImage {
            let small=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            guard let cg=context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { throw CameraFailure.message("No se pudo preparar el registro panorámico.") };return cg
        }
        // Dense homography starts near identity and can miss large panorama
        // displacements. First estimate translation; refine perspective only
        // on the common, already aligned region.
        let rough=VNTranslationalImageRegistrationRequest(targetedCGImage:try low(floating))
        try VNImageRequestHandler(cgImage:try low(reference)).perform([rough])
        guard let observed=rough.results?.first,observed.confidence>=0.5 else { throw CameraFailure.message("No se encontró suficiente detalle común. Conserva un 40–60 % de solapamiento.") }
        let dx=observed.alignmentTransform.tx/scale,dy=observed.alignmentTransform.ty/scale
        let translation=simd_float3x3(columns:(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(Float(dx),Float(dy),1)))
        let shifted=floating.transformed(by:CGAffineTransform(translationX:dx,y:dy))
        let overlap=reference.extent.intersection(shifted.extent).integral.intersection(reference.extent).intersection(shifted.extent)
        guard overlap.width*overlap.height>reference.extent.width*reference.extent.height*0.2 else { throw CameraFailure.message("Falta solapamiento para registrar el panorama.") }
        let refine=VNHomographicImageRegistrationRequest(targetedCGImage:try low(shifted.cropped(to:overlap)))
        try VNImageRequestHandler(cgImage:try low(reference.cropped(to:overlap))).perform([refine])
        guard let result=refine.results?.first,result.confidence>=0.5 else { return translation }
        let s=simd_float3x3(diagonal:SIMD3(Float(scale),Float(scale),1))
        let origin=simd_float3x3(columns:(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(Float(overlap.minX),Float(overlap.minY),1)))
        return origin*s.inverse*result.warpTransform*s*origin.inverse*translation
    }
    static func warp(_ image:CIImage,matrix:simd_float3x3) throws -> CIImage {
        let e=image.extent
        func point(_ x:CGFloat,_ y:CGFloat) throws -> CIVector {
            let p=matrix*SIMD3(Float(x),Float(y),1)
            guard p.x.isFinite,p.y.isFinite,p.z.isFinite,abs(p.z)>0.00001 else { throw CameraFailure.message("Registro panorámico degenerado.") }
            let x=Double(p.x/p.z),y=Double(p.y/p.z)
            guard abs(x)<32768,abs(y)<32768 else { throw CameraFailure.message("Registro panorámico fuera de límites.") }
            return CIVector(x:x,y:y)
        }
        let tl=try point(e.minX,e.maxY),tr=try point(e.maxX,e.maxY),bl=try point(e.minX,e.minY),br=try point(e.maxX,e.minY)
        let corners=[bl,br,tr,tl]
        for i in 0..<4 {
            let a=corners[i],b=corners[(i+1)%4],c=corners[(i+2)%4]
            guard (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)>0.0001 else { throw CameraFailure.message("El registro invierte o pliega la imagen.") }
        }
        let result=image.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":tl,"inputTopRight":tr,"inputBottomLeft":bl,"inputBottomRight":br])
        guard result.extent.width>0,result.extent.height>0,result.extent.width*result.extent.height<image.extent.width*image.extent.height*4 else { throw CameraFailure.message("El registro deforma demasiado la imagen.") }
        return result
    }
    private func feather(_ extent:CGRect) throws -> CIImage {
        guard let result=Self.featherKernel?.apply(extent:extent,arguments:[CIVector(cgRect:extent),max(4,extent.width*0.08)]) else { throw CameraFailure.message("No se pudo preparar la unión de bordes.") };return result
    }
    private static let featherKernel=CIColorKernel(source:"""
        kernel vec4 feather(vec4 rect,float radius) {
            vec2 p=destCoord()-rect.xy;
            float d=min(min(p.x,rect.z-p.x),min(p.y,rect.w-p.y));
            return vec4(vec3(clamp(d/radius,0.0,1.0)),1.0);
        }
        """)
    private static let weightKernel=CIColorKernel(source:"kernel vec4 weights(__sample a,__sample b) { return vec4(vec3(a.r+b.r),1.0); }")
    private static let meanKernel=CIColorKernel(source:"""
        kernel vec4 panoramaMean(__sample a,__sample aw,__sample b,__sample bw) {
            float total=aw.r+bw.r;
            vec3 color=total>0.00001 ? (unpremultiply(a).rgb*aw.r+unpremultiply(b).rgb*bw.r)/total : vec3(0.0);
            return vec4(color,total>0.00001 ? 1.0:0.0);
        }
        """)
}
