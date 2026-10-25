import Foundation

enum MovieResolution: String, Codable, CaseIterable, Identifiable {
    case hd, fullHD, ultraHD
    var id: String { rawValue }
    var label: String { switch self { case .hd: return "720p"; case .fullHD: return "1080p"; case .ultraHD: return "4K" } }
    var width: Int { switch self { case .hd: return 1280; case .fullHD: return 1920; case .ultraHD: return 3840 } }
    var height: Int { width * 9 / 16 }
}
enum MovieCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}
struct MovieConfiguration: Codable, Equatable {
    var resolution = MovieResolution.fullHD
    var fps = 30
    var codec = MovieCodec.hevc
    var audio = true
    var stabilized = true
    func validated() throws -> Self {
        guard [24,30,60].contains(fps) else { throw CameraFailure.message("Elige 24, 30 o 60 FPS.") }
        return self
    }
    func matches(width: Int, height: Int, ranges: [ClosedRange<Double>]) -> Bool {
        width == resolution.width && height == resolution.height && ranges.contains { $0.contains(Double(fps)) }
    }
}

/// Queue-owned lifecycle. A late delegate/PhotoKit completion cannot change a
/// newer recording, and no second recording/save starts while one is pending.
struct MovieRecordingState {
    enum Phase: String { case idle, recording, finishing, review, saving }
    private(set) var phase = Phase.idle
    private(set) var token: UUID?
    var busy: Bool { [.recording,.finishing,.saving].contains(phase) }
    mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        token=UUID();phase = .recording;return token
    }
    mutating func stop() -> Bool { guard phase == .recording else { return false };phase = .finishing;return true }
    mutating func finished(_ id: UUID, valid: Bool) -> Bool {
        guard token==id, phase == .recording || phase == .finishing else { return false }
        phase = valid ? .review : .idle
        if !valid { token=nil }
        return true
    }
    mutating func recover() -> Bool {
        guard phase == .idle else { return false };token=UUID();phase = .review;return true
    }
    mutating func beginSave() -> UUID? { guard phase == .review else { return nil };phase = .saving;return token }
    mutating func saved(_ id: UUID) -> Bool { guard token==id, phase == .saving else { return false };phase = .review;return true }
    mutating func discard() -> Bool { guard phase == .review else { return false };phase = .idle;token=nil;return true }
}
