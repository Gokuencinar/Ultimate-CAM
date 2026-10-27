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
        try checkMultiBand()
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
        let alignment=try PanoramaProcessor().registration(reference:first,floating:second)
        try check(abs(alignment[2].x-128)<3 && abs(alignment[2].y)<3,"Panorama translation sign or pixel coordinates differ from source crops")
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
    static func checkMultiBand() throws {
        let w=256,h=96,e=CGRect(x:0,y:0,width:w,height:h)
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
        var a=[Float](repeating:1,count:w*h*4),b=a,aw=a,bw=a
        for y in 0..<h { for x in 0..<w {
            let j=(y*w+x)*4,v:Float=0.3+0.08*sin(Float(x)*0.3)*cos(Float(y)*0.2)
            for c in 0..<3 {
                a[j+c]=v;b[j+c]=v*0.65*[Float(0.95),1.05,0.9][c]
                aw[j+c]=x<192 ? 1:0;bw[j+c]=x>=64 ? 1:0
                if (110..<138).contains(x) && (28..<68).contains(y) { b[j+c]+=0.16 }
            }
        } }
        func image(_ pixels:[Float])->CIImage { CIImage(bitmapData:pixels.withUnsafeBufferPointer{Data(buffer:$0)},bytesPerRow:w*16,size:e.size,format:.RGBAf,colorSpace:space) }
        let result=try MultiBandStitcher.blend(image(a),coverage:image(aw),image(b),coverage:image(bw),extent:e,context:context)
        var output=a
        output.withUnsafeMutableBytes { context.render(result.image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:e,format:.RGBAf,colorSpace:space) }
        var before=0.0,after=0.0,ghostBefore=0.0,ghostAfter=0.0
        for y in 4..<h-4 { for x in 70..<185 {
            let j=(y*w+x)*4
            for c in 0..<3 {
                let feather=(a[j+c]+b[j+c])*0.5
                before+=pow(Double(feather-a[j+c]),2);after+=pow(Double(output[j+c]-a[j+c]),2)
                if (110..<138).contains(x) && (30..<66).contains(y) {
                    let matched=(a[j+c]+b[j+c]*result.gain[c])*0.5
                    ghostBefore+=pow(Double(matched-a[j+c]),2);ghostAfter+=pow(Double(output[j+c]-a[j+c]),2)
                }
            }
        } }
        print("Panorama RGB gain",result.gain,"join error ratio",after/before,"moving overlap ratio",ghostAfter/ghostBefore)
        try check(after<before*0.35,"Exposure matching + multiband did not reduce join error")
        try check(ghostAfter<ghostBefore*0.4,"Minimum-error seam did not avoid the moved overlap object")
        try check(abs(result.gain.x-1/(0.65*0.95))<0.03 && abs(result.gain.z-1/(0.65*0.9))<0.03,"RGB gain fit lost exposure / colour compensation")
        var costs=[Float](repeating:1,count:32*24)
        for y in 0..<24 { for x in 12...18 { costs[y*32+x]=0.001 } }
        for y in 8..<16 { for x in 14...18 { costs[y*32+x]=10 } }
        let path=MultiBandStitcher.minimumSeam(costs,width:32,height:24)
        try check(path.count==24 && (8..<16).allSatisfy({path[$0]<14}),"DP seam crossed the high-error moving object")
        try check(zip(path,path.dropFirst()).allSatisfy({abs($0-$1)<=1.001}),"Minimum-error seam disconnected")
    }

}
