import Foundation

struct NightTonePlan {
    let gain:Double,whitePoint:Double
    static func make(luminances:[Double],maximumGain:Double,highlightCompression:Double=0) throws -> NightTonePlan {
        guard !luminances.isEmpty,maximumGain.isFinite,(1...64).contains(maximumGain),
              highlightCompression.isFinite,(0...1).contains(highlightCompression),luminances.allSatisfy({$0.isFinite && $0>=0}) else { throw CameraFailure.message("Medición tonal no válida.") }
        let sorted=luminances.sorted()
        func percentile(_ p:Double)->Double { sorted[min(sorted.count-1,Int(Double(sorted.count)*p))] }
        let upper=percentile(0.9),highlight=percentile(0.995)
        // Exclude nearly black background from the exposure statistic. Retain
        // actual dim subjects and smoothly downweight bright lamps/speculars.
        let threshold=max(0.0001,highlight*0.001)
        var weightedLog=0.0,totalWeight=0.0
        for value in sorted where value>threshold {
            let shadowWeight=value/(value+0.01)
            let highlightWeight=1/(1+pow(value/max(upper,0.02),2))
            let weight=shadowWeight*highlightWeight
            weightedLog+=log(max(value,1e-6))*weight;totalWeight+=weight
        }
        guard totalWeight>0 else { return NightTonePlan(gain:1,whitePoint:2) }
        let midtone=exp(weightedLog/totalWeight)
        let desired=max(1,0.14/max(midtone,1e-6))
        let midtoneLimit=max(1,0.35/max(upper,1e-6))
        let highlightLimit=max(1,1/max(highlight,1e-6))
        let gain=min(8,maximumGain,desired,midtoneLimit,highlightLimit)
        return NightTonePlan(gain:gain,whitePoint:max(2,highlight*gain)*pow(2,highlightCompression))
    }
}

/// A scene statistic only sets the bounded strength of a local low-signal gate.
/// Bright sodium/LED lights never contribute to this estimate.
enum NightChromaticityPlan {
    static func strength(_ rgba:[Float])->Float {
        var dark=0,extreme=0
        for i in stride(from:0,to:rgba.count-3,by:4) {
            let r=max(0,rgba[i]),g=max(0,rgba[i+1]),b=max(0,rgba[i+2])
            let l:Float=0.2126*r+0.7152*g+0.0722*b
            guard l>0.005,l<0.07 else { continue };dark+=1
            let excess=max(max(0,g-max(r,b)),max(0,min(r,g)-1.8*b))
            if excess/l>0.35 { extreme+=1 }
        }
        guard dark>=8 else { return 0.15 }
        return min(0.4,0.15+0.5*Float(extreme)/Float(dark))
    }
}
