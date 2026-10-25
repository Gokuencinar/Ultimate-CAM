import Foundation
import ImageIO

enum CaptureMetadata {
    /// Copy bounded camera/date tags, never stale dimensions, orientation,
    /// thumbnails, MakerNotes or the reference's HDR gain map. For stacks the
    /// exposure describes the reference, not a fictitious long exposure.
    static func attach(to jpeg:Data,reference:Data,frames:Int) throws -> Data {
        guard (1...62).contains(frames),let source=CGImageSourceCreateWithData(jpeg as CFData,nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let original=CGImageSourceCreateWithData(reference as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(original,0,nil) as? [CFString:Any] else {
            throw CameraFailure.message("No se pudieron leer los metadatos de la referencia.")
        }
        let metadata=CGImageMetadataCreateMutable()
        func set(_ dictionary:CFString,_ key:CFString,_ value:Any) throws {
            guard CGImageMetadataSetValueMatchingImageProperty(metadata,dictionary,key,value as CFTypeRef) else {
                throw CameraFailure.message("No se pudo conservar el metadato \(key).")
            }
        }
        func bounded(_ value:Any) -> Bool {
            if let text=value as? String { return text.utf8.count<=256 }
            if let number=value as? NSNumber { return number.doubleValue.isFinite }
            if let array=value as? [NSNumber] { return array.count<=4 && array.allSatisfy { $0.doubleValue.isFinite } }
            return false
        }
        let allowed:[(CFString,[CFString])]=[
            (kCGImagePropertyTIFFDictionary,[kCGImagePropertyTIFFMake,kCGImagePropertyTIFFModel,kCGImagePropertyTIFFDateTime]),
            (kCGImagePropertyExifDictionary,[kCGImagePropertyExifDateTimeOriginal,kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifExposureTime,kCGImagePropertyExifFNumber,kCGImagePropertyExifISOSpeedRatings,
                kCGImagePropertyExifFocalLength,kCGImagePropertyExifFocalLenIn35mmFilm,kCGImagePropertyExifLensMake,kCGImagePropertyExifLensModel])]
        for (dictionary,keys) in allowed {
            guard let values=properties[dictionary] as? [CFString:Any] else { continue }
            for key in keys { if let value=values[key],bounded(value) { try set(dictionary,key,value) } }
        }
        try set(kCGImagePropertyTIFFDictionary,kCGImagePropertyTIFFSoftware,"Ultimate CAM")
        try set(kCGImagePropertyTIFFDictionary,kCGImagePropertyTIFFOrientation,1)
        try set(kCGImagePropertyTIFFDictionary,kCGImagePropertyTIFFImageDescription,
                frames>1 ? "Ultimate CAM: \(frames) frames. Exposure tags describe the reference frame." : "Ultimate CAM: processed image.")
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(bytes,"public.jpeg" as CFString,1,nil),
              CGImageDestinationCopyImageSource(destination,source,[kCGImageDestinationMetadata:metadata,
                kCGImageDestinationMergeMetadata:true,kCGImageDestinationOrientation:1] as CFDictionary,nil) else {
            throw CameraFailure.message("No se pudo terminar el JPEG con sus metadatos.")
        }
        return bytes as Data
    }
}
