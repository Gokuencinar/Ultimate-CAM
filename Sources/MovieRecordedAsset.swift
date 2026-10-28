import AVFoundation
import Foundation

struct MovieRecordedAsset {
    let duration: Double
    let width: Int
    let height: Int
    let bytes: Int64
    var hdr10Bit=false
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
        var hdr=false
        for description in try await track.load(.formatDescriptions) {
            guard let extensions=CMFormatDescriptionGetExtensions(description) as? [String:Any] else { continue }
            let atomKey=kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
            let transferKey=kCMFormatDescriptionExtension_TransferFunction as String
            let atoms:[String:Any]?=extensions[atomKey] as? [String:Any]
            let configuration:Data?=atoms?["hvcC"] as? Data
            let transfer:String=extensions[transferKey] as? String ?? ""
            if let configuration,configuration.count>=23 {
                let bitDepth=8+Int(configuration[17]&7),profile=configuration[1]&31
                hdr = hdr || (profile==2 && bitDepth>=10 && (transfer.contains("HLG") || transfer.contains("2084")))
            }
        }
        return Self(duration:duration,width:Int(dimensions.width),height:Int(dimensions.height),bytes:Int64(size),hdr10Bit:hdr)
    }
}
