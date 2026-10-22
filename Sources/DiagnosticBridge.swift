import Foundation
import UIKit
import Darwin

/// SSH test entry point. A signal alone never takes a photo: a local request
/// file plus foreground state and the normal camera authorization are required.
final class DiagnosticBridge {
    private var source: DispatchSourceSignal?
    init(capture: @escaping (Bool) -> Void) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            let path = CaptureTrace.file.deletingLastPathComponent().appendingPathComponent("UltimateCAM-request.json")
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  object["action"] == "capture" else {
                CaptureTrace.record("diagnostic.ignored", ["reason": "no local request"])
                return
            }
            try? FileManager.default.removeItem(at: path)
            guard UIApplication.shared.applicationState == .active else {
                CaptureTrace.record("diagnostic.ignored", ["reason": "application not foreground"])
                return
            }
            CaptureTrace.record("diagnostic.capture", ["mode": object["mode"] ?? "normal"])
            capture(object["mode"] == "stack")
        }
        source.resume()
        self.source = source
    }
    deinit { source?.cancel() }
}
