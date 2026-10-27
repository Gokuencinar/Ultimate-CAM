import CoreImage
import CoreVideo
#if os(iOS)
import AVFoundation
import ImageIO
#endif

/// Disparity and validity share the upright photo geometry. Invalid depth never
/// becomes a false near/far surface; those pixels fall back to the person matte.
struct PortraitDepth {
    let disparity:CIImage
    let validity:CIImage
    func aligned(to extent:CGRect)->PortraitDepth? {
        let e=disparity.extent
        guard e.width>0,e.height>0,abs(e.width/e.height-extent.width/extent.height)<0.03 else { return nil }
        let transform=CGAffineTransform(translationX:-e.minX,y:-e.minY)
            .concatenating(CGAffineTransform(scaleX:extent.width/e.width,y:extent.height/e.height))
            .concatenating(CGAffineTransform(translationX:extent.minX,y:extent.minY))
        return PortraitDepth(disparity:disparity.transformed(by:transform),validity:validity.transformed(by:transform))
    }
    #if os(iOS)
    static func capture(_ value:AVDepthData,orientation:UInt32)->PortraitDepth? {
        let depth=value.applyingExifOrientation(CGImagePropertyOrientation(rawValue:orientation) ?? .up)
            .converting(toDepthDataType:kCVPixelFormatType_DisparityFloat32)
        let pixel=depth.depthDataMap
        CVPixelBufferLockBaseAddress(pixel,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(pixel) else { return nil }
        let w=CVPixelBufferGetWidth(pixel),h=CVPixelBufferGetHeight(pixel),row=CVPixelBufferGetBytesPerRow(pixel)
        var samples=[Float]()
        for y in stride(from:0,to:h,by:max(1,h/96)) { for x in stride(from:0,to:w,by:max(1,w/96)) {
            let d=base.load(fromByteOffset:y*row+x*4,as:Float.self)
            if d.isFinite && d>0 { samples.append(d) }
        } }
        guard samples.count>=32 else { return nil };samples.sort()
        let low=samples[samples.count/100],high=samples[min(samples.count-1,samples.count*99/100)]
        guard high-low>1e-5,let kernel=normalize else { return nil }
        let image=CIImage(cvPixelBuffer:pixel)
        guard let packed=kernel.apply(extent:image.extent,arguments:[image,low,high]) else { return nil }
        // Normalization packs validity in G, then exposes both as gray images.
        let validity=packed.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0,y:1,z:0,w:0),"inputGVector":CIVector(x:0,y:1,z:0,w:0),"inputBVector":CIVector(x:0,y:1,z:0,w:0)])
        return PortraitDepth(disparity:packed,validity:validity)
    }
    private static let normalize=CIColorKernel(source:"""
     kernel vec4 normalizeDisparity(__sample d,float low,float high) {
      float valid=(d.r>0.0 && d.r<1.0e6) ? 1.0:0.0;
      float value=valid>0.5 ? clamp((d.r-low)/(high-low),0.0,1.0):0.0;
      return vec4(value,valid,0.0,1.0);
     }
     """)
    #endif
}
