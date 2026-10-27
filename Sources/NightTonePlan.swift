import Foundation

struct NightTonePlan {
    let gain:Double,whitePoint:Double
    static func make(luminances:[Double],maximumGain:Double) throws -> NightTonePlan {
        guard !luminances.isEmpty,maximumGain.isFinite,(1...64).contains(maximumGain),
              luminances.allSatisfy({$0.isFinite && $0>=0}) else { throw CameraFailure.message("Medición tonal no válida.") }
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
        let desired=max(1,0.18/max(midtone,1e-6))
        let midtoneLimit=max(1,0.5/max(upper,1e-6))
        let highlightLimit=max(2,2/max(highlight,1e-6))
        let gain=min(maximumGain,desired,midtoneLimit,highlightLimit)
        return NightTonePlan(gain:gain,whitePoint:max(2,highlight*gain))
    }
}
