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
enum MovieStabilizationMode:String,Codable,CaseIterable,Identifiable {
    case off,standard,cinematic,locked
    var id:String { rawValue }
    var label:String { switch self {case .off:return "Desactivada";case .standard:return "Estándar";case .cinematic:return "Cinemática";case .locked:return "Extendida"} }
    var fallbackOrder:[Self] { switch self {case .off:return [.off];case .standard:return [.standard,.off];case .cinematic:return [.cinematic,.standard,.off];case .locked:return [.locked,.cinematic,.standard,.off]} }
    func resolved(supported:Set<Self>)->Self { fallbackOrder.first(where:{supported.contains($0)}) ?? .off }
}
struct MovieConfiguration:Codable,Equatable {
    var resolution=MovieResolution.fullHD
    var fps=30
    var codec=MovieCodec.hevc
    var audio=true
    var stabilization=MovieStabilizationMode.standard
    var hdrVideo=false
    var lockWhiteBalance=true
    var exposureBias:Double=0
    var stabilized:Bool {
        get { stabilization != .off }
        set { stabilization=newValue ? .standard:.off }
    }
    func validated() throws -> Self {
        guard [24,30,60].contains(fps) else { throw CameraFailure.message("Elige 24, 30 o 60 FPS.") }
        guard exposureBias.isFinite,(-2...2).contains(exposureBias) else { throw CameraFailure.message("Compensación de vídeo fuera de rango.") }
        guard !hdrVideo || codec == .hevc else { throw CameraFailure.message("HDR de 10 bits necesita formato HEVC.") };return self
    }
    func matches(width:Int,height:Int,ranges:[ClosedRange<Double>],hdr10Bit:Bool=false)->Bool {
        width==resolution.width && height==resolution.height && ranges.contains{$0.contains(Double(fps))} && (!hdrVideo || hdr10Bit)
    }
    enum CodingKeys:String,CodingKey { case resolution,fps,codec,audio,stabilized,stabilization,hdrVideo,lockWhiteBalance,exposureBias }
    init() {}
    init(from decoder:Decoder) throws {
        self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
        resolution=try c.decodeIfPresent(MovieResolution.self,forKey:.resolution) ?? resolution
        fps=try c.decodeIfPresent(Int.self,forKey:.fps) ?? fps
        codec=try c.decodeIfPresent(MovieCodec.self,forKey:.codec) ?? codec
        audio=try c.decodeIfPresent(Bool.self,forKey:.audio) ?? audio
        let legacy=try c.decodeIfPresent(Bool.self,forKey:.stabilized) ?? true
        stabilization=try c.decodeIfPresent(MovieStabilizationMode.self,forKey:.stabilization) ?? (legacy ? .standard:.off)
        hdrVideo=try c.decodeIfPresent(Bool.self,forKey:.hdrVideo) ?? hdrVideo
        lockWhiteBalance=try c.decodeIfPresent(Bool.self,forKey:.lockWhiteBalance) ?? lockWhiteBalance
        exposureBias=try c.decodeIfPresent(Double.self,forKey:.exposureBias) ?? exposureBias
        _=try validated()
    }
    func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(resolution,forKey:.resolution);try c.encode(fps,forKey:.fps);try c.encode(codec,forKey:.codec);try c.encode(audio,forKey:.audio)
        try c.encode(stabilization,forKey:.stabilization);try c.encode(stabilized,forKey:.stabilized)
        try c.encode(hdrVideo,forKey:.hdrVideo);try c.encode(lockWhiteBalance,forKey:.lockWhiteBalance);try c.encode(exposureBias,forKey:.exposureBias)
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
