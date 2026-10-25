import AVFoundation
import Foundation

struct MovieRecordedAsset {
    let duration: Double
    let width: Int
    let height: Int
    let bytes: Int64
    static func inspect(_ url: URL) async throws -> Self {
        let info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>0 else {
            throw CameraFailure.message("El archivo de vídeo está vacío o no es un archivo regular.")
        }
        let asset=AVURLAsset(url:url)
        let duration=try await asset.load(.duration).seconds
        let tracks=try await asset.loadTracks(withMediaType:.video)
        guard try await asset.load(.isPlayable),duration.isFinite,duration>0,duration<=605,let track=tracks.first else {
            throw CameraFailure.message("No se pudo validar el vídeo. El archivo se conserva para recuperación.")
        }
        let (natural,transform)=try await track.load(.naturalSize,.preferredTransform)
        let dimensions=CGRect(origin:.zero,size:natural).applying(transform).size
        guard natural.width.isFinite,natural.height.isFinite,dimensions.width.isFinite,dimensions.height.isFinite,
              natural.width>0,natural.height>0,max(natural.width,natural.height)<=8192,
              dimensions.width>0,dimensions.height>0,max(dimensions.width,dimensions.height)<=8192 else {
            throw CameraFailure.message("Dimensiones de vídeo no válidas.")
        }
        return Self(duration:duration,width:Int(dimensions.width),height:Int(dimensions.height),bytes:Int64(size))
    }
}
