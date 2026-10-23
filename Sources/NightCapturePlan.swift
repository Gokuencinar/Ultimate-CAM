import Foundation

/// Static scene only. Preserve metered exposure while trading ISO for photons.
/// This is not motion metering and does not claim Night Sight equivalence.
struct NightCapturePlan {
    let seconds: Double
    let iso: Double
    let count: Int

    static func make(iso: Double, seconds: Double, isoRange: ClosedRange<Double>,
                     durationRange: ClosedRange<Double>) throws -> NightCapturePlan {
        let values = [iso, seconds, isoRange.lowerBound, isoRange.upperBound,
                      durationRange.lowerBound, durationRange.upperBound]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              isoRange.contains(iso), durationRange.contains(seconds) else {
            throw CameraFailure.message("La medición nocturna no es válida. Vuelve a medir la escena.")
        }
        let meteredProduct = iso * seconds
        guard meteredProduct.isFinite, seconds <= 1 else {
            throw CameraFailure.message("La medición supera el presupuesto de captura nocturna.")
        }
        let limit = min(0.5, durationRange.upperBound)
        // At minimum ISO, extending an already bright exposure would clip it.
        let desired = min(limit, meteredProduct / isoRange.lowerBound)
        let duration = min(durationRange.upperBound, max(durationRange.lowerBound, max(seconds, desired)))
        let sensitivity = min(isoRange.upperBound, max(isoRange.lowerBound, meteredProduct / duration))
        let frames = min(9, max(3, duration <= 4.0 / 9 ? 9 : Int(floor(4 / duration))))
        return NightCapturePlan(seconds: duration, iso: sensitivity, count: frames)
    }
}
