import CoreImage
import ImageIO

/// Dual rendering via Apple's public Adaptive HDR encoder. No Google codec or
/// calibration data is used. The SDR edit remains the backward-compatible base.
enum AdaptiveHDR {
    static func hasGainMap(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil ||
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    static func expanded(_ data: Data) -> CIImage? {
        guard hasGainMap(data) else { return nil }
        return CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: true])
    }

    /// Carry source luminance headroom through SDR artistic edits. Applying a
    /// clipping color LUT to HDR directly would destroy this information. Both
    /// renditions use the same geometry; gain is bounded to eight times SDR white.
    static func companion(base: CIImage, originalSDR: CIImage, originalHDR: CIImage,
                          extent: CGRect) throws -> CIImage {
        guard originalSDR.extent.contains(extent), originalHDR.extent.contains(extent),
              let image = gainKernel?.apply(extent: extent,
                  arguments: [base, originalSDR, originalHDR]) else {
            throw CameraFailure.message("Las representaciones SDR y HDR no coinciden.")
        }
        return image
    }

    static func encode(base: CIImage, originalSDR: CIImage, originalHDR: CIImage,
                       extent: CGRect, colorSpace: CGColorSpace, quality: Double,
                       context: CIContext) throws -> Data {
        let hdr = try companion(base: base, originalSDR: originalSDR,
                                originalHDR: originalHDR, extent: extent)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = context.jpegRepresentation(of: base.cropped(to: extent),
            colorSpace: colorSpace, options: [.hdrImage: hdr, .hdrGainMapAsRGB: false,
                                              qualityKey: quality]), hasGainMap(data) else {
            throw CameraFailure.message("El codificador no generó el mapa HDR. Se conserva la referencia; no se etiqueta SDR como HDR.")
        }
        return data
    }

    private static let gainKernel = CIColorKernel(source: """
        kernel vec4 carryHeadroom(__sample edited, __sample sdr, __sample hdr) {
            vec3 w = vec3(0.2126,0.7152,0.0722);
            float sy = dot(max(sdr.rgb,vec3(0.0)),w);
            float hy = dot(max(hdr.rgb,vec3(0.0)),w);
            float gain = sy > 0.0001 ? clamp(hy/sy,1.0,8.0) : 1.0;
            return vec4(max(edited.rgb,vec3(0.0))*gain,edited.a);
        }
        """)
}
