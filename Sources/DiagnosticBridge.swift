import Foundation
import UIKit
import Darwin

struct DiagnosticCaptureRequest {
    let stack: Bool
    let count: Int
    let raw: Bool
    let flash: CameraFlash
    let adjustments: Bool
    let night: Bool
    let nativeNight:Bool
    let nightRAW: Bool
    let spectral:Bool
    let spectralStrength:Double
    let nightBudget:Double
    let nightShutterLimit:Double
    let mirrorSelfie:Bool

    init?(_ object: [String: String]) {
        guard Set(object.keys).isSubset(of: ["action", "mode", "count", "raw", "adjustments", "flash", "nightRaw","spectral","spectralStrength","nightBudget","nightShutterLimit","mirrorSelfie"]),
              object["action"] == "capture",
              ["normal", "stack", "night", "iosNight"].contains(object["mode"] ?? "normal"),
              ["true", "false"].contains(object["raw"] ?? "false"),
              ["true", "false"].contains(object["nightRaw"] ?? "false"),
              ["true", "false"].contains(object["adjustments"] ?? "false"),
              ["true", "false"].contains(object["spectral"] ?? "false"),
              ["true", "false"].contains(object["mirrorSelfie"] ?? "false"),
              let strength=Double(object["spectralStrength"] ?? "1"),strength.isFinite,(0.25...4).contains(strength),
              let budget=Double(object["nightBudget"] ?? "8"),budget.isFinite,(1...16).contains(budget),
              let limit=Double(object["nightShutterLimit"] ?? "1"),limit.isFinite,(1.0/30...1).contains(limit),
              let flash = CameraFlash(rawValue: object["flash"] ?? "off"),
              let count = Int(object["count"] ?? "3"), [3, 5, 7, 9].contains(count) else { return nil }
        nativeNight=object["mode"] == "iosNight"
        night = object["mode"] == "night"
        nightRAW = object["nightRaw"] == "true"
        spectral=object["spectral"] == "true";spectralStrength=strength;nightBudget=budget;nightShutterLimit=limit
        mirrorSelfie=object["mirrorSelfie"] == "true"
        stack = object["mode"] == "stack" || night
        self.count = count
        raw = object["raw"] == "true"
        adjustments = object["adjustments"] == "true"
        self.flash = flash
        guard (!nightRAW && !spectral) || night else { return nil }
        guard !nativeNight || (!raw && flash == .off && !nightRAW && !spectral) else { return nil }
        guard !(stack && raw), flash == .off || (!stack && !raw) else { return nil }
    }

    var options: ProcessingOptions {
        var result = ProcessingOptions()
        if nativeNight { result=PhotoModePolicy.nativeNight(from:result) }
        if night {
            result.nightStatic = true
            result.nightRAW = nightRAW
            result.nightSpectralFusion=spectral;result.nightSpectralStrength=spectralStrength
            result.nightBudget=nightBudget;result.nightShutterLimit=nightShutterLimit
            result.maximumDimension = 4096
            result.noiseReduction = 0.012
            result.sharpening = 0.1
        }
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
                  ["capture", "focus", "lens", "control", "save", "inspect", "export"].contains(action) else {
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
                CaptureTrace.record("diagnostic.capture", ["mode": request.night ? "night" : (request.stack ? "stack" : "normal"),
                    "count": request.stack ? request.count : 1, "raw": request.raw,
                    "adjustments": request.adjustments,"spectral":request.spectral,"mirrorSelfie":request.mirrorSelfie])
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
