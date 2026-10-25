import ImageIO
import Foundation

enum SphereMetadata {
    static func add(to jpeg:Data,width:Int,height:Int,sources:Int) throws -> Data {
        let metadata=CGImageMetadataCreateMutable()
        guard width>0,height>0,width==height*2,(2...62).contains(sources),let source=CGImageSourceCreateWithData(jpeg as CFData,nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let info=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              info[kCGImagePropertyPixelWidth] as? Int==width,info[kCGImagePropertyPixelHeight] as? Int==height else { throw CameraFailure.message("Dimensiones esféricas no válidas.") }
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata,"http://ns.google.com/photos/1.0/panorama/" as CFString,"GPano" as CFString,nil) else {
            throw CameraFailure.message("No se pudo registrar el formato de panorama.")
        }
        let fields:[String:Any]=["UsePanoramaViewer":true,"ProjectionType":"equirectangular",
            "CaptureSoftware":"Ultimate CAM","StitchingSoftware":"Ultimate CAM",
            "CroppedAreaImageWidthPixels":width,"CroppedAreaImageHeightPixels":height,
            "FullPanoWidthPixels":width,"FullPanoHeightPixels":height,
            "CroppedAreaLeftPixels":0,"CroppedAreaTopPixels":0,"SourcePhotosCount":sources]
        for (key,value) in fields {
            guard CGImageMetadataSetValueWithPath(metadata,nil,("GPano:"+key) as CFString,value as CFTypeRef) else { throw CameraFailure.message("No se pudo escribir el campo esférico \(key).") }
        }
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(bytes,"public.jpeg" as CFString,1,nil) else { throw CameraFailure.message("No se pudo crear el archivo esférico.") }
        guard CGImageDestinationCopyImageSource(destination,source,[kCGImageDestinationMetadata:metadata] as CFDictionary,nil) else {
            throw CameraFailure.message("No se pudo terminar el JPEG esférico.")
        }
        return bytes as Data
    }
}
