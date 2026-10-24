import Foundation
import Combine

struct ProcessingProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var options: ProcessingOptions
}

struct ProfileDocumentData: Codable {
    var format = "UltimateCAM.Profile"
    var version = 1
    var name: String
    var options: ProcessingOptions
    var lut: CubeLUT?

    static func decode(_ data: Data) throws -> ProfileDocumentData {
        guard data.count <= 16 * 1024 * 1024 else { throw CameraFailure.message("El perfil supera 16 MB.") }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.format == "UltimateCAM.Profile", document.version == 1,
              !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.name.count <= 60 else { throw CameraFailure.message("Formato de perfil no compatible.") }
        _ = try document.options.validated()
        if let lut = document.lut { _ = try lut.validated() }
        guard document.options.lutID == nil || document.lut != nil else {
            throw CameraFailure.message("El perfil hace referencia a una LUT que no contiene.")
        }
        return document
    }
}

/// Only app-owned documents. UUID identifiers never become arbitrary paths.
enum ColorLUTStore {
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorLUTs", isDirectory: true) }

    static func save(_ lut: CubeLUT) throws -> String {
        _ = try lut.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try JSONEncoder().encode(lut).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
        return id
    }

    static func load(_ id: String) throws -> CubeLUT {
        guard UUID(uuidString: id) != nil else { throw CameraFailure.message("Identificador LUT no válido.") }
        let url = directory.appendingPathComponent(id + ".json")
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw CameraFailure.message("La LUT guardada supera el límite.") }
        return try JSONDecoder().decode(CubeLUT.self, from: Data(contentsOf: url)).validated()
    }
}

final class ProcessingProfiles: ObservableObject {
    private struct Archive: Codable {
        var version = 1
        var profiles: [ProcessingProfile] = []
        var lenses: [String: ProcessingOptions] = [:]
    }
    @Published private(set) var profiles: [ProcessingProfile] = []
    @Published var error: String?
    private var archive = Archive()
    private let file: URL
    private let io = DispatchQueue(label: "com.gokuencinar.ultimatecam.profiles")
    private var pending: DispatchWorkItem?
    private var loadFailed = false

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("processing-profiles-v1.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let size = try self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 512 * 1024 else { throw CameraFailure.message("Archivo de perfiles demasiado grande.") }
                let value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.file))
                guard value.version == 1, value.profiles.count <= 24, value.lenses.count <= 4,
                      Set(value.lenses.keys).isSubset(of: ["wide", "ultraWide", "telephoto", "front"]),
                      Set(value.profiles.map(\.id)).count == value.profiles.count,
                      value.profiles.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 60 }) else {
                    throw CameraFailure.message("Archivo de perfiles no compatible.")
                }
                archive = value; profiles = value.profiles
            } catch { loadFailed = true; self.error = "No se cargaron los perfiles: \(error.localizedDescription)" }
        }
    }

    func options(for lens: String) -> ProcessingOptions? { archive.lenses[lens] }

    func remember(_ options: ProcessingOptions, lens: String) {
        guard ["wide", "ultraWide", "telephoto", "front"].contains(lens) else { return }
        do { archive.lenses[lens] = try options.validated(); persist() }
        catch { self.error = error.localizedDescription }
    }

    func save(name: String, options: ProcessingOptions) throws {
        guard !loadFailed else { throw CameraFailure.message("El archivo de perfiles no pudo leerse; se conserva sin sobrescribir.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, archive.profiles.count < 24 else {
            throw CameraFailure.message("Escribe un nombre de hasta 60 caracteres; máximo 24 perfiles.")
        }
        archive.profiles.append(ProcessingProfile(name: name, options: try options.validated()))
        profiles = archive.profiles; persist()
    }

    func remove(_ id: UUID) { archive.profiles.removeAll { $0.id == id }; profiles = archive.profiles; persist() }

    func importDocument(_ data: Data) throws -> ProcessingOptions {
        guard archive.profiles.count < 24 else { throw CameraFailure.message("Máximo 24 perfiles.") }
        let document = try ProfileDocumentData.decode(data)
        var options = document.options
        if let lut = document.lut { options.lutID = try ColorLUTStore.save(lut) }
        try save(name: document.name, options: options)
        return options
    }

    func exportDocument(name: String, options: ProcessingOptions) throws -> Data {
        _ = try options.validated()
        let lut = try options.lutID.map { try ColorLUTStore.load($0) }
        let value = ProfileDocumentData(name: String(name.prefix(60)), options: options, lut: lut)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func persist() {
        // Preserve an unreadable archive instead of overwriting user data.
        guard !loadFailed else { return }
        pending?.cancel()
        let snapshot = archive, file = file
        let item = DispatchWorkItem { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch { DispatchQueue.main.async { self?.error = "No se pudieron guardar los perfiles: \(error.localizedDescription)" } }
        }
        pending = item; io.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}
