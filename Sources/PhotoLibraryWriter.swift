import AVFoundation
import Foundation
import ImageIO
import Photos

/// One explicit save = one PhotoKit transaction. Never retries a failed or
/// unacknowledged transaction, and never requests read access to the library.
enum PhotoLibraryWriter {
    static func save(_ result: CaptureResult, jpegOnly: Bool, includeReference: Bool,
                     completion: @escaping (Result<[String], Error>) -> Void) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltimateCAM-Photos", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stem = "UltimateCAM-" + UUID().uuidString
        var rawURL: URL?
        do {
            if let raw = result.raw, !jpegOnly {
                guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
                      let type = CGImageSourceGetType(source),
                      (type as String) == AVFileType.dng.rawValue else {
                    throw CameraFailure.message("El RAW recibido no se reconoce como DNG. Puedes guardar el JPEG sin perder la captura.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(stem + ".dng")
                try raw.write(to: url, options: .atomic)
                rawURL = url
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(error))
            return
        }
        let stagedRAW = rawURL
        var identifiers = [String]()
        PHPhotoLibrary.shared().performChanges({
            func addJPEG(_ data: Data, name: String) {
                let asset = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                options.uniformTypeIdentifier = AVFileType.jpg.rawValue
                asset.addResource(with: .photo, data: data, options: options)
                if let id = asset.placeholderForCreatedAsset?.localIdentifier { identifiers.append(id) }
            }
            if let stagedRAW {
                // Import the camera JPEG as primary and the staged DNG as its
                // alternate resource. DNG-primary/JPEG-alternate is rejected
                // with PHPhotosErrorDomain 3300 on the tested iOS 18 device.
                // An adjusted JPEG is a separate asset, not a replacement for
                // the camera companion whose dimensions/metadata match the DNG.
                let asset = PHAssetCreationRequest.forAsset()
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = stem + ".dng"
                rawOptions.uniformTypeIdentifier = AVFileType.dng.rawValue
                asset.addResource(with: .alternatePhoto, fileURL: stagedRAW, options: rawOptions)
                let jpegOptions = PHAssetResourceCreationOptions()
                jpegOptions.originalFilename = stem + ".jpg"
                jpegOptions.uniformTypeIdentifier = AVFileType.jpg.rawValue
                asset.addResource(with: .photo, data: result.reference, options: jpegOptions)
                if let id = asset.placeholderForCreatedAsset?.localIdentifier { identifiers.append(id) }
                if result.jpeg != result.reference { addJPEG(result.jpeg, name: stem + "-edit.jpg") }
            } else {
                addJPEG(result.jpeg, name: stem + ".jpg")
                if includeReference && result.jpeg != result.reference {
                    addJPEG(result.reference, name: stem + "-reference.jpg")
                }
            }
        }) { success, error in
            // Keep the source DNG until PhotoKit has finished reading it.
            if stagedRAW != nil { try? FileManager.default.removeItem(at: directory) }
            if success { completion(.success(identifiers)) }
            else { completion(.failure(error ?? CameraFailure.message("Fotos no pudo completar el guardado. La captura sigue disponible."))) }
        }
    }
}
