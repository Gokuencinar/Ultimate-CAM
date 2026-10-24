import Foundation

struct FrameExposure: Codable, Equatable {
    let seconds: Double
    let iso: Double
    var product: Double { seconds * iso }
    var isValid: Bool { seconds.isFinite && iso.isFinite && seconds > 0 && seconds <= 60 && iso > 0 && product.isFinite }
}

/// Three actual exposures, anchored at the metered frame. This is an original
/// bracket planner, not Google's HDR+ exposure/motion scheduling algorithm.
enum HDRCapturePlan {
    static func make(iso: Double, seconds: Double, span: Double,
                     isoRange: ClosedRange<Double>, durationRange: ClosedRange<Double>) throws -> [FrameExposure] {
        guard iso.isFinite, seconds.isFinite, iso > 0, seconds > 0, span.isFinite, (1...3).contains(span),
              isoRange.lowerBound > 0, isoRange.upperBound.isFinite,
              durationRange.lowerBound > 0, durationRange.upperBound.isFinite else {
            throw CameraFailure.message("Medición HDR fuera de rango.")
        }
        let baseISO = min(isoRange.upperBound,max(isoRange.lowerBound,iso))
        let maximumDuration = min(0.5,durationRange.upperBound)
        guard durationRange.lowerBound <= maximumDuration else { throw CameraFailure.message("El formato no admite el horquillado HDR.") }
        let baseDuration = min(maximumDuration,max(durationRange.lowerBound,seconds))
        let anchor = FrameExposure(seconds:baseDuration,iso:baseISO)
        let frames = [0.0,-span,span].map { ev -> FrameExposure in
            let target = anchor.product * pow(2,ev)
            let duration = min(maximumDuration,max(durationRange.lowerBound,baseDuration*pow(2,ev)))
            let gain = min(isoRange.upperBound,max(isoRange.lowerBound,target/duration))
            return FrameExposure(seconds:duration,iso:gain)
        }
        guard frames.allSatisfy(\.isValid), log2(frames[2].product/frames[1].product) >= 1 else {
            throw CameraFailure.message("La lente no permite suficiente separación de exposición para HDR.")
        }
        return frames
    }
}
