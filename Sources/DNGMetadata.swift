import Foundation

/// Bounded classic-TIFF metadata reader. ImageIO does not expose every DNG
/// calibration/opcode tag. No strip/tile image data or private maker notes read.
struct DNGMetadata {
    struct Field {
        let type:UInt16,data:Data,little:Bool
        var numbers:[Double] {
            let stride:Int
            switch type { case 1:stride=1;case 3:stride=2;case 4:stride=4;case 5,10,12:stride=8;default:return [] }
            return data.withUnsafeBytes { bytes in
                func u32(_ offset:Int)->UInt32 {
                    let value=bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self)
                    return little ? UInt32(littleEndian:value):UInt32(bigEndian:value)
                }
                return Swift.stride(from:0,to:data.count,by:stride).map { offset in
                    switch type {
                    case 1:return Double(bytes[offset])
                    case 3:
                        let value=bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self)
                        return Double(little ? UInt16(littleEndian:value):UInt16(bigEndian:value))
                    case 4:return Double(u32(offset))
                    case 5:
                        let denominator=u32(offset+4)
                        return denominator>0 ? Double(u32(offset))/Double(denominator):.nan
                    case 10:
                        let numerator=Int32(bitPattern:u32(offset)),denominator=Int32(bitPattern:u32(offset+4))
                        return denominator != 0 ? Double(numerator)/Double(denominator):.nan
                    case 12:
                        let bits=bytes.loadUnaligned(fromByteOffset:offset,as:UInt64.self)
                        return Double(bitPattern:little ? UInt64(littleEndian:bits):UInt64(bigEndian:bits))
                    default:return .nan
                    }
                }
            }
        }
    }
    let fields:[UInt16:Field]
    subscript(_ tag:UInt16)->[Double] { fields[tag]?.numbers ?? [] }
    static let namedTags:[String:UInt16]=[
        "ColorMatrix1":50721,"ColorMatrix2":50722,"CameraCalibration1":50723,"CameraCalibration2":50724,
        "AnalogBalance":50727,"AsShotNeutral":50728,"CalibrationIlluminant1":50778,"CalibrationIlluminant2":50779,
        "BlackLevelRepeatDim":50713,"BlackLevel":50714,"WhiteLevel":50717,"BlackLevelDeltaH":50715,"BlackLevelDeltaV":50716,
        "LinearizationTable":50712,"ActiveArea":50829,"DefaultCropOrigin":50719,"DefaultCropSize":50720,
        "ForwardMatrix1":50964,"ForwardMatrix2":50965,"BaselineExposure":50730,"NoiseProfile":51041]
    static func read(_ bytes:Data) throws -> DNGMetadata {
        guard bytes.count>=8 else { throw CameraFailure.message("Cabecera DNG incompleta.") }
        let little=bytes[0]==0x49 && bytes[1]==0x49
        guard little || (bytes[0]==0x4d && bytes[1]==0x4d) else { throw CameraFailure.message("Orden TIFF inválido.") }
        func integer(_ offset:Int,_ size:Int) throws -> UInt32 {
            guard offset>=0,offset<=bytes.count-size else { throw CameraFailure.message("Etiqueta DNG fuera de límites.") }
            var value:UInt32=0
            for index in 0..<size { value |= UInt32(bytes[offset+index]) << (8*(little ? index:size-1-index)) }
            return value
        }
        guard try integer(2,2)==42 else { throw CameraFailure.message("Se requiere DNG TIFF clásico.") }
        let wanted=Set(namedTags.values).union([UInt16(51009)])
        var pending=[Int(try integer(4,4))],visited=Set<Int>(),global=[UInt16:Field](),raw=[UInt16:Field]()
        while let offset=pending.popLast(),offset>0 {
            guard visited.count<16,visited.insert(offset).inserted else { throw CameraFailure.message("Directorios DNG cíclicos o excesivos.") }
            let count=Int(try integer(offset,2))
            guard count<=1024,offset<=bytes.count-6-count*12 else { throw CameraFailure.message("Directorio DNG incompleto.") }
            var directory=[UInt16:Field](),isRAW=false
            for index in 0..<count {
                let entry=offset+2+index*12,tag=UInt16(try integer(entry,2)),type=UInt16(try integer(entry+2,2))
                guard wanted.contains(tag) || tag==330 || tag==262 else { continue }
                let units=Int(try integer(entry+4,4)),unit:Int
                switch type { case 1,7:unit=1;case 3:unit=2;case 4:unit=4;case 5,10,12:unit=8;default:continue }
                guard units>0,units<=1_048_576/unit else { throw CameraFailure.message("Metadatos DNG demasiado grandes.") }
                let length=units*unit,start=length<=4 ? entry+8:Int(try integer(entry+8,4))
                guard start>=0,start<=bytes.count-length else { throw CameraFailure.message("Datos DNG truncados.") }
                let field=Field(type:type,data:bytes.subdata(in:start..<start+length),little:little)
                if tag==330 {
                    guard type==4,units<=8 else { throw CameraFailure.message("SubIFD DNG inválido.") }
                    pending.append(contentsOf:field.numbers.map { Int($0) })
                } else if tag==262 { isRAW=field.numbers.first==32803 }
                else { directory[tag]=field }
            }
            let next=Int(try integer(offset+2+count*12,4));if next>0 { pending.append(next) }
            if isRAW { raw.merge(directory) { _,new in new } }
            else { global.merge(directory) { old,_ in old } }
        }
        global.merge(raw) { _,new in new };return DNGMetadata(fields:global)
    }
    /// Opcode lists are opaque big-endian payloads even in little-endian TIFF.
    /// Validate framing/version before forwarding, without rewriting gain maps.
    static func validatedOpcodes(_ data:Data) throws -> Data {
        func u32(_ offset:Int) throws -> UInt32 {
            guard offset>=0,offset<=data.count-4 else { throw CameraFailure.message("Corrección de lente DNG truncada.") }
            return (0..<4).reduce(UInt32(0)) { ($0<<8)|UInt32(data[offset+$1]) }
        }
        let count=Int(try u32(0));guard count<=64 else { throw CameraFailure.message("Demasiadas correcciones de lente DNG.") }
        var offset=4
        for _ in 0..<count {
            let version=try u32(offset+4),length=Int(try u32(offset+12))
            guard version<=0x01040000,length<=1_048_576,offset<=data.count-16-length else { throw CameraFailure.message("Corrección de lente DNG incompatible.") }
            offset+=16+length
        }
        guard offset==data.count else { throw CameraFailure.message("Lista de corrección DNG inválida.") }
        return data
    }
}
