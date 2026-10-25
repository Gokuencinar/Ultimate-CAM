import CoreImage

/// Rectilinear view into the same equirectangular convention used by SphereProcessor.
/// Pure rendering: no motion service, capture session or photo-library access.
final class SphereViewerRenderer {
    private let context=CIContext(options:[.cacheIntermediates:false])
    func render(_ image:CGImage,yaw:Double,pitch:Double,fieldOfView:Double,width:Int=640,height:Int=400) throws -> CGImage {
        guard image.width==image.height*2,yaw.isFinite,pitch.isFinite,fieldOfView.isFinite,
              abs(pitch)<=Double.pi/2,(30...110).contains(fieldOfView),(64...1024).contains(width),(64...1024).contains(height) else {
            throw CameraFailure.message("La vista 360° no tiene una geometría válida.")
        }
        let input=CIImage(cgImage:image),extent=CGRect(x:0,y:0,width:width,height:height)
        // Duplicate the panorama on either side for bilinear sampling across the seam.
        let w=CGFloat(image.width)
        let repeated=input.transformed(by:CGAffineTransform(translationX:-w,y:0))
            .composited(over:input).composited(over:input.transformed(by:CGAffineTransform(translationX:w,y:0)))
        let focal=Double(width)*0.5/tan(fieldOfView*Double.pi/360)
        guard let output=Self.kernel?.apply(extent:extent,roiCallback:{_,_ in repeated.extent},arguments:[repeated,
            CIVector(x:CGFloat(width),y:CGFloat(height)),CIVector(x:w,y:CGFloat(image.height)),focal,yaw,pitch]),
              let result=context.createCGImage(output,from:extent) else { throw CameraFailure.message("No se pudo dibujar la vista 360°.") }
        return result
    }
    private static let kernel=CIKernel(source:"""
        kernel vec4 sphereView(sampler image,vec2 outputSize,vec2 imageSize,float focal,float yaw,float pitch) {
            vec2 p=(destCoord()-outputSize*0.5)/focal;
            vec3 r=normalize(vec3(p.x,p.y,1.0));
            vec3 t=vec3(r.x,cos(pitch)*r.y+sin(pitch)*r.z,-sin(pitch)*r.y+cos(pitch)*r.z);
            vec3 d=vec3(cos(yaw)*t.x+sin(yaw)*t.z,t.y,-sin(yaw)*t.x+cos(yaw)*t.z);
            float u=atan(d.x,d.z)/6.28318530718+0.5;
            float v=asin(clamp(d.y,-1.0,1.0))/3.14159265359+0.5;
            return sample(image,samplerTransform(image,vec2(u,v)*imageSize));
        }
        """)
}
