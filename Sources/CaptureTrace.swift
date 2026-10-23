import Foundation

/// Bounded local diagnostics. Records exposure/ISO/timestamps only; no pixels, location or credentials.
enum CaptureTrace {
    private static let queue = DispatchQueue(label: "com.gokuencinar.ultimatecam.trace")
    private static var sequence: UInt64 = 0
    static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UltimateCAM-capture.jsonl")

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        RuntimeDiagnostics.record(event, path: file.path)
        queue.async {
            sequence += 1
            var entry = fields
            entry["sequence"] = sequence
            entry["event"] = event
            entry["time"] = ISO8601DateFormatter().string(from: Date())
            entry["pid"] = ProcessInfo.processInfo.processIdentifier
            entry["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 131072 {
                    let previous = file.appendingPathExtension("previous")
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    try data.write(to: file, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                RuntimeDiagnostics.writeError(error)
                NSLog("Ultimate CAM: capture trace unavailable: %@", error.localizedDescription)
            }
        }
    }
}
