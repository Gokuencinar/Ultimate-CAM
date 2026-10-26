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
    var backing:BayerScratchStorage? = nil
    func discardResidentPages() { backing?.discardResidentPages() }

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
        let step=max(1,Int(ceil(Double(max(cw,ch))/4096)))
        let qw=cw/(2*step),qh=ch/(2*step)
        let status=CVPixelBufferLockBaseAddress(pixel,.readOnly)
        guard status==kCVReturnSuccess else { throw CameraFailure.message("No se pudo leer el plano Bayer.") }
        defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        let rowBytes=CVPixelBufferGetBytesPerRow(pixel)
        guard let base=CVPixelBufferGetBaseAddress(pixel),rowBytes>=w*2,rowBytes%2==0,Int(bitPattern:base)%2==0 else { throw CameraFailure.message("Stride o alineación Bayer inválidos.") }
        let levels=phaseMap.map { Float(black[black.count==1 ? 0:$0]) }
        let samples=UnsafeBufferPointer(start:base.assumingMemoryBound(to:UInt16.self),count:rowBytes/2*h)
        let packed=try BayerQuadPacking.pack(samples,rowElements:rowBytes/2,originX:offsetX,originY:offsetY,
            cropWidth:cw,cropHeight:ch,step:step,black:levels,white:Float(white))
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
        let mapped=try BayerScratchStorage.store(packed)
        var frame=SensorBayerFrame(width:qw,height:qh,quads:mapped.data,calibration:calibration,exposure:exposure,timestamp:photo.timestamp.seconds)
        frame.backing=mapped.storage;return frame
    }
    #endif
}

enum BayerQuadPacking {
    static func pack(_ input:UnsafeBufferPointer<UInt16>,rowElements:Int,originX:Int,originY:Int,
                     cropWidth:Int,cropHeight:Int,step:Int,black:[Float],white:Float) throws -> Data {
        guard rowElements>0,originX>=0,originY>=0,cropWidth>=4,cropHeight>=4,
              step>=1,step<=5,originX+cropWidth<=rowElements,(originY+cropHeight)<=input.count/rowElements,
              black.count==4,black.allSatisfy({$0.isFinite && $0>=0 && $0+64<white}),white.isFinite,white<=16383 else { throw CameraFailure.message("Plano Bayer fuera de límites.") }
        let width=cropWidth/(2*step),height=cropHeight/(2*step)
        guard width>0,height>0,width<=2048,height<=2048,let source=input.baseAddress else { throw CameraFailure.message("Dimensiones de cuartetos fuera de rango.") }
        let count=width*height*4,output=UnsafeMutablePointer<UInt16>.allocate(capacity:count)
        var transferred=false
        defer { if !transferred { output.deallocate() } }
        let b=SIMD4<Float>(black[0],black[1],black[2],black[3])
        let gain=SIMD4<Float>(repeating:1)/(SIMD4<Float>(repeating:white)-b)
        @inline(__always) func normalized(_ value:UInt16,_ phase:Int) -> UInt16 { Float16((Float(UInt16(littleEndian:value))-b[phase])*gain[phase]).bitPattern.littleEndian }
        if step==1 {
            // Native 4032x3024: two tight loops and four explicitly typed loads.
            // No per-pixel division, interpolation, Data indexing or extra copy.
            for y in 0..<height {
                let top=source.advanced(by:(originY+y*2)*rowElements+originX),bottom=top.advanced(by:rowElements)
                let destination=output.advanced(by:y*width*4)
                for x in 0..<width {
                    let a=top[x*2],b=top[x*2+1],c=bottom[x*2],d=bottom[x*2+1]
                    guard ((UInt16(littleEndian:a)|UInt16(littleEndian:b)|UInt16(littleEndian:c)|UInt16(littleEndian:d)) & 0xc000)==0 else { throw CameraFailure.message("El sensor excede el formato Bayer de 14 bits.") }
                    let q=destination.advanced(by:x*4)
                    q[0]=normalized(a,0);q[1]=normalized(b,1);q[2]=normalized(c,2);q[3]=normalized(d,3)
                }
            }
        } else {
            // Larger sensors: resample each CFA phase at its physical center.
            for y in 0..<height { for x in 0..<width { for phase in 0..<4 {
                let px=phase&1,py=phase>>1
                let sx=Double(x*step)+Double(px*(step-1))/2+Double(step-1)/4
                let sy=Double(y*step)+Double(py*(step-1))/2+Double(step-1)/4
                let ix=Int(floor(sx)),iy=Int(floor(sy)),fx=Float(sx-Double(floor(sx))),fy=Float(sy-Double(floor(sy)))
                var sum:Float=0
                for dy in 0...1 { for dx in 0...1 {
                    let col=originX+min((cropWidth-1-px)/2,max(0,ix+dx))*2+px
                    let row=originY+min((cropHeight-1-py)/2,max(0,iy+dy))*2+py
                    let value=UInt16(littleEndian:source[row*rowElements+col])
                    guard value<=16383 else { throw CameraFailure.message("Bayer fuera de rango.") }
                    sum+=Float(value)*(dx==0 ? 1-fx:fx)*(dy==0 ? 1-fy:fy)
                } }
                output[(y*width+x)*4+phase]=Float16((sum-b[phase])*gain[phase]).bitPattern.littleEndian
            } } }
        }
        let data=Data(bytesNoCopy:UnsafeMutableRawPointer(output),count:count*2,deallocator:.custom { pointer,_ in pointer.assumingMemoryBound(to:UInt16.self).deallocate() })
        transferred=true;return data
    }
}

