import Foundation

/// Static scene only. Trade ISO for photons and account for bounded AE shortfall.
/// Accepts a separate, confidence-gated preview motion cap; no Night Sight model.
struct NightCapturePlan {
    let seconds: Double
    let iso: Double
    let count: Int
    let compensationEV: Double
    var astro:Bool=false

    static func make(iso: Double, seconds: Double, isoRange: ClosedRange<Double>,
                     durationRange: ClosedRange<Double>, targetOffset: Double = 0,
                     budget: Double = 8, shutterLimit: Double = 1,motionLimit:Double?=nil,tripodStable:Bool=false,astroEnabled:Bool=true) throws -> NightCapturePlan {
        let values = [iso, seconds, isoRange.lowerBound, isoRange.upperBound,
                      durationRange.lowerBound, durationRange.upperBound]
        guard budget.isFinite, (1...16).contains(budget), shutterLimit.isFinite, (1.0/30...1).contains(shutterLimit),
              targetOffset.isFinite, values.allSatisfy({ $0.isFinite && $0 > 0 }),
              isoRange.contains(iso), durationRange.contains(seconds) else {
            throw CameraFailure.message("La medición nocturna no es válida. Vuelve a medir la escena.")
        }
        if let motionLimit { guard motionLimit.isFinite,(1.0/1000...1).contains(motionLimit) else { throw CameraFailure.message("Medición de movimiento fuera de rango.") } }
        // AE can hit its preview ISO/shutter ceiling before reaching its target.
        // Compensate only measured underexposure at high ISO, with a 2 EV cap.
        let compensation = iso >= isoRange.upperBound * 0.8 && seconds >= 1.0 / 30
            ? min(2, max(0, -targetOffset)) : 0
        let meteredProduct = iso * seconds * pow(2, compensation)
        guard meteredProduct.isFinite, seconds <= 1 else {
            throw CameraFailure.message("La medición supera el presupuesto de captura nocturna.")
        }
        if astroEnabled && tripodStable && budget>=8 && meteredProduct/isoRange.lowerBound>=1.0/15 {
            // Sixteen real integrations, bounded by both physical exposure and
            // the user's total integration budget. Never silently turn 8 s into
            // minutes; the physical limit is reached when the budget allows it.
            let duration=min(durationRange.upperBound,shutterLimit,budget/16,meteredProduct/isoRange.lowerBound)
            guard duration>=durationRange.lowerBound else { throw CameraFailure.message("El formato no admite la serie Astro.") }
            let sensitivity=min(isoRange.upperBound,max(isoRange.lowerBound,meteredProduct/duration))
            return NightCapturePlan(seconds:duration,iso:sensitivity,count:16,compensationEV:compensation,astro:true)
        }
        let limit = min(shutterLimit,motionLimit ?? 1, durationRange.upperBound, budget/3)
        guard limit >= durationRange.lowerBound else { throw CameraFailure.message("El formato no permite el límite nocturno elegido.") }
        // At minimum ISO, extending an already bright exposure would clip it.
        let desired = min(limit, meteredProduct / isoRange.lowerBound)
        // Avoid arbitrary long durations that this iPhone reports rounded in
        // DNG EXIF (for example requested 0.834 s becomes declared 1 s).
        let shutters: [Double] = [1, 0.5, 0.25, 0.125, 1.0/15, 1.0/30, 1.0/60,
            1.0/125, 1.0/250, 1.0/500, 1.0/1000, 1.0/2000, 1.0/4000, 1.0/8000]
        let rounded = shutters.first(where: { $0 <= desired && $0 >= durationRange.lowerBound }) ?? desired
        let duration = min(limit, max(durationRange.lowerBound, max(min(seconds, limit), rounded)))
        let sensitivity = min(isoRange.upperBound, max(isoRange.lowerBound, meteredProduct / duration))
        let frames = min(16, max(3, Int(floor(budget / duration))))
        return NightCapturePlan(seconds: duration, iso: sensitivity, count: frames, compensationEV: compensation)
    }
}
