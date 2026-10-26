import Foundation

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

