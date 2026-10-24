import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Photos owns the received URL only during the transfer callback. Stage a
/// bounded copy before returning, then the caller removes it after processing.
struct PhotoImportTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 48 * 1024 * 1024 else {
                throw CameraFailure.message("Selecciona una imagen de hasta 48 MB.")
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("UltimateCAM-import-" + UUID().uuidString)
            try FileManager.default.copyItem(at: received.file, to: target)
            return Self(url: target)
        }
    }
}
