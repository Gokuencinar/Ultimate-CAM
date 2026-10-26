import AVFoundation
import ImageIO

struct BayerCalibration:Equatable {
    let pattern:[UInt8]
    let matrix:[Double]
    let neutral:[Double]
    let illuminant:UInt16
    let orientation:UInt32
    var extraColor:[UInt16:[Double]] = [:]
    var illuminant2:UInt16 = 0
}

/// A compact quad texture: RGGB/GRBG/BGGR/GBRG phases remain four separate
/// channels through alignment and fusion. No interpolation across CFA colors.
struct SensorBayerFrame {
    let width:Int,height:Int // Quad dimensions; output Bayer dimensions are 2x.
    let quads:Data // RGBA16Float, scene-linear sensor values before WB/demosaic.
    let calibration:BayerCalibration
    let exposure:FrameExposure
    let timestamp:Double

    #if os(iOS)
    static func capture(_ photo:AVCapturePhoto,dng:Data) throws -> SensorBayerFrame {
        guard photo.isRawPhoto,let pixel=photo.pixelBuffer,
              let source=CGImageSourceCreateWithData(dng as CFData,nil),
              let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let tags=props[kCGImagePropertyDNGDictionary as String] as? [String:Any] else {
            throw CameraFailure.message("El RAW no contiene plano Bayer y calibración DNG accesibles.")
        }
        func numbers(_ key:String) -> [Double] {
            if let n=tags[key] as? NSNumber { return [n.doubleValue] }
            return (tags[key] as? [NSNumber])?.map(\.doubleValue) ?? []
        }
        let pattern:[UInt8]
        switch CVPixelBufferGetPixelFormatType(pixel) {
        case kCVPixelFormatType_14Bayer_RGGB:pattern=[0,1,1,2]
        case kCVPixelFormatType_14Bayer_GRBG:pattern=[1,0,2,1]
        case kCVPixelFormatType_14Bayer_BGGR:pattern=[2,1,1,0]
        case kCVPixelFormatType_14Bayer_GBRG:pattern=[1,2,0,1]
        default:throw CameraFailure.message("Metal RAW requiere Bayer de 14 bits en contenedor little-endian de 16 bits; este formato no se interpreta como Bayer.")
        }
        let matrix=numbers("ColorMatrix1"),neutral=numbers("AsShotNeutral"),black=numbers("BlackLevel"),white=numbers("WhiteLevel")
        let illumination=numbers("CalibrationIlluminant1").first ?? 0
        guard matrix.count==9,matrix.allSatisfy({$0.isFinite && abs($0)<32}),
              neutral.count==3,neutral.allSatisfy({$0.isFinite && $0>0 && $0<32}),
              [1,4].contains(black.count),black.allSatisfy({$0.isFinite && $0>=0}),
              white.count==1,let white=white.first,white.isFinite,white<=16383,
              black.allSatisfy({white>$0+64}),illumination>=1,illumination<=255,illumination.rounded()==illumination else {
            throw CameraFailure.message("Calibración RAW incompleta; no se inventan niveles de negro, blanco o matrices de color.")
        }
        let repeatDim=numbers("BlackLevelRepeatDim")
        guard (black.count==1 && (repeatDim.isEmpty || repeatDim==[1,1])) || (black.count==4 && repeatDim==[2,2]),
              numbers("LinearizationTable").isEmpty,
              (numbers("BlackLevelDeltaH")+numbers("BlackLevelDeltaV")).allSatisfy({$0==0}) else {
            throw CameraFailure.message("El RAW requiere linealización o corrección de negro adicional.")
        }
        let w=CVPixelBufferGetWidth(pixel),h=CVPixelBufferGetHeight(pixel)
        guard w>=4,h>=4,w<=10000,h<=10000,CVPixelBufferGetPlaneCount(pixel)==0 else { throw CameraFailure.message("Geometría Bayer no admitida.") }
        // ActiveArea and DefaultCrop use sensor coordinates, before EXIF
        // orientation. Keep phase/black-level indexing anchored to that origin.
        let active=numbers("ActiveArea"),origin=numbers("DefaultCropOrigin"),crop=numbers("DefaultCropSize")
        guard (active.isEmpty || active.count==4),(origin.isEmpty || origin.count==2),(crop.isEmpty || crop.count==2),
              (active+origin+crop).allSatisfy({$0.isFinite && $0>=0 && $0.rounded()==$0 && $0<=10000}) else { throw CameraFailure.message("Recorte DNG inválido.") }
        if active.isEmpty && origin.isEmpty && crop.isEmpty {
            let declaredWidth=(props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
            let declaredHeight=(props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
            guard declaredWidth==w,declaredHeight==h else { throw CameraFailure.message("Falta la relación de recorte entre el plano RAW y el DNG.") }
        }
        let top=active.isEmpty ? 0:Int(active[0]),left=active.isEmpty ? 0:Int(active[1])
        let bottom=active.isEmpty ? h:Int(active[2]),right=active.isEmpty ? w:Int(active[3])
        let ox=origin.isEmpty ? 0:Int(origin[0]),oy=origin.isEmpty ? 0:Int(origin[1])
        let cw=crop.isEmpty ? right-left-ox:Int(crop[0]),ch=crop.isEmpty ? bottom-top-oy:Int(crop[1])
        guard top<bottom,left<right,bottom<=h,right<=w,cw>=4,ch>=4,ox+cw<=right-left,oy+ch<=bottom-top else { throw CameraFailure.message("El recorte DNG excede el plano del sensor.") }
        let offsetX=left+ox,offsetY=top+oy
        var phaseMap=[Int]()
        for phase in 0..<4 {
            let row=(offsetY+phase/2)%2,col=(offsetX+phase%2)%2
            phaseMap.append(row*2+col)
        }
        let croppedPattern=phaseMap.map { pattern[$0] }
        let step=max(1,Int(ceil(Double(max(cw,ch))/2048)))
        let qw=cw/(2*step),qh=ch/(2*step)
        let status=CVPixelBufferLockBaseAddress(pixel,.readOnly)
        guard status==kCVReturnSuccess else { throw CameraFailure.message("No se pudo leer el plano Bayer.") }
        defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(pixel),CVPixelBufferGetBytesPerRow(pixel)>=w*2 else { throw CameraFailure.message("Stride Bayer inválido.") }
        let rowBytes=CVPixelBufferGetBytesPerRow(pixel)
        var packed=[UInt16](repeating:0,count:qw*qh*4)
        for y in 0..<qh { for x in 0..<qw { for phase in 0..<4 {
            // Resample each CFA plane at the physical center of the output
            // mosaic pixel. Averaging same-phase 2x2 cells without this offset
            // would place R/G/B at inconsistent positions after decimation.
            let px=phase&1,py=phase>>1
            let sourceX=Double(x*step)+Double(px*(step-1))/2+Double(step-1)/4
            let sourceY=Double(y*step)+Double(py*(step-1))/2+Double(step-1)/4
            let ix=Int(floor(sourceX)),iy=Int(floor(sourceY))
            let fx=sourceX-Double(ix),fy=sourceY-Double(iy)
            let maxX=(cw-1-px)/2,maxY=(ch-1-py)/2
            var sum:Double=0
            for by in 0...1 { for bx in 0...1 {
                let sx=offsetX+min(maxX,max(0,ix+bx))*2+px
                let sy=offsetY+min(maxY,max(0,iy+by))*2+py
                let value=base.loadUnaligned(fromByteOffset:sy*rowBytes+sx*2,as:UInt16.self).littleEndian
                guard value<=16383 else { throw CameraFailure.message("El plano RAW no respeta el empaquetado de 14 bits esperado.") }
                let weightX=bx==0 ? 1-fx:fx,weightY=by==0 ? 1-fy:fy
                sum+=Double(value)*weightX*weightY
            } }
            let level=black[black.count==1 ? 0:phaseMap[phase]]
            packed[(y*qw+x)*4+phase]=Float16((sum-level)/(white-level)).bitPattern.littleEndian
        } } }
        let exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let exposure=FrameExposure(seconds:(exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0,
            iso:(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 0)
        guard exposure.isValid,photo.timestamp.seconds.isFinite else { throw CameraFailure.message("El RAW no incluye exposición y tiempo válidos.") }
        var extra=[UInt16:[Double]]()
        for (key,tag,count) in [("ColorMatrix2",UInt16(50722),9),("CameraCalibration1",UInt16(50723),9),("CameraCalibration2",UInt16(50724),9),("AnalogBalance",UInt16(50727),3)] {
            let values=numbers(key)
            guard values.isEmpty || (values.count==count && values.allSatisfy({$0.isFinite && abs($0)<32}) && (tag != 50727 || values.allSatisfy({$0>0}))) else { throw CameraFailure.message("Calibración de color RAW inválida.") }
            if !values.isEmpty { extra[tag]=values }
        }
        let secondIlluminant=numbers("CalibrationIlluminant2").first ?? 0
        guard extra[50722]==nil || (secondIlluminant>=1 && secondIlluminant<=255 && secondIlluminant.rounded()==secondIlluminant) else { throw CameraFailure.message("Falta el segundo iluminante del DNG.") }
        let orientation=(props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        guard (1...8).contains(orientation) else { throw CameraFailure.message("Orientación RAW inválida.") }
        var calibration=BayerCalibration(pattern:croppedPattern,matrix:matrix,neutral:neutral,illuminant:UInt16(illumination),orientation:orientation)
        calibration.extraColor=extra;calibration.illuminant2=extra[50722]==nil ? 0:UInt16(secondIlluminant)
        return SensorBayerFrame(width:qw,height:qh,quads:packed.withUnsafeBufferPointer { Data(buffer:$0) },
            calibration:calibration,exposure:exposure,timestamp:photo.timestamp.seconds)
    }
    #endif
}

/// Minimal uncompressed DNG for CIRAWFilter demosaicing/color conversion of the
/// fused mosaic. The saved user's RAW remains the original, never this working DNG.
enum FusedDNG {
    static func encode(quads:Data,width:Int,height:Int,calibration c:BayerCalibration) throws -> Data {
        guard width>0,height>0,width<=1024,height<=1024,quads.count==width*height*8,c.pattern.count==4,
              c.matrix.count==9,c.matrix.allSatisfy({$0.isFinite && abs($0)<32}),
              c.neutral.count==3,c.neutral.allSatisfy({$0.isFinite && $0>0 && $0<32}),
              c.pattern.sorted()==[0,1,1,2],(1...8).contains(c.orientation),(1...255).contains(c.illuminant) else { throw CameraFailure.message("Mosaico fusionado inválido.") }
        func u16(_ n:UInt16)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func u32(_ n:UInt32)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func rational(_ n:Double,signed:Bool=false)->Data {
            let numerator=Int32((n*1_000_000).rounded())
            return u32(UInt32(bitPattern:numerator))+u32(1_000_000)
        }
        struct Tag { let key:UInt16,type:UInt16,count:UInt32,data:Data }
        var tags=[Tag]()
        func add(_ key:UInt16,_ type:UInt16,_ count:UInt32,_ data:Data) { tags.append(Tag(key:key,type:type,count:count,data:data)) }
        let w=width*2,h=height*2
        add(256,4,1,u32(UInt32(w)));add(257,4,1,u32(UInt32(h)))
        add(258,3,1,u16(16));add(259,3,1,u16(1));add(262,3,1,u16(32803))
        add(273,4,1,u32(0));add(274,3,1,u16(UInt16(c.orientation)))
        add(277,3,1,u16(1));add(278,4,1,u32(UInt32(h)));add(279,4,1,u32(UInt32(w*h*2)))
        add(284,3,1,u16(1));add(33421,3,2,u16(2)+u16(2));add(33422,1,4,Data(c.pattern))
        add(50706,1,4,Data([1,4,0,0]));add(50707,1,4,Data([1,3,0,0]))
        let model=Data("UltimateCAM working mosaic\0".utf8);add(50708,2,UInt32(model.count),model)
        add(50710,1,3,Data([0,1,2]));add(50711,3,1,u16(1))
        add(50713,3,2,u16(1)+u16(1));add(50714,5,1,rational(4096));add(50717,4,1,u32(61439))
        add(50721,10,9,c.matrix.reduce(Data()) { $0+rational($1,signed:true) })
        add(50728,5,3,c.neutral.reduce(Data()) { $0+rational($1) });add(50778,3,1,u16(c.illuminant))
        for (tag,values) in c.extraColor {
            guard [50722,50723,50724,50727].contains(tag),values.count==(tag==50727 ? 3:9),values.allSatisfy({$0.isFinite && abs($0)<32}) else { throw CameraFailure.message("Etiquetas de color DNG fuera de rango.") }
            add(tag,tag==50727 ? 5:10,UInt32(values.count),values.reduce(Data()) { $0+rational($1) })
        }
        if c.illuminant2>0 { add(50779,3,1,u16(c.illuminant2)) }
        tags.sort { $0.key<$1.key }
        let base=8+2+tags.count*12+4
        var extra=Data(),entries=Data()
        let extraBytes=tags.reduce(0) { $0+($1.data.count>4 ? ($1.data.count+1)/2*2:0) }
        let stripOffset=base+extraBytes
        for tag in tags {
            entries+=u16(tag.key)+u16(tag.type)+u32(tag.count)
            if tag.key==273 { entries+=u32(UInt32(stripOffset)) }
            else if tag.data.count<=4 { entries+=tag.data+Data(repeating:0,count:4-tag.data.count) }
            else { entries+=u32(UInt32(base+extra.count));extra+=tag.data;if extra.count%2==1 { extra.append(0) } }
        }
        var mosaic=[UInt16](repeating:0,count:w*h)
        try quads.withUnsafeBytes { bytes in
            for y in 0..<height { for x in 0..<width { for phase in 0..<4 {
                let value=Float(Float16(bitPattern:UInt16(littleEndian:bytes.loadUnaligned(fromByteOffset:((y*width+x)*4+phase)*2,as:UInt16.self))))
                guard value.isFinite else { throw CameraFailure.message("La fusión RAW devolvió un valor no finito.") }
                mosaic[(y*2+(phase>>1))*w+x*2+(phase&1)]=UInt16(min(65535,max(0,(value*57343+4096).rounded()))).littleEndian
            } } }
        }
        var result=Data([0x49,0x49,42,0])
        result+=u32(8);result+=u16(UInt16(tags.count));result+=entries;result+=u32(0);result+=extra
        result+=mosaic.withUnsafeBufferPointer { Data(buffer:$0) };return result
    }
}
