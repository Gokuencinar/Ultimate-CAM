import Foundation
import CoreImage

/// Bounded IRIDAS 3D .cube reader. Red varies fastest, then green, then blue.
/// No shaders, native libraries or LUT assets from the Android package are bundled.
struct CubeLUT: Codable, Equatable {
    let title: String
    let dimension: Int
    let rgba: Data
    let domainMin: [Float]
    let domainMax: [Float]

    func validated() throws -> CubeLUT {
        guard (2...64).contains(dimension), rgba.count == dimension * dimension * dimension * 16,
              domainMin.count == 3, domainMax.count == 3, title.count <= 120 else {
            throw CameraFailure.message("La tabla LUT no es válida.")
        }
        for i in 0..<3 {
            guard domainMin[i].isFinite, domainMax[i].isFinite,
                  (domainMax[i] - domainMin[i]).isFinite, domainMax[i] - domainMin[i] > 0.00001 else { throw CameraFailure.message("Dominio LUT no válido.") }
        }
        // Do not bind potentially unaligned Data to Float.
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let bits = rgba.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index, as: UInt32.self) }
            let value = Float(bitPattern: UInt32(littleEndian: bits))
            guard value.isFinite, (-16...16).contains(value), (index / 4) % 4 != 3 || value == 1 else { throw CameraFailure.message("LUT con valores no finitos o excesivos.") }
        }
        return self
    }

    static func parse(_ data: Data, name: String = "LUT importada") throws -> CubeLUT {
        guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw CameraFailure.message("La LUT debe ser texto UTF-8 y ocupar menos de 16 MB.")
        }
        var title = String(name.prefix(120)), size: Int?
        var lower: [Float] = [0,0,0], upper: [Float] = [1,1,1], values = [Float]()
        var started = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch parts[0] {
            case "TITLE":
                guard !started else { throw CameraFailure.message("Cabecera LUT después de los datos.") }
                title = String(line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"\t")).prefix(120))
            case "LUT_3D_SIZE":
                guard !started, size == nil, parts.count == 2, let n = Int(parts[1]), (2...64).contains(n) else {
                    throw CameraFailure.message("La LUT 3D debe tener entre 2 y 64 puntos por canal.")
                }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard !started, parts.count == 4 else { throw CameraFailure.message("Dominio LUT no válido.") }
                let v = parts.dropFirst().compactMap(Float.init)
                guard v.count == 3, v.allSatisfy(\.isFinite) else { throw CameraFailure.message("Dominio LUT no finito.") }
                if parts[0] == "DOMAIN_MIN" { lower = v } else { upper = v }
            default:
                guard let n = size, parts.count == 3, values.count < n*n*n*4 else {
                    throw CameraFailure.message("Se admite .cube 3D sin tablas 1D ni instrucciones adicionales.")
                }
                let rgb = parts.compactMap(Float.init)
                guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (-16...16).contains($0) }) else {
                    throw CameraFailure.message("Datos LUT no válidos.")
                }
                started = true; values.append(contentsOf: rgb); values.append(1)
            }
        }
        guard let size, values.count == size*size*size*4 else { throw CameraFailure.message("La LUT está incompleta.") }
        let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return try CubeLUT(title: title, dimension: size, rgba: bytes, domainMin: lower, domainMax: upper).validated()
    }

    func resampledData() -> Data {
        if domainMin == [0,0,0] && domainMax == [1,1,1] { return rgba }
        let n = dimension
        let values: [Float] = stride(from: 0, to: rgba.count, by: 4).map { index in
            Float(bitPattern: rgba.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)) })
        }
        var output = [Float](); output.reserveCapacity(values.count)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let channels = [r,g,b]
            var coord = [Float]()
            for channel in 0..<3 {
                let input = Float(channels[channel]) / Float(n - 1)
                let position = (input - domainMin[channel]) / (domainMax[channel] - domainMin[channel])
                coord.append(min(Float(n - 1), max(0, position * Float(n - 1))))
            }
            let low = coord.map { Int(floor($0)) }, high = coord.map { min(n-1, Int(ceil($0))) }
            let t = (0..<3).map { coord[$0] - Float(low[$0]) }
            for c in 0..<3 {
                var value: Float = 0
                for z in 0...1 { for y in 0...1 { for x in 0...1 {
                    let ix = x == 0 ? low[0] : high[0], iy = y == 0 ? low[1] : high[1], iz = z == 0 ? low[2] : high[2]
                    let weightX = x == 0 ? 1 - t[0] : t[0]
                    let weightY = y == 0 ? 1 - t[1] : t[1]
                    let weightZ = z == 0 ? 1 - t[2] : t[2]
                    value += values[((iz * n + iy) * n + ix) * 4 + c] * weightX * weightY * weightZ
                } } }
                output.append(value)
            }
            output.append(1)
        } } }
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func apply(to image: CIImage, intensity: Double) throws -> CIImage {
        _ = try validated()
        guard intensity.isFinite, (0...1).contains(intensity) else { throw CameraFailure.message("Intensidad LUT no válida.") }
        // Resample DOMAIN in the cube's RGB coordinates, never in CI's linear
        // working image. Standard 0..1 cubes avoid this additional allocation.
        let table = resampledData()
        let graded = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension, "inputCubeData": table,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: graded, kCIInputTimeKey: intensity])
    }
}
