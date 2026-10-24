import Foundation
import ImageIO

/// Review images are bounded; JPEG/DNG bytes kept for saving remain untouched.
enum PreviewDecoder {
    static func image(_ data: Data, maximumDimension: Int = 1600) -> CGImage? {
        guard (1...4096).contains(maximumDimension),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
