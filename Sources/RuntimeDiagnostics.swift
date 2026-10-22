import Foundation
import Darwin

/// Read-only state for the SSH probe, including when local file logging fails.
/// This channel never accepts commands or publishes image data.
enum RuntimeDiagnostics {
    private static let lock = NSLock()
    private static var tokens: [String: Int32] = [:]
    private static var initialized = false

    private static func set(_ suffix: String, _ value: UInt64) {
        let name = "com.gokuencinar.ultimatecam.diagnostic." + suffix
        var token = tokens[name] ?? 0
        if tokens[name] == nil {
            guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
            tokens[name] = token
        }
        _ = notify_set_state(token, value)
    }

    private static func string(_ name: String, _ value: String, limit: Int) {
        let bytes = Array(value.utf8.prefix(limit))
        set(name + ".length", UInt64(bytes.count))
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            var word: UInt64 = 0
            for index in offset..<min(offset + 8, bytes.count) {
                word |= UInt64(bytes[index]) << ((index - offset) * 8)
            }
            set(name + "." + String(offset / 8), word)
        }
    }

    static func record(_ event: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        if !initialized {
            set("pid", UInt64(getpid()))
            set("build", UInt64(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0)
            string("path", path, limit: 768)
            set("writeError", 0)
            initialized = true
        }
        string("event", event, limit: 96)
    }

    static func writeError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        let value = error as NSError
        set("writeError", UInt64(bitPattern: Int64(value.code)))
        string("errorDomain", value.domain, limit: 96)
    }
}
