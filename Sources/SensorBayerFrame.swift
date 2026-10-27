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
    var baselineExposure:Double? = nil
    var geometry:DNGSensorGeometry? = nil
    var opcodeList2:Data? = nil
    var opcodeList3:Data? = nil
}

struct DNGSensorGeometry:Equatable {
    let width:Int,height:Int,activeArea:[UInt32],cropOrigin:[Double],cropSize:[Double]
    func valid(width:Int,height:Int)->Bool {
        guard self.width==width,self.height==height,activeArea.count==4,cropOrigin.count==2,cropSize.count==2,
              (cropOrigin+cropSize).allSatisfy({$0.isFinite && $0>=0}),cropSize.allSatisfy({$0>=1}),
              activeArea[0]<activeArea[2],activeArea[1]<activeArea[3],activeArea[2]<=UInt32(height),activeArea[3]<=UInt32(width) else { return false }
        return cropOrigin[0]+cropSize[0]<=Double(activeArea[3]-activeArea[1]) &&
               cropOrigin[1]+cropSize[1]<=Double(activeArea[2]-activeArea[0])
    }
}

enum BayerZoomCrop {
    static func geometry(width:Int,height:Int,original:DNGSensorGeometry?,zoom:Double) throws -> DNGSensorGeometry {
        guard width>=4,height>=4,zoom.isFinite,(1...64).contains(zoom) else { throw CameraFailure.message("Zoom RAW fuera de rango.") }
        let source=original ?? DNGSensorGeometry(width:width,height:height,activeArea:[0,0,UInt32(height),UInt32(width)],cropOrigin:[0,0],cropSize:[Double(width),Double(height)])
        guard source.valid(width:width,height:height) else { throw CameraFailure.message("Geometría RAW de zoom inválida.") }
        if zoom==1 { return source }
        let activeWidth=Double(source.activeArea[3]-source.activeArea[1]),activeHeight=Double(source.activeArea[2]-source.activeArea[0])
        // Some camera formats already encode the digital crop in their DNG.
        // Never apply the viewfinder zoom a second time in that case.
        if zoom>1.05,abs(activeWidth/source.cropSize[0]/zoom-1)<0.035,
           abs(activeHeight/source.cropSize[1]/zoom-1)<0.035 { return source }
        let cropW=floor(source.cropSize[0]/zoom/2)*2,cropH=floor(source.cropSize[1]/zoom/2)*2
        guard cropW>=4,cropH>=4 else { throw CameraFailure.message("El encuadre RAW es demasiado pequeño.") }
        let left=Double(source.activeArea[1]),top=Double(source.activeArea[0])
        let x=floor((left+source.cropOrigin[0]+(source.cropSize[0]-cropW)/2)/2)*2-left
        let y=floor((top+source.cropOrigin[1]+(source.cropSize[1]-cropH)/2)/2)*2-top
        let result=DNGSensorGeometry(width:width,height:height,activeArea:source.activeArea,cropOrigin:[x,y],cropSize:[cropW,cropH])
        guard result.valid(width:width,height:height),x>=source.cropOrigin[0],y>=source.cropOrigin[1] else { throw CameraFailure.message("Recorte RAW fuera del área original.") }
        return result
    }
}

/// Half-open quad ROI, including two 16-quad tiles for warp/regularizer support.
struct BayerFusionRegion:Equatable {
    let minX:Int,minY:Int,maxX:Int,maxY:Int
    var vector:SIMD4<UInt32> { SIMD4(UInt32(minX),UInt32(minY),UInt32(maxX),UInt32(maxY)) }
    func level(_ level:Int)->BayerFusionRegion {
        let divisor=1<<level
        return Self(minX:minX/divisor,minY:minY/divisor,maxX:(maxX+divisor-1)/divisor,maxY:(maxY+divisor-1)/divisor)
    }
    static func make(width:Int,height:Int,geometry:DNGSensorGeometry?,zoom:Double) throws -> Self {
        guard width>0,height>0 else { throw CameraFailure.message("ROI Bayer inválida.") }
        if zoom<=1.001 { return Self(minX:0,minY:0,maxX:width,maxY:height) }
        let crop=try BayerZoomCrop.geometry(width:width*2,height:height*2,original:geometry,zoom:zoom)
        let left=Double(crop.activeArea[1])+crop.cropOrigin[0],top=Double(crop.activeArea[0])+crop.cropOrigin[1]
        let x=max(0,Int(floor(left/32))*16-32),y=max(0,Int(floor(top/32))*16-32)
        let right=min(width,Int(ceil((left+crop.cropSize[0])/32))*16+32)
        let bottom=min(height,Int(ceil((top+crop.cropSize[1])/32))*16+32)
        return Self(minX:x,minY:y,maxX:right,maxY:bottom)
    }
}

