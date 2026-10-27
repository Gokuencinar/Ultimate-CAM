import CoreImage

enum HybridZSL {
    static func supportGeometry(_ image:CIImage,angle:Double,previewMirrored:Bool,mirrorOutput:Bool)->CIImage {
        var image=previewMirrored ? image.oriented(.upMirrored):image
        switch Int(angle) { case 0:image=image.oriented(.left);case 180:image=image.oriented(.right);case 270:image=image.oriented(.down);default:break }
        return mirrorOutput ? image.oriented(.upMirrored):image
    }
    static func inject(native:CIImage,support:CIImage)->CIImage {
        let e=native.extent,scale=e.width/support.extent.width
        let enlarged=support.transformed(by:CGAffineTransform(translationX:-support.extent.minX,y:-support.extent.minY))
            .transformed(by:CGAffineTransform(scaleX:scale,y:e.height/support.extent.height))
            .transformed(by:CGAffineTransform(translationX:e.minX,y:e.minY))
        let radius=max(2,scale*2)
        let base=native.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:e)
        let clean=enlarged.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:e)
        return kernel?.apply(extent:e,arguments:[native,base,clean]) ?? native
    }
    private static let kernel=CIColorKernel(source:"""
      kernel vec4 hybridZSL(__sample anchor,__sample base,__sample support) {
       float y=dot(base.rgb,vec3(0.2126,0.7152,0.0722));
       float shadow=(1.0-smoothstep(0.04,0.35,y))*0.7;
       // Keep native spatial frequencies; only substitute low-frequency RGB.
       return vec4(max(anchor.rgb+shadow*(support.rgb-base.rgb),vec3(0.0)),anchor.a);
      }
      """)
}
