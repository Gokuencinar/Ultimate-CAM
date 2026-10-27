import CoreImage
import ImageIO

/// Dual rendering via Apple's public Adaptive HDR encoder. No Google codec or
/// calibration data is used. The SDR edit remains the backward-compatible base.
enum AdaptiveHDR {
    static func rollOff(_ image:CIImage,gain:Double,headroom:Double=4) throws -> CIImage {
        guard gain.isFinite,(1...64).contains(gain),headroom.isFinite,(1.01...16).contains(headroom),
              let result=rollOffKernel?.apply(extent:image.extent,arguments:[image,gain,headroom]) else {
            throw CameraFailure.message("No se pudo preparar el rango HDR.")
        }
        return result
    }
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
                          extent: CGRect,maximumHeadroom:Double=8) throws -> CIImage {
        guard maximumHeadroom.isFinite,(1...16).contains(maximumHeadroom),originalSDR.extent.contains(extent), originalHDR.extent.contains(extent),
              let image = gainKernel?.apply(extent: extent,
                  arguments: [base, originalSDR, originalHDR,maximumHeadroom]) else {
            throw CameraFailure.message("Las representaciones SDR y HDR no coinciden.")
        }
        return image
    }

    static func encode(base: CIImage, originalSDR: CIImage, originalHDR: CIImage,
                       extent: CGRect, colorSpace: CGColorSpace, quality: Double,
                       context: CIContext,maximumHeadroom:Double=8) throws -> Data {
        let hdr = try companion(base: base, originalSDR: originalSDR,
                                originalHDR: originalHDR, extent: extent,maximumHeadroom:maximumHeadroom)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = context.jpegRepresentation(of: base.cropped(to: extent),
            colorSpace: colorSpace, options: [.hdrImage: hdr, qualityKey: quality]), hasGainMap(data) else {
            throw CameraFailure.message("El codificador no generó el mapa HDR. Se conserva la referencia; no se etiqueta SDR como HDR.")
        }
        return data
    }

    private static let gainKernel = CIColorKernel(source: """
        kernel vec4 carryHeadroom(__sample edited, __sample sdr, __sample hdr, float maximum) {
            vec3 w = vec3(0.2126,0.7152,0.0722);
            float sy = dot(max(sdr.rgb,vec3(0.0)),w);
            float hy = dot(max(hdr.rgb,vec3(0.0)),w);
            float gain = sy > 0.0001 ? clamp(hy/sy,1.0,8.0) : 1.0;
            vec3 rgb=max(edited.rgb,vec3(0.0))*gain;
            rgb*=min(1.0,maximum/max(max(rgb.r,max(rgb.g,rgb.b)),0.00001));
            return vec4(rgb,edited.a);
        }
        """)
    private static let rollOffKernel=CIColorKernel(source:"""
        kernel vec4 rollOff(__sample p, float gain, float headroom) {
            vec3 rgb=max(p.rgb,vec3(0.0))*gain;
            float peak=max(rgb.r,max(rgb.g,rgb.b));
            float over=max(peak-1.0,0.0),span=headroom-1.0;
            float mapped=peak<=1.0 ? peak : 1.0+span*over/(span+over);
            return vec4(rgb*(peak>0.000001 ? mapped/peak : 1.0),p.a);
        }
        """)
}
