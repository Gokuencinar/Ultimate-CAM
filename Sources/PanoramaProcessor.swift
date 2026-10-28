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
                 progress:((String)->Void)?=nil,fieldOfView:Double?=nil) throws -> CaptureResult {
        guard (2...24).contains(frames.count) else { throw CameraFailure.message("Panorama necesita entre 2 y 24 fotos solapadas.") }
        _=try options.validated();defer { context.clearCaches() }
        func decode(_ data:Data) throws -> CIImage {
            guard let image=CIImage(data:data,options:[.applyOrientationProperty:true]),image.extent.width>0,image.extent.height>0 else { throw CameraFailure.message("Fotograma panorámico no válido.") }
            let scale=min(1,1600/max(image.extent.width,image.extent.height))
            let scaled=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let normalized=scaled.transformed(by:CGAffineTransform(translationX:-scaled.extent.minX,y:-scaled.extent.minY))
            return try fieldOfView.map{try Self.cylindrical(normalized,fieldOfView:$0)} ?? normalized
        }
        var previous=try decode(frames[0]),mean=previous,extent=previous.extent
        var weight=try feather(previous),previousTransform=matrix_identity_float3x3,accepted=1
        for index in 1..<frames.count {
            try cancellation?.check();progress?("Uniendo panorama \(index+1) de \(frames.count)…")
            let next=try decode(frames[index])
            guard abs(next.extent.width-previous.extent.width)<=2,abs(next.extent.height-previous.extent.height)<=2 else { throw CameraFailure.message("Mantén la misma lente, orientación y zoom durante el panorama.") }
            let pair=try registration(reference:previous,floating:next,perspective:fieldOfView==nil)
            let transform=previousTransform*pair
            let warped=try Self.warp(next,matrix:transform)
            let warpedWeight=try Self.warp(feather(next),matrix:transform)
            let union=extent.union(warped.extent).integral
            guard union.width*union.height-extent.width*extent.height>next.extent.width*next.extent.height*0.03 else {
                // A short sweep may include a nearly duplicate anchor while AE
                // settles. Skip it and retain later views that add real scene.
                continue
            }
            guard union.width<=8192,union.height<=8192,union.width*union.height<=16_000_000 else { throw CameraFailure.message("El panorama supera el límite de 16 MP. Termina antes o usa menos fotos.") }
            let overlap=extent.intersection(warped.extent)
            guard overlap.width*overlap.height>next.extent.width*next.extent.height*0.2 else { throw CameraFailure.message("Falta solapamiento entre las fotos.") }
            let joined=try MultiBandStitcher.blend(mean,coverage:weight,warped,coverage:warpedWeight,
                extent:union,context:context,cancellation:cancellation)
            mean=joined.image;weight=joined.coverage
            extent=union;previous=next;previousTransform=transform;accepted+=1
        }
        try cancellation?.check()
        guard accepted>=2 else { throw CameraFailure.message("Hace falta algo más de desplazamiento entre las fotos. Pulsa Reiniciar para otro barrido.") }
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
        return CaptureResult(jpeg:rendered.data,reference:frames[0],details:"Panorama guiado · \(accepted) fotos · \(rendered.width) × \(rendered.height). JPEG SDR; sin profundidad ni corrección de paralaje.",mergedFrames:accepted,source:"guided-projective-panorama")
    }
    func registration(reference:CIImage,floating:CIImage,perspective:Bool=true) throws -> simd_float3x3 {
        let scale=min(1,1024/max(reference.extent.width,reference.extent.height))
        func patches(_ a:CIImage,_ b:CIImage) throws -> (CGImage,CGImage) {
            let width=Int(floor(min(a.extent.width,b.extent.width)*scale))
            let height=Int(floor(min(a.extent.height,b.extent.height)*scale))
            guard width>=16,height>=16 else { throw CameraFailure.message("El solapamiento es demasiado pequeño para registrar.") }
            let bounds=CGRect(x:0,y:0,width:width,height:height)
            func raster(_ image:CIImage) throws -> CGImage {
                let normalized=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                    .transformed(by:CGAffineTransform(scaleX:scale,y:scale)).cropped(to:bounds)
                guard let cg=context.createCGImage(normalized,from:bounds,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!),cg.width==width,cg.height==height else { throw CameraFailure.message("No se pudo preparar el registro panorámico.") }
                return cg
            }
            return (try raster(a),try raster(b))
        }
        // Dense homography starts near identity and can miss large panorama
        // displacements. First estimate translation; refine perspective only
        // on the common, already aligned region.
        let initial=try patches(reference,floating)
        let rough=VNTranslationalImageRegistrationRequest(targetedCGImage:initial.1)
        rough.regionOfInterest=CGRect(x:0,y:0,width:1,height:1)
        try VNImageRequestHandler(cgImage:initial.0,orientation:.up).perform([rough])
        guard let observed=rough.results?.first,observed.confidence>=0.5 else { throw CameraFailure.message("No se encontró suficiente detalle común. Conserva un 40–60 % de solapamiento.") }
        let dx=observed.alignmentTransform.tx/scale,dy=observed.alignmentTransform.ty/scale
        let translation=simd_float3x3(columns:(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(Float(dx),Float(dy),1)))
        if !perspective { return translation }
        let shifted=floating.transformed(by:CGAffineTransform(translationX:dx,y:dy))
        let overlap=reference.extent.intersection(shifted.extent).integral.intersection(reference.extent).intersection(shifted.extent)
        guard overlap.width*overlap.height>reference.extent.width*reference.extent.height*0.2 else { throw CameraFailure.message("Falta solapamiento para registrar el panorama.") }
        let aligned=try patches(reference.cropped(to:overlap),shifted.cropped(to:overlap))
        let refine=VNHomographicImageRegistrationRequest(targetedCGImage:aligned.1)
        refine.regionOfInterest=CGRect(x:0,y:0,width:1,height:1)
        try VNImageRequestHandler(cgImage:aligned.0,orientation:.up).perform([refine])
        guard let result=refine.results?.first,result.confidence>=0.5 else { return translation }
        let s=simd_float3x3(diagonal:SIMD3(Float(scale),Float(scale),1))
        let origin=simd_float3x3(columns:(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(Float(overlap.minX),Float(overlap.minY),1)))
        let refined=origin*s.inverse*result.warpTransform*s*origin.inverse*translation
        // A low-texture Vision fit may be numerically valid yet almost fold a
        // corner. Keep the measured translation rather than amplifying it in
        // every subsequent cumulative homography.
        guard let warped=try? Self.warp(floating,matrix:refined),
              warped.extent.width<floating.extent.width*1.25,
              warped.extent.height<floating.extent.height*1.25 else { return translation }
        return refined
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
    static func cylindrical(_ image:CIImage,fieldOfView:Double) throws -> CIImage {
        guard fieldOfView.isFinite,(30...110).contains(fieldOfView) else { throw CameraFailure.message("Campo de visión panorámico no válido.") }
        let e=image.extent,f=max(e.width,e.height)*0.5/tan(fieldOfView*Double.pi/360)
        let width=floor(2*f*atan(e.width/(2*f))),bounds=CGRect(x:0,y:0,width:width,height:e.height)
        guard let output=cylinderKernel?.apply(extent:bounds,roiCallback:{_,_ in e},image:image,
            arguments:[f,CIVector(x:e.midX,y:e.midY),width/2]) else { throw CameraFailure.message("No se pudo preparar la proyección panorámica.") }
        return output
    }
    private static let cylinderKernel=CIWarpKernel(source:"""
        kernel vec2 cylinder(float focal,vec2 center,float outputCenter) {
            vec2 p=destCoord();float theta=(p.x-outputCenter)/focal;
            return vec2(focal*tan(theta)+center.x,(p.y-center.y)/cos(theta)+center.y);
        }
        """)
    private func feather(_ image:CIImage) throws -> CIImage {
        let extent=image.extent
        guard let result=Self.featherKernel?.apply(extent:extent,arguments:[CIVector(cgRect:extent),max(4,extent.width*0.08)]) else { throw CameraFailure.message("No se pudo preparar la unión de bordes.") }
        let alpha=image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0,y:0,z:0,w:1),"inputGVector":CIVector(x:0,y:0,z:0,w:1),"inputBVector":CIVector(x:0,y:0,z:0,w:1),"inputAVector":CIVector(x:0,y:0,z:0,w:0),"inputBiasVector":CIVector(x:0,y:0,z:0,w:1)])
        return result.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:alpha])
    }
    private static let featherKernel=CIColorKernel(source:"""
        kernel vec4 feather(vec4 rect,float radius) {
            vec2 p=destCoord()-rect.xy;
            float d=min(min(p.x,rect.z-p.x),min(p.y,rect.w-p.y));
            return vec4(vec3(clamp(d/radius,0.0,1.0)),1.0);
        }
        """)
}