/// Minimal uncompressed DNG for CIRAWFilter demosaicing/color conversion of the
/// fused mosaic. The saved user's RAW remains the original, never this working DNG.
enum FusedDNG {
    static func encode(quads:Data,width:Int,height:Int,calibration c:BayerCalibration) throws -> Data {
        guard width>0,height>0,width<=2048,height<=2048,quads.count==width*height*8,c.pattern.count==4,
              c.matrix.count==9,c.matrix.allSatisfy({$0.isFinite && abs($0)<32}),
              c.neutral.count==3,c.neutral.allSatisfy({$0.isFinite && $0>0 && $0<32}),
              c.pattern.sorted()==[0,1,1,2],(1...8).contains(c.orientation),(1...255).contains(c.illuminant) else { throw CameraFailure.message("Mosaico fusionado inválido.") }
        func stage(_ name:String) {
            #if os(macOS)
            if ProcessInfo.processInfo.environment["UC_DNG_TRACE"]=="1" { print("DNG:",name) }
            #endif
        }
        stage("validated")
        func u16(_ n:UInt16)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func u32(_ n:UInt32)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func rational(_ n:Double,signed:Bool=false)->Data {
            if n.rounded()==n {
                let numerator=signed ? UInt32(bitPattern:Int32(n)):UInt32(n)
                return u32(numerator)+u32(1)
            }
            let scaled=(n*1_000_000).rounded()
            let numerator=signed ? UInt32(bitPattern:Int32(scaled)):UInt32(scaled)
            return u32(numerator)+u32(1_000_000)
        }
        struct Tag { let key:UInt16,type:UInt16,count:UInt32,data:Data }
        var tags=[Tag]()
        func add(_ key:UInt16,_ type:UInt16,_ count:UInt32,_ data:Data) { tags.append(Tag(key:key,type:type,count:count,data:data)) }
        let w=width*2,h=height*2
        add(254,4,1,u32(0))
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
            guard [50722,50723,50724,50727].contains(tag),values.count==(tag==50727 ? 3:9),values.allSatisfy({$0.isFinite && abs($0)<32}),tag != 50727 || values.allSatisfy({$0>0}) else { throw CameraFailure.message("Etiquetas de color DNG fuera de rango.") }
            add(tag,tag==50727 ? 5:10,UInt32(values.count),values.reduce(Data()) { $0+rational($1,signed:tag != 50727) })
        }
        if c.illuminant2>0 { add(50779,3,1,u16(c.illuminant2)) }
        // Canonical TIFF/EP layout: reduced RGB IFD0 plus full Bayer SubIFD.
        // Keep global DNG/color tags in IFD0 as well as the raw directory.
        var preview=tags.filter { $0.key>=50706 }
        func thumb(_ key:UInt16,_ type:UInt16,_ count:UInt32,_ data:Data) { preview.append(Tag(key:key,type:type,count:count,data:data)) }
        thumb(254,4,1,u32(1));thumb(256,4,1,u32(16));thumb(257,4,1,u32(16))
        thumb(258,3,3,u16(8)+u16(8)+u16(8));thumb(259,3,1,u16(1));thumb(262,3,1,u16(2))
        thumb(273,4,1,u32(0));thumb(274,3,1,u16(UInt16(c.orientation)));thumb(277,3,1,u16(3))
        thumb(278,4,1,u32(16));thumb(279,4,1,u32(16*16*3));thumb(284,3,1,u16(1));thumb(330,4,1,u32(0))
        tags.sort { $0.key<$1.key };preview.sort { $0.key<$1.key }
        func directorySize(_ tags:[Tag])->Int { 2+tags.count*12+4+tags.reduce(0) { $0+($1.data.count>4 ? ($1.data.count+1)/2*2:0) } }
        let rawOffset=8+directorySize(preview),thumbnailOffset=rawOffset+directorySize(tags)
        let stripOffset=thumbnailOffset+16*16*3
        func directory(_ tags:[Tag],offset:Int,strip:Int)->Data {
            let base=offset+2+tags.count*12+4
            var extra=Data(),entries=Data()
            for tag in tags {
                entries+=u16(tag.key)+u16(tag.type)+u32(tag.count)
                if tag.key==273 { entries+=u32(UInt32(strip)) }
                else if tag.key==330 { entries+=u32(UInt32(rawOffset)) }
                else if tag.data.count<=4 { entries+=tag.data+Data(repeating:0,count:4-tag.data.count) }
                else { entries+=u32(UInt32(base+extra.count));extra+=tag.data;if extra.count%2==1 { extra.append(0) } }
            }
            var output=u16(UInt16(tags.count));output+=entries;output+=u32(0);output+=extra;return output
        }
        var header=Data([0x49,0x49,42,0]);header+=u32(8)
        header+=directory(preview,offset:8,strip:thumbnailOffset)
        header+=directory(tags,offset:rawOffset,strip:stripOffset)
        // Private working DNG only: the placeholder is never saved as a photo.
        header+=Data(repeating:46,count:16*16*3)
        guard header.count==stripOffset,stripOffset%2==0 else { throw CameraFailure.message("Cabecera DNG desalineada.") }
        stage("header built")
        let length=header.count+w*h*2
        let allocation=UnsafeMutableRawPointer.allocate(byteCount:length,alignment:16)
        var transferred=false
        defer { if !transferred { allocation.deallocate() } }
        header.withUnsafeBytes { allocation.copyMemory(from:$0.baseAddress!,byteCount:header.count) }
        let mosaic=allocation.advanced(by:stripOffset).assumingMemoryBound(to:UInt16.self)
        stage("allocated output")
        try quads.withUnsafeBytes { bytes in
            guard let address=bytes.baseAddress,Int(bitPattern:address)%2==0 else { throw CameraFailure.message("Cuartetos RAW desalineados.") }
            let input=UnsafeBufferPointer(start:address.assumingMemoryBound(to:UInt16.self),count:width*height*4)
            @inline(__always) func encoded(_ bits:UInt16) throws -> UInt16 {
                let value=Float(Float16(bitPattern:UInt16(littleEndian:bits)))
                guard value.isFinite else { throw CameraFailure.message("La fusión RAW devolvió un valor no finito.") }
                let sample=min(Float(65535),max(0,(value*57343+4096).rounded()))
                return UInt16(sample).littleEndian
            }
            stage("typed input")
            for y in 0..<height {
                let top=mosaic.advanced(by:y*2*w),bottom=top.advanced(by:w)
                let row=input.baseAddress!.advanced(by:y*width*4)
                for x in 0..<width {
                    let q=row.advanced(by:x*4),pixel=x*2
                    top[pixel]=try encoded(q[0]);top[pixel+1]=try encoded(q[1])
                    bottom[pixel]=try encoded(q[2]);bottom[pixel+1]=try encoded(q[3])
                }
            }
        }
        stage("pixels written")
        let result=Data(bytesNoCopy:allocation,count:length,deallocator:.custom { pointer,_ in pointer.deallocate() })
        transferred=true;return result
    }
}
