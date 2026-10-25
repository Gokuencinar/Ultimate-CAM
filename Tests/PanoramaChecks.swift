import CoreImage
import Foundation
import Darwin
import simd

@main struct PanoramaChecks {
    static func check(_ test:Bool,_ text:String) throws { if !test { throw CameraFailure.message(text) } }
    static func main() {
        do { try run();print("PANORAMA CHECKS PASSED · synthetic overlap and geometry only") }
        catch { fputs("PANORAMA CHECK FAILED: \(error)\n",stderr);exit(1) }
    }
    static func run() throws {
        try check(CoveredRectangle.largest([UInt8](repeating:255,count:32),width:8,height:4)==CGRect(x:0,y:0,width:8,height:4),"Full coverage cropped incorrectly")
        try check(CoveredRectangle.largest([UInt8](repeating:0,count:32),width:8,height:4)==nil,"Empty coverage accepted")
        var mask=[UInt8](repeating:255,count:32);for i in 24..<32 { mask[i]=0 }
        try check(CoveredRectangle.largest(mask,width:8,height:4)==CGRect(x:0,y:0,width:8,height:3),"Coverage gap was not cropped")
        let context=CIContext(options:[.useSoftwareRenderer:true]),space=CGColorSpace(name:CGColorSpace.sRGB)!
        var seed:UInt32=19,pixels=[UInt8](repeating:255,count:768*256*4)
        for y in 0..<256 { for x in 0..<768 { for c in 0..<3 {
            seed=seed &* 1664525 &+ 1013904223;pixels[(y*768+x)*4+c]=UInt8(30+(seed>>24)%190)
        } } }
        let scene=CIImage(bitmapData:Data(pixels),bytesPerRow:768*4,size:CGSize(width:768,height:256),format:.RGBA8,colorSpace:space)
            .clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1]).cropped(to:CGRect(x:0,y:0,width:768,height:256))
        let first=scene.cropped(to:CGRect(x:0,y:0,width:512,height:256))
        let second=scene.cropped(to:CGRect(x:128,y:0,width:512,height:256)).transformed(by:CGAffineTransform(translationX:-128,y:0))
        func encode(_ image:CIImage)->Data { context.pngRepresentation(of:image,format:.RGBA8,colorSpace:space)! }
        let a=encode(first),b=encode(second)
        let result=try PanoramaProcessor().process([a,b],options:ProcessingOptions())
        let rendered=PreviewDecoder.image(result.jpeg,maximumDimension:4096)!
        print("Panorama fixture dimensions: \(rendered.width) × \(rendered.height)")
        try check(rendered.width>600 && rendered.width<650 && rendered.height>235 && rendered.height<=258,
                  "Homography sign, registration or coverage crop is incorrect")
        let translation=simd_float3x3(columns:(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(20,7,1)))
        let warped=try PanoramaProcessor.warp(first,matrix:translation)
        try check(abs(warped.extent.minX-20)<2 && abs(warped.extent.minY-7)<2,"Perspective warp matrix convention differs from source coordinates")
        var rejected=false
        do { _=try PanoramaProcessor().process([a,a],options:ProcessingOptions()) } catch { rejected=true }
        try check(rejected,"Duplicate views were mislabeled as panorama")
        let cancellation=ProcessingCancellation();cancellation.cancel()
        rejected=false
        do { _=try PanoramaProcessor().process([a,b],options:ProcessingOptions(),cancellation:cancellation) } catch { rejected=true }
        try check(rejected,"Cancelled panorama continued processing")
    }
}
