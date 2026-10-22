import Foundation

/// Bounded local diagnostics. Never records pixels, photo metadata or credentials.
enum CaptureTrace {
    private static let queue = DispatchQueue(label: "com.gokuencinar.ultimatecam.trace")
    static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UltimateCAM-capture.jsonl")

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        queue.async {
            var entry = fields
            entry["event"] = event
            entry["time"] = ISO8601DateFormatter().string(from: Date())
            guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 131072 || !FileManager.default.fileExists(atPath: file.path) {
                    try data.write(to: file, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch { NSLog("Ultimate CAM: capture trace unavailable: %@", error.localizedDescription) }
        }
    }
}
