import CoreImage
import simd

struct SphereImageFrame {
    let data:Data
    let pose:SpherePose
    /// Horizontal field of view of the landscape capture format. The camera
    /// is held upright, so this corresponds to the long side after orientation.
    let fieldOfView:Double
}

final class SphereProcessor {
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context=CIContext(options:[.workingColorSpace:space,.cacheIntermediates:false])
    func process(_ frames:[SphereImageFrame],width:Int=4096,cancellation:ProcessingCancellation?=nil,
                 minimumCoverage:Double=0,progress:((String)->Void)?=nil) throws -> CaptureResult {
        guard (2...62).contains(frames.count),[512,1024,2048,4096].contains(width),minimumCoverage.isFinite,(0...1).contains(minimumCoverage) else { throw CameraFailure.message("Configuración esférica fuera de límites.") }
        defer { context.clearCaches() }
        let extent=CGRect(x:0,y:0,width:width,height:width/2)
        var mean=CIImage(color:CIColor.clear).cropped(to:extent),weight=CIImage(color:.black).cropped(to:extent)
        for (index,frame) in frames.enumerated() {
            try cancellation?.check();progress?("Proyectando esfera \(index+1) de \(frames.count)…")
            let joined=try autoreleasepool { () throws -> MultiBandStitcher.Result in
            guard frame.pose.sphereToDevice.columns.0.x.isFinite,frame.pose.sphereToDevice.columns.1.y.isFinite,frame.pose.sphereToDevice.columns.2.z.isFinite,frame.fieldOfView.isFinite,(30...130).contains(frame.fieldOfView),let decoded=CIImage(data:frame.data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("Fotograma esférico no válido.") }
            let target=max(128,min(1400,Double(width)*frame.fieldOfView/360*1.15))
            let scale=min(1,target/max(decoded.extent.width,decoded.extent.height))
            var image=decoded.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            image=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            let focal=max(image.extent.width,image.extent.height)*0.5/tan(frame.fieldOfView*Double.pi/360)
            let matrix=frame.pose.sphereToDevice
            let rows=(0..<3).map { row in CIVector(x:CGFloat(matrix[0][row]),y:CGFloat(matrix[1][row]),z:CGFloat(matrix[2][row])) }
            guard let projected=Self.projectKernel?.apply(extent:extent,roiCallback:{_,_ in image.extent},arguments:[image,
                CIVector(x:CGFloat(width),y:CGFloat(width/2)),CIVector(x:image.extent.width,y:image.extent.height),
                focal,rows[0],rows[1],rows[2]]),
                let color=Self.colorKernel?.apply(extent:extent,arguments:[projected]),
                let coverage=Self.coverKernel?.apply(extent:extent,arguments:[projected]) else { throw CameraFailure.message("No se pudo proyectar la esfera.") }
            return try MultiBandStitcher.blend(mean,coverage:weight,color,coverage:coverage,
                extent:extent,context:context,wrapX:true,cancellation:cancellation)
            }
            mean=joined.image;weight=joined.coverage
        }
        try cancellation?.check()
        let mask=weight.applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.001])
            .applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:extent)])
        var coverage=[Float](repeating:0,count:4)
        coverage.withUnsafeMutableBytes { context.render(mask,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:nil) }
        guard coverage[0].isFinite,coverage[0]>0.001,Double(coverage[0])>=minimumCoverage else {
            throw CameraFailure.message("La esfera solo cubre el \(Int(max(0,coverage[0])*100)) %. Añade fotos en los huecos antes de guardar.")
        }
        let output:CIImage
        if coverage[0]<0.995 {
            func ambientColor(_ region:CGRect,fallback:CIColor)->CIColor {
                let avg=mean.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:region)])
                var p=[Float](repeating:0,count:4)
                p.withUnsafeMutableBytes { context.render(avg,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space) }
                guard p.allSatisfy(\.isFinite),p[3]>0.005 else { return fallback }
                func channel(_ c:Int)->CGFloat { CGFloat(min(0.7,max(0.015,p[c]/p[3]*0.75))) }
                return CIColor(red:channel(0),green:channel(1),blue:channel(2))
            }
            let neutral=CIColor(red:0.05,green:0.06,blue:0.08)
            let bottom=ambientColor(CGRect(x:0,y:0,width:width,height:width/4),fallback:neutral)
            let top=ambientColor(CGRect(x:0,y:width/4,width:width,height:width/4),fallback:bottom)
            guard let gradient=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0,y:extent.height),"inputColor0":bottom,"inputColor1":top])?.outputImage else { throw CameraFailure.message("No se pudo preparar el fondo ambiental.") }
            let ambient=gradient.cropped(to:extent)
            let soft=weight.applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.02]).clampedToExtent()
                .applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:3])
                .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:5]).cropped(to:extent)
            output=mean.composited(over:ambient).applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:ambient,kCIInputMaskImageKey:soft]).cropped(to:extent)
        } else { output=mean }
        let rendered=try JPEGRenderer.render(output,extent:extent,options:ProcessingOptions(),context:context)
        let jpeg=try SphereMetadata.add(to:rendered.data,width:rendered.width,height:rendered.height,sources:frames.count)
        return CaptureResult(jpeg:jpeg,reference:frames[0].data,
            details:"\(coverage[0]<0.995 ? "Esfera parcial":"Esfera 360°") · \(frames.count) fotos · \(rendered.width) × \(rendered.height) · cobertura \(String(format:"%.1f",coverage[0]*100)) %. Orientación relativa; sin rumbo GPS ni corrección de paralaje.",
            mergedFrames:frames.count,source:"guided-equirectangular-sphere")
    }
    private static let projectKernel=CIKernel(source:"""
        kernel vec4 sphereProject(sampler frame,vec2 outputSize,vec2 inputSize,float focal,vec3 row0,vec3 row1,vec3 row2) {
            vec2 q=destCoord()/outputSize;
            float yaw=(q.x-0.5)*6.28318530718, pitch=(q.y-0.5)*3.14159265359;
            vec3 ray=vec3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch));
            vec3 p=vec3(dot(row0,ray),dot(row1,ray),dot(row2,ray));
            float z=-p.z;
            if (z<=0.0001) return vec4(0.0);
            vec2 uv=focal*p.xy/z+inputSize*0.5;
            if (uv.x<0.0 || uv.x>=inputSize.x || uv.y<0.0 || uv.y>=inputSize.y) return vec4(0.0);
            float edge=min(min(uv.x,inputSize.x-uv.x),min(uv.y,inputSize.y-uv.y));
            float w=smoothstep(0.0,min(inputSize.x,inputSize.y)*0.08,edge);
            vec4 color=sample(frame,samplerTransform(frame,uv));
            return vec4(unpremultiply(color).rgb*w,w);
        }
        """)
    private static let coverKernel=CIColorKernel(source:"kernel vec4 cover(__sample p) {return vec4(vec3(p.a),1.0);}")
    private static let colorKernel=CIColorKernel(source:"kernel vec4 color(__sample p) {return vec4(unpremultiply(p).rgb,p.a>0.00001 ? 1.0:0.0);}")
}
