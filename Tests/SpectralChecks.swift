import CoreImage
import Foundation
import Darwin

@main struct SpectralChecks {
    struct Oracle:Decodable { let upstream_revision:String;let side:Int;let cases:[Example] }
    struct Example:Decodable { let name:String;let sigma:Float;let strength:Float;let frames:[[Float]];let expected:[Float] }
    static let context=CIContext(options:[.useSoftwareRenderer:true,.cacheIntermediates:false])
    static let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    static func check(_ condition:Bool,_ text:String) throws { if !condition { throw CameraFailure.message(text) } }
    static func rejected(_ body:()throws->Void) throws {
        do { try body() } catch { return };throw CameraFailure.message("Invalid spectral input accepted")
    }
    static func main() {
        do { try run();print("SPECTRAL CHECKS PASSED · pinned Google research NumPy parity, synthetic noise/detail, borders and cancellation; no device quality proof") }
        catch { fputs("SPECTRAL CHECK FAILED: \(error)\n",stderr);exit(1) }
    }
    static func image(_ values:[Float],width:Int,height:Int) -> CIImage {
        CIImage(bitmapData:values.withUnsafeBufferPointer { Data(buffer:$0) },bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
    }
    static func pixels(_ image:CIImage,extent:CGRect) -> [Float] {
        var data=[Float](repeating:0,count:Int(extent.width*extent.height)*4)
        data.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:Int(extent.width)*16,bounds:extent,format:.RGBAf,colorSpace:space) };return data
    }
    static func run() throws {
        let oracle=try JSONDecoder().decode(Oracle.self,from:Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/GoogleWiener32.json")))
        try check(oracle.side==32 && oracle.upstream_revision=="7ff07e009568778ff337c259e192d1d81aedbea6","Unknown spectral reference")
        let fft=try ResearchWienerTile()
        for item in oracle.cases {
            let reference=item.frames[0]
            var mean=zip(reference,fft.window).map(*)
            for frame in item.frames.dropFirst() {
                let next=try fft.regularize(reference:reference,sample:frame,sigma:item.sigma,strength:item.strength)
                for i in mean.indices { mean[i]+=next[i] }
            }
            for i in mean.indices { mean[i]/=Float(item.frames.count) }
            let error=zip(mean,item.expected).map { abs($0-$1) }.max()!
            try check(error<0.00002,"Swift FFT differs from upstream NumPy: \(item.name), max error \(error)")
            print("Research FFT parity:",item.name,"max error",error)
        }
        try rejected { _=try fft.regularize(reference:[0],sample:[0],sigma:0.02) }
        try rejected { _=try fft.regularize(reference:[Float](repeating:0,count:1024),sample:[Float](repeating:0,count:1024),sigma:0) }
        let width=96,height=64,extent=CGRect(x:0,y:0,width:96,height:64)
        var first=[Float](repeating:1,count:width*height*4),second=first,state:UInt32=42
        func noise() -> Float {
            state=1664525 &* state &+ 1013904223;let u=max(0.000001,Double(state)/Double(UInt32.max))
            state=1664525 &* state &+ 1013904223;let v=Double(state)/Double(UInt32.max)
            return Float(sqrt(-2*log(u))*cos(2*Double.pi*v)*0.02)
        }
        for y in 0..<height { for x in 0..<width {
            let moving=(32..<64).contains(x) && (16..<48).contains(y)
            let value:Float=moving ? ((x+y)%2==0 ? 0.2:0.7):0.3
            let other:Float=moving ? 0.9-value:value
            for c in 0..<3 { first[(y*width+x)*4+c]=value+noise();second[(y*width+x)*4+c]=other+noise() }
        } }
        let anchor=image(first,width:width,height:height),sample=image(second,width:width,height:height)
        let filter=try ResearchWienerFilter(reference:anchor,context:context)
        let identity=pixels(try filter.filter(anchor,extent:extent),extent:extent)
        try check(zip(first,identity).allSatisfy { abs($0-$1)<0.0001 },"Overlapping FFT tiles changed identity or damaged borders")
        let regularized=try filter.filter(sample,extent:extent)
        let merged=WeightedTemporalMerger(reference:anchor,context:context)
        let result=pixels(try merged.append(regularized,extent:extent,rejectMotion:false,sigma:3),extent:extent)
        let baseline=WeightedTemporalMerger(reference:anchor,context:context)
        let old=pixels(try baseline.append(sample,extent:extent,rejectMotion:true,sigma:3),extent:extent)
        func contrast(_ data:[Float]) -> Float {
            var sum:Float=0;var count:Float=0
            for y in 20..<44 { for x in 36..<60 { sum+=data[(y*width+x)*4]*((x+y)%2==0 ? -1:1);count+=1 } }
            return 2*sum/count
        }
        try check(contrast(result)>contrast(old)+0.2,"Spectral rejection lost moving fine detail like the coarse mask")
        var before:Double=0,after:Double=0,count=0
        for y in 0..<height { for x in 0..<width where x<16 || x>=80 {
            for c in 0..<3 { before+=pow(Double(first[(y*width+x)*4+c])-0.3,2);after+=pow(Double(result[(y*width+x)*4+c])-0.3,2);count+=1 }
        } }
        try check(after<before*0.95,"Spectral temporal result did not reduce static-region noise")
        print("Synthetic spectral contrast:",contrast(result),"coarse baseline:",contrast(old),"static RMSE",sqrt(before/Double(count)),"->",sqrt(after/Double(count)))
        let token=ProcessingCancellation();token.cancel()
        try rejected { _=try filter.filter(sample,extent:extent,cancellation:token) }
        try rejected { _=try filter.filter(sample,extent:CGRect(x:-1,y:0,width:96,height:64)) }
        var options=ProcessingOptions();options.nightStatic=true;options.nightSpectralFusion=true;options.nightSpectralStrength=1.5
        try check(try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(options))==options,"Spectral recipe did not round trip")
        var texture=[Float](repeating:1,count:256*192*4)
        for y in 0..<192 { for x in 0..<256 { for c in 0..<3 { texture[(y*256+x)*4+c]=Float(30+(x*13+y*7+c*53)%190)/255 } } }
        let png=context.pngRepresentation(of:image(texture,width:256,height:192),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)!
        options.chooseSharpestReference=false;options.nightWeightedFusion=false
        let pipeline=try BurstProcessor().process([png,png],options:options)
        try check(pipeline.mergedFrames==2 && pipeline.details.contains("FFT de investigación"),"Night capture pipeline did not use the spectral implementation")
        options.rejectMotion=false;try rejected { _=try options.validated() }
    }
}
