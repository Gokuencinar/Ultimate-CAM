import Foundation

struct PreviewAnalysisOptions: Equatable {
    var histogram=false
    var peaking=false
    var zebras=false
    var colorLook=false
    var edgeThreshold:Double=0.12
    var enabled:Bool { histogram || peaking || zebras || colorLook }
}
struct PreviewLumaMetrics {
    let histogram:[Double]
    let shadows:Double
    let highlights:Double
    let mean:Double
    let width:Int
    let height:Int
    let overlayRGBA:Data
}

/// Bounded analysis of decoded preview luma, not a RAW/sensor exposure meter.
enum PreviewLumaAnalyzer {
    static func measure(_ bytes:UnsafeBufferPointer<UInt8>,width:Int,height:Int,rowBytes:Int,
                        videoRange:Bool,options:PreviewAnalysisOptions) -> PreviewLumaMetrics? {
        guard width>=3,height>=3,rowBytes>=width,height<=Int.max/rowBytes,
              bytes.count>=rowBytes*height,options.edgeThreshold.isFinite,(0.02...0.5).contains(options.edgeThreshold) else { return nil }
        let scale=min(1,160/Double(max(width,height)))
        let w=max(3,Int(Double(width)*scale)),h=max(3,Int(Double(height)*scale))
        var values=[Double](repeating:0,count:w*h),counts=[Double](repeating:0,count:64)
        var dark=0.0,bright=0.0,sum=0.0
        for y in 0..<h { for x in 0..<w {
            let index=min(height-1,y*height/h)*rowBytes+min(width-1,x*width/w)
            let value=min(1,max(0,(Double(bytes[index])-(videoRange ? 16:0))/(videoRange ? 219:255)))
            values[y*w+x]=value;counts[min(63,Int(value*64))]+=1;sum+=value
            if value<=0.02 { dark+=1 };if value>=0.98 { bright+=1 }
        } }
        var overlay=[UInt8](repeating:0,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let p=(y*w+x)*4
            if options.zebras && values[y*w+x]>=0.98 && ((x+y)/3)%2==0 {
                overlay[p]=180;overlay[p+1]=30;overlay[p+2]=30;overlay[p+3]=180
            }
            if options.peaking && x>0 && x<w-1 && y>0 && y<h-1 {
                let gradient=(abs(values[y*w+x+1]-values[y*w+x-1])+abs(values[(y+1)*w+x]-values[(y-1)*w+x]))*0.5
                if gradient>=options.edgeThreshold { overlay[p]=0;overlay[p+1]=220;overlay[p+2]=70;overlay[p+3]=220 }
            }
        } }
        let count=Double(w*h)
        return PreviewLumaMetrics(histogram:counts.map {$0/count},shadows:dark/count,highlights:bright/count,
            mean:sum/count,width:w,height:h,overlayRGBA:Data(overlay))
    }
}
