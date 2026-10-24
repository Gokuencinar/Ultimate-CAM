import Foundation

enum SinglePhotoQuality: String, Codable, CaseIterable, Identifiable {
    case speed, balanced, quality
    var id: String { rawValue }
    var label: String {
        switch self { case .speed: return "Rapidez"; case .balanced: return "Equilibrado"; case .quality: return "Calidad iOS" }
    }
}

/// Quality is a request to Apple's ISP, not a selector for Camera's Night mode.
/// Manual exposure and app-managed bursts need exactly the requested exposure.
enum PhotoCapturePolicy {
    static func priority(requested: SinglePhotoQuality, count: Int, raw: Bool,
                         customExposure: Bool, lockedExposure: Bool) -> SinglePhotoQuality {
        count == 1 && !raw && !customExposure && !lockedExposure ? requested : .speed
    }
}
