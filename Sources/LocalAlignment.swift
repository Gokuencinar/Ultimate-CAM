import CoreImage
import Vision

/// Optional 3x3 residual translation mesh after global registration. This is a
/// conservative RGB approximation, not AGC's Bayer pyramid/optical flow.
enum LocalAlignment {
    static func align(_ image: CIImage, reference: CIImage, extent: CGRect, context: CIContext) throws -> CIImage {
        guard extent.width >= 192, extent.height >= 192 else { return image }
        var offsets = [CIVector]()
        for row in 0..<3 {
            for column in 0..<3 {
                let side = min(384, min(extent.width, extent.height) / 3)
                let patch = CGRect(x: extent.minX + extent.width * (CGFloat(column) + 0.5) / 3 - side / 2,
                    y: extent.minY + extent.height * (CGFloat(row) + 0.5) / 3 - side / 2, width: side, height: side).integral.intersection(extent)
                var vector = CIVector(x: 0, y: 0)
                if let target = context.createCGImage(image, from: patch, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                   let anchor = context.createCGImage(reference, from: patch, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
                    if (try? VNImageRequestHandler(cgImage: anchor).perform([request])) != nil,
                       let observation = request.results?.first, observation.confidence >= 0.8 {
                        let t = observation.alignmentTransform
                        if t.tx.isFinite, t.ty.isFinite, abs(t.tx) <= 6, abs(t.ty) <= 6 { vector = CIVector(x: t.tx, y: t.ty) }
                    }
                }
                offsets.append(vector)
            }
        }
        return try warp(image, extent: extent, offsets: offsets)
    }

    static func warp(_ image: CIImage, extent: CGRect, offsets: [CIVector]) throws -> CIImage {
        guard offsets.count == 9, offsets.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 6 && abs($0.y) <= 6 }),
              let result = kernel?.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -8, dy: -8) },
                  image: image.clampedToExtent(), arguments: [CIVector(cgRect: extent)] + offsets) else {
            throw CameraFailure.message("No se pudo aplicar la alineación local.")
        }
        return result.cropped(to: extent)
    }

    private static let kernel = CIWarpKernel(source: """
        kernel vec2 mesh(vec4 rect, vec2 a, vec2 b, vec2 c, vec2 d, vec2 e, vec2 f, vec2 g, vec2 h, vec2 i) {
            vec2 q = destCoord();
            vec2 uv = clamp((q - rect.xy) / rect.zw * 3.0 - 0.5, vec2(0.0), vec2(2.0));
            vec2 top = uv.x < 1.0 ? mix(a,b,uv.x) : mix(b,c,uv.x-1.0);
            vec2 mid = uv.x < 1.0 ? mix(d,e,uv.x) : mix(e,f,uv.x-1.0);
            vec2 bot = uv.x < 1.0 ? mix(g,h,uv.x) : mix(h,i,uv.x-1.0);
            vec2 t = uv.y < 1.0 ? mix(top,mid,uv.y) : mix(mid,bot,uv.y-1.0);
            return q - t;
        }
        """)
}
