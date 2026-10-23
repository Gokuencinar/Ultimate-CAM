import Foundation
import UIKit
import Darwin

struct DiagnosticCaptureRequest {
    let stack: Bool
    let count: Int
    let raw: Bool
    let flash: CameraFlash
    let adjustments: Bool

    init?(_ object: [String: String]) {
        guard Set(object.keys).isSubset(of: ["action", "mode", "count", "raw", "adjustments", "flash"]),
              object["action"] == "capture",
              ["normal", "stack"].contains(object["mode"] ?? "normal"),
              ["true", "false"].contains(object["raw"] ?? "false"),
              ["true", "false"].contains(object["adjustments"] ?? "false"),
              let flash = CameraFlash(rawValue: object["flash"] ?? "off"),
              let count = Int(object["count"] ?? "3"), [3, 5, 7, 9].contains(count) else { return nil }
        stack = object["mode"] == "stack"
        self.count = count
        raw = object["raw"] == "true"
        adjustments = object["adjustments"] == "true"
        self.flash = flash
        guard !(stack && raw), flash == .off || (!stack && !raw) else { return nil }
    }

    var options: ProcessingOptions {
        var result = ProcessingOptions()
        if adjustments {
            result.noiseReduction = 0.02
            result.sharpening = 0.2
            result.liftShadows = 0.2
        }
        return result
    }
}

/// SSH test entry point. A signal alone never takes a photo: a local request
/// file plus foreground state and the normal camera authorization are required.
final class DiagnosticBridge {
    private var source: DispatchSourceSignal?
    init(capture: @escaping (DiagnosticCaptureRequest) -> Void,
         command: @escaping ([String: String]) -> Void) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            let path = CaptureTrace.file.deletingLastPathComponent().appendingPathComponent("UltimateCAM-request.json")
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let action = object["action"],
                  ["capture", "focus", "lens", "control", "save", "inspect"].contains(action) else {
                CaptureTrace.record("diagnostic.ignored", ["reason": "no local request"])
                return
            }
            try? FileManager.default.removeItem(at: path)
            guard UIApplication.shared.applicationState == .active else {
                CaptureTrace.record("diagnostic.ignored", ["reason": "application not foreground"])
                return
            }
            if action == "capture" {
                guard let request = DiagnosticCaptureRequest(object) else {
                    CaptureTrace.record("diagnostic.ignored", ["reason": "invalid capture request"])
                    return
                }
                CaptureTrace.record("diagnostic.capture", ["mode": request.stack ? "stack" : "normal",
                    "count": request.stack ? request.count : 1, "raw": request.raw,
                    "adjustments": request.adjustments])
                capture(request)
            } else {
                CaptureTrace.record("diagnostic.command", ["action": action])
                command(object)
            }
        }
        source.resume()
        self.source = source
    }
    deinit { source?.cancel() }
}
