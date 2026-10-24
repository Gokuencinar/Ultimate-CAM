import Foundation
import CoreGraphics
import ImageIO

enum PNGLUTLayout: String, CaseIterable, Identifiable {
    case agcTiles, standardHald
    var id: String { rawValue }
    var label: String { self == .agcTiles ? "Mosaico AGC" : "Hald estándar" }
}

/// PNG is numeric LUT data, not a photograph: do not apply EXIF orientation or
/// convert the embedded color profile. Square AGC tiles and standard Hald have
/// different indexing, so their layout must be selected explicitly.
enum PNGLUT {
    static let signature: [UInt8] = [137,80,78,71,13,10,26,10]

    static func parse(_ data: Data, layout: PNGLUTLayout, name: String) throws -> CubeLUT {
        guard data.count <= 16*1024*1024, data.starts(with: signature),
              let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=info[kCGImagePropertyPixelWidth] as? Int,
              let height=info[kCGImagePropertyPixelHeight] as? Int,
              width>0, height>0, width<=65536, height<=4096,
              Int64(width)*Int64(height)<=16_777_216,
              (info[kCGImagePropertyOrientation] as? Int ?? 1)==1 else {
            throw CameraFailure.message("La LUT PNG debe estar completa, sin giro, y ocupar hasta 16 MB y 16 MP.")
        }
        let level: Int, edge: Int, strip: Bool
        if width == height, let n=(2...16).first(where: { $0*$0*$0 == width }) {
            level=n;edge=n*n;strip=false
        } else if height>=2, height<=256, width==height*height {
            level=1;edge=height;strip=true
        } else {
            throw CameraFailure.message("Usa un mosaico/Hald cuadrado (por ejemplo 512×512) o una tira horizontal (4096×64).")
        }
        guard let image=CGImageSourceCreateImageAtIndex(source,0,nil), image.bitsPerComponent==8,
              image.colorSpace?.model == .rgb,
              let untagged=image.copy(colorSpace: CGColorSpace(name:CGColorSpace.sRGB)!) else {
            throw CameraFailure.message("Se admite LUT PNG RGB de 8 bits, sin paleta indexada.")
        }
        var pixels=[UInt8](repeating:0,count:width*height*4)
        let drawn=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(untagged,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard drawn, stride(from:3,to:pixels.count,by:4).allSatisfy({pixels[$0]==255}) else {
            throw CameraFailure.message("La LUT PNG no puede contener transparencia.")
        }
        func offset(_ r:Int,_ g:Int,_ b:Int) -> Int {
            let x:Int,y:Int
            if strip { x=b*edge+r;y=g }
            else if layout == .agcTiles { x=(b%level)*edge+r;y=(b/level)*edge+g }
            else { let index=(b*edge+g)*edge+r;x=index%width;y=index/width }
            return (y*width+x)*4
        }
        let target=min(64,edge)
        var output=[Float]();output.reserveCapacity(target*target*target*4)
        // Larger input cubes are resampled with trilinear interpolation, never
        // by resizing the PNG (which would mix unrelated blue slices).
        for b in 0..<target { for g in 0..<target { for r in 0..<target {
            let p=[r,g,b].map { Double($0)*Double(edge-1)/Double(target-1) }
            let lo=p.map { Int(floor($0)) },hi=p.map { min(edge-1,Int(ceil($0))) }
            let f=zip(p,lo).map { $0-Double($1) }
            for c in 0..<3 {
                var value=0.0
                for z in 0...1 { for y in 0...1 { for x in 0...1 {
                    let index=offset(x==0 ? lo[0]:hi[0],y==0 ? lo[1]:hi[1],z==0 ? lo[2]:hi[2])
                    value += Double(pixels[index+c])/255 * (x==0 ? 1-f[0]:f[0]) *
                        (y==0 ? 1-f[1]:f[1]) * (z==0 ? 1-f[2]:f[2])
                } } }
                output.append(Float(value))
            }
            output.append(1)
        } } }
        return try CubeLUT(title:String(name.prefix(120)),dimension:target,
            rgba:output.withUnsafeBufferPointer { Data(buffer:$0) },domainMin:[0,0,0],domainMax:[1,1,1]).validated()
    }
}