/// Unwrapped yaw avoids the ±180° discontinuity while the camera stays at one
/// viewpoint. Samples are gated by actual angular overlap, not a repeating burst.
struct PanoramaSweepPlan {
    let reference:SphereReference
    private var lastYaw:Float=0
    private var travel:Float=0
    private var lastCaptured:Float=0
    private let initialPitch:Float
    var direction:Float=1
    var distance:Float { max(0,travel*direction) }
    var progress:Double { min(1,Double(distance/170)) }
    var warning:String?
    init(_ sample:SphereMotionSnapshot) throws {
        reference=try SphereReference(sample)
        let f=try reference.pose(sample).forward
        initialPitch=asin(min(1,max(-1,f.y)))*180/Float.pi
    }
    mutating func update(_ sample:SphereMotionSnapshot) throws {
        let f=try reference.pose(sample).forward
        let yaw=atan2(f.x,f.z)*180/Float.pi
        var delta=yaw-lastYaw;if delta>180 {delta-=360};if delta < -180 {delta+=360}
        travel+=delta;lastYaw=yaw
        if abs(travel)>3 && lastCaptured==0 { direction=travel>=0 ? 1:-1 }
        let pitch=asin(min(1,max(-1,f.y)))*180/Float.pi
        warning=sample.rotationSpeed>0.55 ? "Gira más despacio":(abs(pitch-initialPitch)>10 || abs(sample.gravity.x)>0.22 ? "Mantén la flecha en la línea central":nil)
    }
    func needsFrame(fieldOfView:Double)->Bool { warning==nil && distance-lastCaptured>=Float(min(15,max(10,fieldOfView*0.19))) }
    mutating func captured() { lastCaptured=distance }
}

struct PanoramaSweepState:Equatable {
    var sweeping=false,pending=false,finishRequested=false
    mutating func reset() { sweeping=false;pending=false;finishRequested=false }
    func canStitch(validFrames:Int,processing:Bool)->Bool { validFrames>=2 && !processing }
    static func needsTimedSample(now:Double,lastRequest:Double)->Bool { now-lastRequest>=1.2 }
}
