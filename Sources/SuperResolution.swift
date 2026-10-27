import Foundation

struct BayerGainMap {
    let top:Int,left:Int,bottom:Int,right:Int,rowPitch:Int,colPitch:Int
    let rows:Int,cols:Int,spacingY:Double,spacingX:Double,originY:Double,originX:Double
    let gains:[Float]
    static func read(_ data:Data?) throws -> [Self] {
        guard let data else { return [] };_ = try DNGMetadata.validatedOpcodes(data)
        func u(_ o:Int)->Int { Int(data[o..<o+4].reduce(UInt32(0)){($0<<8)|UInt32($1)}) }
        func d(_ o:Int)->Double { Double(bitPattern:data[o..<o+8].reduce(UInt64(0)){($0<<8)|UInt64($1)}) }
        var offset=4,result=[Self]()
        for _ in 0..<u(0) {
            let id=u(offset),length=u(offset+12),s=offset+16
            // Unknown optical operations cannot be silently dropped by SR.
            guard id==9,length>=76 else { throw CameraFailure.message("Super Res necesita mapas de lente GainMap compatibles.") }
            let rows=u(s+32),cols=u(s+36),planes=u(s+72)
            guard rows>0,cols>0,rows<=512,cols<=512,planes==1,u(s+16)==0,u(s+20)==1,
                  [1,2].contains(u(s+24)),[1,2].contains(u(s+28)),length==76+rows*cols*4 else { throw CameraFailure.message("Mapa de lente SR no compatible.") }
            let sy=d(s+40),sx=d(s+48),oy=d(s+56),ox=d(s+64)
            guard [sy,sx,oy,ox].allSatisfy(\.isFinite),sy>0,sx>0 else { throw CameraFailure.message("Mapa de lente SR inválido.") }
            let values=(0..<rows*cols).map { Float(bitPattern:UInt32(u(s+76+$0*4))) }
            guard values.allSatisfy({$0.isFinite && $0>0 && $0<=32}) else { throw CameraFailure.message("Ganancia óptica fuera de rango.") }
            result.append(Self(top:u(s),left:u(s+4),bottom:u(s+8),right:u(s+12),rowPitch:u(s+24),colPitch:u(s+28),rows:rows,cols:cols,spacingY:sy,spacingX:sx,originY:oy,originX:ox,gains:values));offset=s+length
        }
        return result
    }
    func gain(x:Double,y:Double,phase:Int,sensorWidth:Int,sensorHeight:Int)->Float {
        if x<Double(left) || x>=Double(right) || y<Double(top) || y>=Double(bottom) { return 1 }
        if rowPitch==2 && (phase/2-top%2+2)%2 != 0 { return 1 }
        if colPitch==2 && (phase%2-left%2+2)%2 != 0 { return 1 }
        let gx=min(Double(cols-1),max(0,(x/Double(sensorWidth)-originX)/spacingX))
        let gy=min(Double(rows-1),max(0,(y/Double(sensorHeight)-originY)/spacingY))
        let ix=Int(gx),iy=Int(gy),fx=Float(gx-Double(ix)),fy=Float(gy-Double(iy))
        let nextX:Int=min(cols-1,ix+1),nextY:Int=min(rows-1,iy+1)
        let topRow:Int=iy*cols,bottomRow:Int=nextY*cols
        let a:Float=gains[topRow+ix],b:Float=gains[topRow+nextX]
        let c:Float=gains[bottomRow+ix],d:Float=gains[bottomRow+nextX]
        let upper:Float=a*(1-fx)+b*fx,lower:Float=c*(1-fx)+d*fx
        return upper*(1-fy)+lower*fy
    }
}
struct SuperResolutionPlan {
    let width:Int,height:Int,sensorWidth:Int,sensorHeight:Int
    let originX:Double,originY:Double,scaleX:Double,scaleY:Double
    let maps:[BayerGainMap]
    static func make(_ frame:SensorBayerFrame,count:Int) throws -> Self? {
        guard frame.zoom>=1.25,count>=4 else { return nil }
        let crop=try BayerZoomCrop.geometry(width:frame.width*2,height:frame.height*2,original:frame.calibration.geometry,zoom:frame.zoom)
        let cw=crop.cropSize[0]/2,ch=crop.cropSize[1]/2,factor=min(frame.zoom,2)
        let w=min(2016,Int((cw*factor).rounded())),h=min(1512,Int((ch*factor).rounded()))
        return Self(width:w,height:h,sensorWidth:frame.width*2,sensorHeight:frame.height*2,
            originX:(Double(crop.activeArea[1])+crop.cropOrigin[0])/2,originY:(Double(crop.activeArea[0])+crop.cropOrigin[1])/2,
            scaleX:Double(w)/cw,scaleY:Double(h)/ch,maps:try BayerGainMap.read(frame.calibration.opcodeList2))
    }
    func source(x:Int,y:Int,phase:Int)->(Double,Double) {
        let px=Double(phase%2)*0.5+0.25,py=Double(phase/2)*0.5+0.25
        return (originX+(Double(x)+px)/scaleX-px,originY+(Double(y)+py)/scaleY-py)
    }
    func gain(x:Int,y:Int,phase:Int)->Float {
        let (qx,qy)=source(x:x,y:y,phase:phase)
        return maps.reduce(Float(1)) { $0*$1.gain(x:qx*2+Double(phase%2)+0.5,y:qy*2+Double(phase/2)+0.5,phase:phase,sensorWidth:sensorWidth,sensorHeight:sensorHeight) }
    }
    func calibration(_ original:BayerCalibration)->BayerCalibration {
        var c=original;c.geometry=nil;c.opcodeList2=nil
        // GainMap is applied during mosaic packing in original sensor axes.
        // Do not export an opcode whose geometry no longer matches the raster.
        return c
    }
}

/// Portable scalar reconstruction, also used to verify shared Metal kernel math.
/// Source positions are actual subpixel offsets, never a resized fused image.
enum SuperResolutionReference {
    static func reconstruct(samples:[[Float]],width:Int,height:Int,shifts:[SIMD2<Float>],factor:Int=2)->[Float] {
        precondition(samples.count==shifts.count && samples.allSatisfy{$0.count==width*height})
        var result=[Float](repeating:0,count:width*height*factor*factor)
        for y in 0..<height*factor { for x in 0..<width*factor {
            let p=SIMD2<Float>(UCSRPosition(Float(x),0.25,0,Float(factor)),UCSRPosition(Float(y),0.25,0,Float(factor)))
            var sum:Float=0,weights:Float=0
            for i in samples.indices {
                let q=p+shifts[i],base=SIMD2<Int>(Int(floor(q.x)),Int(floor(q.y)))
                for dy in -1...2 { for dx in -1...2 {
                    let sx=base.x+dx,sy=base.y+dy
                    if sx<0 || sy<0 || sx>=width || sy>=height { continue }
                    let w=UCSRWeight(Float(sx)-q.x,Float(sy)-q.y)
                    sum+=samples[i][sy*width+sx]*w;weights+=w
                } }
            }
            result[y*width*factor+x]=sum/max(weights,1e-8)
        } };return result
    }
}
