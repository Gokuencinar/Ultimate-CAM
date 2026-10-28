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
                     budget requestedBudget: Double = 8, shutterLimit: Double = 1,motionLimit:Double?=nil,tripodStable:Bool=false,astroEnabled:Bool=true,resources:CaptureResourceBudget = .unrestricted) throws -> NightCapturePlan {
        let values = [iso, seconds, isoRange.lowerBound, isoRange.upperBound,
                      durationRange.lowerBound, durationRange.upperBound]
        guard requestedBudget.isFinite, (1...16).contains(requestedBudget), shutterLimit.isFinite, (1.0/30...1).contains(shutterLimit),
              targetOffset.isFinite, values.allSatisfy({ $0.isFinite && $0 > 0 }),
              isoRange.contains(iso), durationRange.contains(seconds) else {
            throw CameraFailure.message("La medición nocturna no es válida. Vuelve a medir la escena.")
        }
        let budget=max(1,requestedBudget*resources.nightBudgetScale)
        if let motionLimit { guard motionLimit.isFinite,(1.0/1000...1).contains(motionLimit) else { throw CameraFailure.message("Medición de movimiento fuera de rango.") } }
        // Preserve AE's measured sensor exposure. A preview target offset is
        // not highlight headroom and must not request an extra +2 EV in RAW.
        let compensation=0.0
        let meteredProduct=iso*seconds
        guard meteredProduct.isFinite, seconds <= 1 else {
            throw CameraFailure.message("La medición supera el presupuesto de captura nocturna.")
        }
        if astroEnabled && tripodStable && budget>=8 && meteredProduct/isoRange.lowerBound>=1.0/15 {
            // Maximize photons per integration before choosing the frame count.
            // Forcing sixteen half-length shots at the same total integration
            // adds read noise with no extra photons. Retain at least four views
            // for subpixel reconstruction and at most sixteen for bounded RAM.
            let duration=min(durationRange.upperBound,shutterLimit,budget/4,meteredProduct/isoRange.lowerBound)
            guard duration>=durationRange.lowerBound else { throw CameraFailure.message("El formato no admite la serie Astro.") }
            let sensitivity=min(isoRange.upperBound,max(isoRange.lowerBound,meteredProduct/duration))
            let frames=min(resources.maximumFrames,max(4,Int(floor(budget/duration))))
            return NightCapturePlan(seconds:duration,iso:sensitivity,count:frames,compensationEV:compensation,astro:true)
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
        let frames = min(resources.maximumFrames, max(3, Int(floor(budget / duration))))
        return NightCapturePlan(seconds: duration, iso: sensitivity, count: frames, compensationEV: compensation)
    }
}

/// Deterministic host-testable policy. CameraModel samples thermal/memory state;
/// planner and preview do not infer pressure from unrelated image statistics.
struct CaptureResourceBudget:Equatable {
    let maximumFrames:Int,previewInterval:Double,temporalInterval:Double,temporalBytes:Int,nightBudgetScale:Double
    static let unrestricted=Self(maximumFrames:16,previewInterval:0.2,temporalInterval:1.0/15,temporalBytes:48*1024*1024,nightBudgetScale:1)
    static func make(thermal:ProcessInfo.ThermalState,memoryPressure:Bool=false)->Self {
        if memoryPressure || thermal == .critical { return Self(maximumFrames:4,previewInterval:1,temporalInterval:0.25,temporalBytes:8*1024*1024,nightBudgetScale:0.35) }
        if thermal == .serious { return Self(maximumFrames:8,previewInterval:0.5,temporalInterval:0.125,temporalBytes:16*1024*1024,nightBudgetScale:0.6) }
        if thermal == .fair { return Self(maximumFrames:12,previewInterval:0.25,temporalInterval:1.0/12,temporalBytes:32*1024*1024,nightBudgetScale:0.85) }
        return unrestricted
    }
}

/// An advisory notification alone is never a cancellation decision.
enum CaptureMemoryPolicy {
    static let criticalBytes:UInt64=35*1024*1024
    static func isCritical(availableBytes:UInt64)->Bool { availableBytes<criticalBytes }
}