struct DNGCaptureInfo {
    let exposure:FrameExposure
    var aperture:Double? = nil
    var focalLength:Double? = nil
    var lensModel:String? = nil
    var make:String? = nil
    var model:String? = nil
    static func read(reference:Data,exposure:FrameExposure)->Self {
        var result=Self(exposure:exposure)
        guard let source=CGImageSourceCreateWithData(reference as CFData,nil),
              let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { return result }
        let exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let tiff=props[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        result.aperture=(exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        result.focalLength=(exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        result.lensModel=exif[kCGImagePropertyExifLensModel as String] as? String
        result.make=tiff[kCGImagePropertyTIFFMake as String] as? String
        result.model=tiff[kCGImagePropertyTIFFModel as String] as? String
        return result
    }
}

/// DNG payloads stay file-backed, not as a second 16-frame dirty heap burst.
/// Keeping indexed mappings also handles a late change of the dominant exposure
/// cohort: comparison JPEG and original DNG always use the final same anchor.
struct BayerReferenceArchive {
    private var originals:[Int:Data] = [:]
    mutating func append(_ dng:Data,index:Int) throws {
        let mapped=try BayerScratchStorage.store(dng)
        originals[index]=mapped.data
        mapped.storage.discardResidentPages()
    }
    func original(at index:Int)->Data? { originals[index] }
    mutating func reset() { originals.removeAll() }
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
    var noiseProfile:[Double] = []
    var sharpness:Double = 0
    var zoom:Double = 1
    var lens:LensIdentity = .wide
    func discardResidentPages() { backing?.discardResidentPages() }

    func matchesExposure(of other:SensorBayerFrame)->Bool {
        exposure.isValid && other.exposure.isValid &&
        abs(exposure.seconds/other.exposure.seconds-1)<0.05 && abs(exposure.iso/other.exposure.iso-1)<0.05
    }
    static func referenceIndex(in frames:[SensorBayerFrame],hdr:Bool)->Int? {
        let valid=frames.indices.filter { frames[$0].exposure.isValid }
        if hdr { return valid.min { frames[$0].exposure.product<frames[$1].exposure.product } }
        // Pick the largest exposure cohort before ranking sharpness. A bright
        // outlier must not win merely because its gradients are larger.
        var best:Int?,population=0,score = -Double.infinity
        for index in valid {
            let count=valid.filter { frames[$0].matchesExposure(of:frames[index]) }.count
            let sharpness=frames[index].sharpness.isFinite ? max(0,frames[index].sharpness):0
            if count>population || (count==population && sharpness>score) {
                best=index;population=count;score=sharpness
            }
        }
        return population>=2 ? best:nil
    }

    #if os(iOS)
    static func capture(_ photo:AVCapturePhoto,dng:Data,zoom:Double=1,lens:LensIdentity = .wide) throws -> SensorBayerFrame {
        guard zoom.isFinite,(1...64).contains(zoom) else { throw CameraFailure.message("Zoom RAW inválido.") }
        guard photo.isRawPhoto,let pixel=photo.pixelBuffer,
              let source=CGImageSourceCreateWithData(dng as CFData,nil),
              let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let tags=props[kCGImagePropertyDNGDictionary as String] as? [String:Any] else {
            throw CameraFailure.message("El RAW no contiene plano Bayer y calibración DNG accesibles.")
        }
        let rawMetadata=try DNGMetadata.read(dng)
        func numbers(_ key:String) -> [Double] {
            if let tag=DNGMetadata.namedTags[key],let field=rawMetadata.fields[tag] { return field.numbers }
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
        // Retain the original sensor axes (including masked borders) when the
        // native buffer fits. DefaultCrop remains metadata, not an early crop:
        // OpcodeList2 gain maps must see the exact original pixel coordinates.
        let keepGeometry=w<=4096 && h<=4096 && w%2==0 && h%2==0
        let offsetX=keepGeometry ? 0:left+ox,offsetY=keepGeometry ? 0:top+oy
        let packedWidth=keepGeometry ? w:cw,packedHeight=keepGeometry ? h:ch
        var phaseMap=[Int]()
        for phase in 0..<4 {
            let row=(offsetY+phase/2)%2,col=(offsetX+phase%2)%2
            phaseMap.append(row*2+col)
        }
        let croppedPattern=phaseMap.map { pattern[$0] }
        let step=max(1,Int(ceil(Double(max(packedWidth,packedHeight))/4096)))
        let qw=packedWidth/(2*step),qh=packedHeight/(2*step)
        let status=CVPixelBufferLockBaseAddress(pixel,.readOnly)
        guard status==kCVReturnSuccess else { throw CameraFailure.message("No se pudo leer el plano Bayer.") }
        defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        let rowBytes=CVPixelBufferGetBytesPerRow(pixel)
        guard let base=CVPixelBufferGetBaseAddress(pixel),rowBytes>=w*2,rowBytes%2==0,Int(bitPattern:base)%2==0 else { throw CameraFailure.message("Stride o alineación Bayer inválidos.") }
        let blackPhases=BayerQuadPacking.phaseIndices(originX:offsetX,originY:offsetY,anchorX:left,anchorY:top)
        let levels=blackPhases.map { Float(black[black.count==1 ? 0:$0]) }
        let samples=UnsafeBufferPointer(start:base.assumingMemoryBound(to:UInt16.self),count:rowBytes/2*h)
        let packed=try BayerQuadPacking.pack(samples,rowElements:rowBytes/2,originX:offsetX,originY:offsetY,
            cropWidth:packedWidth,cropHeight:packedHeight,step:step,black:levels,white:Float(white))
        let exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let exposure=FrameExposure(seconds:(exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0,
            iso:(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 0)
        guard exposure.isValid,photo.timestamp.seconds.isFinite else { throw CameraFailure.message("El RAW no incluye exposición y tiempo válidos.") }
        var extra=[UInt16:[Double]]()
        for (key,tag,count) in [("ColorMatrix2",UInt16(50722),9),("CameraCalibration1",UInt16(50723),9),("CameraCalibration2",UInt16(50724),9),("AnalogBalance",UInt16(50727),3),("ForwardMatrix1",UInt16(50964),9),("ForwardMatrix2",UInt16(50965),9)] {
            let values=numbers(key)
            guard values.isEmpty || (values.count==count && values.allSatisfy({$0.isFinite && abs($0)<32}) && (tag != 50727 || values.allSatisfy({$0>0}))) else { throw CameraFailure.message("Calibración de color RAW inválida.") }
            if !values.isEmpty { extra[tag]=values }
        }
        let secondIlluminant=numbers("CalibrationIlluminant2").first ?? 0
        let needsSecond=extra[50722] != nil || extra[50965] != nil
        guard !needsSecond || (secondIlluminant>=1 && secondIlluminant<=255 && secondIlluminant.rounded()==secondIlluminant) else { throw CameraFailure.message("Falta el segundo iluminante del DNG.") }
        let orientation=(props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        guard (1...8).contains(orientation) else { throw CameraFailure.message("Orientación RAW inválida.") }
        var calibration=BayerCalibration(pattern:croppedPattern,matrix:matrix,neutral:neutral,illuminant:UInt16(illumination),orientation:orientation)
        calibration.extraColor=extra;calibration.illuminant2=needsSecond ? UInt16(secondIlluminant):0
        let baseline=numbers("BaselineExposure")
        guard baseline.isEmpty || (baseline.count==1 && baseline[0].isFinite && abs(baseline[0])<=16) else { throw CameraFailure.message("Exposición base DNG inválida.") }
        calibration.baselineExposure=baseline.first
        if keepGeometry {
            calibration.geometry=DNGSensorGeometry(width:w,height:h,activeArea:[UInt32(top),UInt32(left),UInt32(bottom),UInt32(right)],
                cropOrigin:[Double(ox),Double(oy)],cropSize:[Double(cw),Double(ch)])
            if let opcode=rawMetadata.fields[51009],opcode.type==7 { calibration.opcodeList2=try DNGMetadata.validatedOpcodes(opcode.data) }
            if let opcode=rawMetadata.fields[51022],opcode.type==7 { calibration.opcodeList3=try DNGMetadata.validatedOpcodes(opcode.data) }
        }
        let mapped=try BayerScratchStorage.store(packed)
        var frame=SensorBayerFrame(width:qw,height:qh,quads:mapped.data,calibration:calibration,exposure:exposure,timestamp:photo.timestamp.seconds)
        frame.noiseProfile=SensorNoiseModel.validProfile(numbers("NoiseProfile")) ?? []
        frame.zoom=zoom;frame.lens=lens
        frame.sharpness=BayerQuadPacking.sharpness(quads:packed,width:qw,height:qh,pattern:croppedPattern,
            noise:SensorNoiseModel.coefficients(iso:exposure.iso,profile:frame.noiseProfile,lens:lens))
        frame.backing=mapped.storage;return frame
    }
    #endif
}

/// DNG normalized linear-domain variance = shot * signal + read variance.
/// ISO fallback follows the DNG baseline ISO-100 model; a real profile already
/// includes gain and must not be multiplied by ISO a second time.
enum SensorNoiseModel {
    static func validProfile(_ values:[Double])->[Double]? {
        guard [2,6].contains(values.count) else { return nil }
        for pair in stride(from:0,to:values.count,by:2) {
            guard values[pair].isFinite,values[pair]>0,values[pair]<=1,
                  values[pair+1].isFinite,values[pair+1]>=0,values[pair+1]<=1 else { return nil }
        }
        return values
    }
    static func coefficients(iso:Double,profile:[Double],lens:LensIdentity = .wide)->SIMD2<Float> {
        if let profile=validProfile(profile) {
            var shot=0.0,read=0.0
            for pair in stride(from:0,to:profile.count,by:2) { shot+=profile[pair];read+=profile[pair+1] }
            let planes=Double(profile.count/2)
            return SIMD2<Float>(Float(shot/planes),Float(read/planes))
        }
        let gain=Float(min(128,max(0.25,iso.isFinite ? iso/100:1)))
        let prior=LensCalibration.profile(lens)
        return SIMD2<Float>(2e-5*gain*prior.shot,4.5e-7*gain*gain*prior.read)
    }
    static func pair(reference:FrameExposure,referenceProfile:[Double],sample:FrameExposure,sampleProfile:[Double],scale:Float,referenceLens:LensIdentity = .wide,sampleLens:LensIdentity = .wide)->SIMD2<Float> {
        let a=coefficients(iso:reference.iso,profile:referenceProfile,lens:referenceLens),b=coefficients(iso:sample.iso,profile:sampleProfile,lens:sampleLens)
        return SIMD2<Float>(a.x+b.x*scale,a.y+b.y*scale*scale)
    }
}

enum BayerImpulseProtection {
    /// Same per-phase soft rejection used by the GPU prepass. Also prevents an
    /// isolated green impulse from winning the CPU lucky-imaging metric.
    static func value(_ center:Float,minimum:Float,maximum:Float,noise:SIMD2<Float>)->Float {
        guard center.isFinite,minimum.isFinite,maximum.isFinite,minimum<=maximum else { return center }
        let bounded=min(maximum,max(minimum,center))
        let variance=max(1e-8,noise.x*max(0,(minimum+maximum)*0.5)+noise.y)
        let threshold=6*sqrt(variance),distance=abs(center-bounded)
        let t=min(1,max(0,(distance-threshold)/threshold))
        return center+(bounded-center)*(t*t*(3-2*t))
    }
}

enum BayerQuadPacking {
    /// Bounded central reduction (~18K samples), computed once while packing
    /// data is resident. Both green phases are measured independently; no CFA
    /// colors are mixed, and no full image or scratch mapping is read again.
    static func sharpness(quads:Data,width:Int,height:Int,pattern:[UInt8],noise:SIMD2<Float> = SIMD2<Float>(2e-5,4.5e-7))->Double {
        guard width>=8,height>=8,quads.count==width*height*8,pattern.count==4 else { return 0 }
        let greens=pattern.indices.filter { pattern[$0]==1 }
        guard greens.count==2 else { return 0 }
        let spanX=min(width-4,384),spanY=min(height-4,384)
        let x0=(width-spanX)/2,y0=(height-spanY)/2
        let step=max(1,max(spanX,spanY)/96)
        return quads.withUnsafeBytes { bytes in
            var energy=0.0,light=0.0,count=0
            func raw(_ x:Int,_ y:Int,_ phase:Int)->Float {
                let bits=bytes.loadUnaligned(fromByteOffset:((y*width+x)*4+phase)*2,as:UInt16.self)
                return Float(Float16(bitPattern:UInt16(littleEndian:bits)))
            }
            func green(_ x:Int,_ y:Int,_ phase:Int)->Double {
                var low=Float.infinity,high = -Float.infinity
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let value=raw(min(width-1,max(0,x+dx)),min(height-1,max(0,y+dy)),phase)
                    low=min(low,value);high=max(high,value)
                } }
                return Double(BayerImpulseProtection.value(raw(x,y,phase),minimum:low,maximum:high,noise:noise))
            }
            for y in stride(from:y0,to:y0+spanY,by:step) {
                for x in stride(from:x0,to:x0+spanX,by:step) {
                    for phase in greens {
                        let a=green(x,y,phase),b=green(x+1,y,phase),c=green(x,y+1,phase)
                        guard a.isFinite,b.isFinite,c.isFinite,a<0.98,b<0.98,c<0.98 else { continue }
                        let dx=min(0.1,abs(b-a)),dy=min(0.1,abs(c-a))
                        energy+=dx*dx+dy*dy;light+=max(0,a);count+=1
                    }
                }
            }
            guard count>0 else { return 0 }
            return energy/Double(count)/max(0.0001,light/Double(count))
        }
    }
    static func phaseIndices(originX:Int,originY:Int,anchorX:Int=0,anchorY:Int=0)->[Int] {
        (0..<4).map { phase in
            let row=((originY+phase/2-anchorY)%2+2)%2,col=((originX+phase%2-anchorX)%2+2)%2
            return row*2+col
        }
    }
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

/// Calibrated uncompressed DNG for CIRAWFilter and optional computational RAW
/// export. The original camera DNG remains the default export choice.
enum FusedDNG {
    static func encode(quads:Data,width:Int,height:Int,calibration c:BayerCalibration,noiseProfile:[Double]=[],zoom:Double=1,capture:DNGCaptureInfo?=nil) throws -> Data {
        guard width>0,height>0,width<=2048,height<=2048,quads.count==width*height*8,c.pattern.count==4,
              c.matrix.count==9,c.matrix.allSatisfy({$0.isFinite && abs($0)<32}),
              c.neutral.count==3,c.neutral.allSatisfy({$0.isFinite && $0>0 && $0<32}),
              c.pattern.sorted()==[0,1,1,2],(1...8).contains(c.orientation),(1...255).contains(c.illuminant) else { throw CameraFailure.message("Mosaico fusionado inválido.") }
        func u16(_ n:UInt16)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func u32(_ n:UInt32)->Data { var x=n.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
        func f64(_ n:Double)->Data { var x=n.bitPattern.littleEndian;return withUnsafeBytes(of:&x) { Data($0) } }
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
        let outputGeometry=try BayerZoomCrop.geometry(width:w,height:h,original:c.geometry,zoom:zoom)
        add(254,4,1,u32(0))
        add(256,4,1,u32(UInt32(w)));add(257,4,1,u32(UInt32(h)))
        add(258,3,1,u16(16));add(259,3,1,u16(1));add(262,3,1,u16(32803))
        add(273,4,1,u32(0));add(274,3,1,u16(UInt16(c.orientation)))
        add(277,3,1,u16(1));add(278,4,1,u32(UInt32(h)));add(279,4,1,u32(UInt32(w*h*2)))
        let active=c.geometry?.activeArea ?? [0,0,UInt32(h),UInt32(w)]
        guard active.count==4 else { throw CameraFailure.message("Área activa DNG inválida.") }
        let dngPattern=BayerQuadPacking.phaseIndices(originX:Int(active[1]),originY:Int(active[0])).map { c.pattern[$0] }
        add(284,3,1,u16(1));add(33421,3,2,u16(2)+u16(2));add(33422,1,4,Data(dngPattern))
        add(50706,1,4,Data([1,4,0,0]));add(50707,1,4,Data([1,3,0,0]))
        let model=Data("UltimateCAM working mosaic\0".utf8);add(50708,2,UInt32(model.count),model)
        add(50710,1,3,Data([0,1,2]));add(50711,3,1,u16(1))
        add(50713,3,2,u16(1)+u16(1));add(50714,5,1,rational(4096));add(50717,4,1,u32(61439))
        if c.geometry != nil || zoom>1 {
            let geometry=outputGeometry
            guard geometry.valid(width:w,height:h) else { throw CameraFailure.message("La corrección de lente no coincide con el mosaico.") }
            add(50719,5,2,geometry.cropOrigin.reduce(Data()) { $0+rational($1) })
            add(50720,5,2,geometry.cropSize.reduce(Data()) { $0+rational($1) })
            add(50829,4,4,geometry.activeArea.reduce(Data()) { $0+u32($1) })
            if let opcodes=c.opcodeList2 {
                guard c.geometry != nil else { throw CameraFailure.message("Falta la geometría original de la corrección de lente.") }
                let data=try DNGMetadata.validatedOpcodes(opcodes);add(51009,7,UInt32(data.count),data)
            }
        } else {
            guard c.opcodeList2==nil else { throw CameraFailure.message("Falta la geometría original de la corrección de lente.") }
            add(50719,5,2,rational(0)+rational(0));add(50720,4,2,u32(UInt32(w))+u32(UInt32(h)))
            add(50829,4,4,u32(0)+u32(0)+u32(UInt32(h))+u32(UInt32(w)))
        }
        if let opcodes=c.opcodeList3 {
            let data=try DNGMetadata.validatedOpcodes(opcodes);add(51022,7,UInt32(data.count),data)
        }
        add(50721,10,9,c.matrix.reduce(Data()) { $0+rational($1,signed:true) })
        add(50728,5,3,c.neutral.reduce(Data()) { $0+rational($1) });add(50778,3,1,u16(c.illuminant))
        for (tag,values) in c.extraColor {
            guard [50722,50723,50724,50727,50964,50965].contains(tag),values.count==(tag==50727 ? 3:9),values.allSatisfy({$0.isFinite && abs($0)<32}),tag != 50727 || values.allSatisfy({$0>0}) else { throw CameraFailure.message("Etiquetas de color DNG fuera de rango.") }
            add(tag,tag==50727 ? 5:10,UInt32(values.count),values.reduce(Data()) { $0+rational($1,signed:tag != 50727) })
        }
        if c.illuminant2>0 { add(50779,3,1,u16(c.illuminant2)) }
        if let baseline=c.baselineExposure {
            guard baseline.isFinite,abs(baseline)<=16 else { throw CameraFailure.message("Exposición base DNG fuera de rango.") }
            add(50730,10,1,rational(baseline,signed:true))
        }
        if !noiseProfile.isEmpty {
            guard let profile=SensorNoiseModel.validProfile(noiseProfile) else { throw CameraFailure.message("Modelo de ruido DNG inválido.") }
            add(51041,12,UInt32(profile.count),profile.reduce(Data()) { $0+f64($1) })
        }
        // Canonical TIFF/EP layout: reduced RGB IFD0 plus full Bayer SubIFD.
        // Keep global DNG/color tags in IFD0 as well as the raw directory.
        let globalTags:Set<UInt16>=[50706,50707,50708,50721,50722,50723,50724,50727,50728,50730,50778,50779,50964,50965]
        var preview=tags.filter { globalTags.contains($0.key) }
        var exif=[Tag]()
        if let capture {
            guard capture.exposure.isValid,capture.exposure.seconds<=3600,capture.exposure.iso<=65535 else { throw CameraFailure.message("EXIF RAW inválido.") }
            exif.append(Tag(key:33434,type:5,count:1,data:rational(capture.exposure.seconds)))
            exif.append(Tag(key:34855,type:3,count:1,data:u16(UInt16(capture.exposure.iso.rounded()))))
            for (key,value) in [(UInt16(33437),capture.aperture),(UInt16(37386),capture.focalLength)] {
                if let value,value.isFinite,value>0,value<1000 { exif.append(Tag(key:key,type:5,count:1,data:rational(value))) }
            }
            func ascii(_ value:String?)->Data? {
                guard let value,!value.isEmpty,value.utf8.count<=256,let data=value.data(using:.ascii) else { return nil }
                return data+Data([0])
            }
            if let value=ascii(capture.lensModel) { exif.append(Tag(key:42036,type:2,count:UInt32(value.count),data:value)) }
            for (key,text) in [(UInt16(271),capture.make),(UInt16(272),capture.model)] {
                if let value=ascii(text) { preview.append(Tag(key:key,type:2,count:UInt32(value.count),data:value)) }
            }
            preview.append(Tag(key:34665,type:4,count:1,data:u32(0)))
        }
        exif.sort { $0.key<$1.key }
        func thumb(_ key:UInt16,_ type:UInt16,_ count:UInt32,_ data:Data) { preview.append(Tag(key:key,type:type,count:count,data:data)) }
        thumb(254,4,1,u32(1));thumb(256,4,1,u32(16));thumb(257,4,1,u32(16))
        thumb(258,3,3,u16(8)+u16(8)+u16(8));thumb(259,3,1,u16(1));thumb(262,3,1,u16(2))
        thumb(273,4,1,u32(0));thumb(274,3,1,u16(UInt16(c.orientation)));thumb(277,3,1,u16(3))
        thumb(278,4,1,u32(16));thumb(279,4,1,u32(16*16*3));thumb(284,3,1,u16(1));thumb(330,4,1,u32(0))
        tags.sort { $0.key<$1.key };preview.sort { $0.key<$1.key }
        func directorySize(_ tags:[Tag])->Int { 2+tags.count*12+4+tags.reduce(0) { $0+($1.data.count>4 ? ($1.data.count+1)/2*2:0) } }
        let rawOffset=8+directorySize(preview),exifOffset=rawOffset+directorySize(tags)
        let thumbnailOffset=exifOffset+(exif.isEmpty ? 0:directorySize(exif))
        let stripOffset=thumbnailOffset+16*16*3
        func directory(_ tags:[Tag],offset:Int,strip:Int)->Data {
            let base=offset+2+tags.count*12+4
            var extra=Data(),entries=Data()
            for tag in tags {
                entries+=u16(tag.key)+u16(tag.type)+u32(tag.count)
                if tag.key==273 { entries+=u32(UInt32(strip)) }
                else if tag.key==330 { entries+=u32(UInt32(rawOffset)) }
                else if tag.key==34665 { entries+=u32(UInt32(exifOffset)) }
                else if tag.data.count<=4 { entries+=tag.data+Data(repeating:0,count:4-tag.data.count) }
                else { entries+=u32(UInt32(base+extra.count));extra+=tag.data;if extra.count%2==1 { extra.append(0) } }
            }
            var output=u16(UInt16(tags.count));output+=entries;output+=u32(0);output+=extra;return output
        }
        var header=Data([0x49,0x49,42,0]);header+=u32(8)
        header+=directory(preview,offset:8,strip:thumbnailOffset)
        header+=directory(tags,offset:rawOffset,strip:stripOffset)
        if !exif.isEmpty { header+=directory(exif,offset:exifOffset,strip:0) }
        // Reduced placeholder; the exported RAW is paired with its rendered JPEG.
        header+=Data(repeating:46,count:16*16*3)
        guard header.count==stripOffset,stripOffset%2==0 else { throw CameraFailure.message("Cabecera DNG desalineada.") }
        let length=header.count+w*h*2
        let allocation=UnsafeMutableRawPointer.allocate(byteCount:length,alignment:16)
        var transferred=false
        defer { if !transferred { allocation.deallocate() } }
        header.withUnsafeBytes { allocation.copyMemory(from:$0.baseAddress!,byteCount:header.count) }
        let mosaic=allocation.advanced(by:stripOffset).assumingMemoryBound(to:UInt16.self)
        try quads.withUnsafeBytes { bytes in
            guard let address=bytes.baseAddress,Int(bitPattern:address)%2==0 else { throw CameraFailure.message("Cuartetos RAW desalineados.") }
            let input=UnsafeBufferPointer(start:address.assumingMemoryBound(to:UInt16.self),count:width*height*4)
            @inline(__always) func encoded(_ bits:UInt16) throws -> UInt16 {
                let value=Float(Float16(bitPattern:UInt16(littleEndian:bits)))
                guard value.isFinite else { throw CameraFailure.message("La fusión RAW devolvió un valor no finito.") }
                let sample=min(Float(65535),max(0,(value*57343+4096).rounded()))
                return UInt16(sample).littleEndian
            }
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
        let result=Data(bytesNoCopy:allocation,count:length,deallocator:.custom { pointer,_ in pointer.deallocate() })
        transferred=true;return result
    }
}
