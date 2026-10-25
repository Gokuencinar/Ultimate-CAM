import Foundation

enum CaptureRotation {
    /// Keep pixel axes rectangular. The device coordinator supplies the angle;
    /// never infer front-camera rotation by swapping landscape labels ourselves.
    static func cardinal(_ degrees:Double) throws -> Double {
        guard degrees.isFinite else { throw CameraFailure.message("No se pudo leer la orientación de captura.") }
        let normalized=(degrees.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
        return (normalized/90).rounded().truncatingRemainder(dividingBy:4)*90
    }
}
