import Foundation

struct BayerGainMap {
    let top:Int,left:Int,bottom:Int,right:Int,rowPitch:Int,colPitch:Int
    let rows:Int,cols:Int,spacingY:Double,spacingX:Double,originY:Double,originX:Double
    let gains:[Float]
    var flags:UInt32=0
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
            guard [sy,sx,oy,ox].allSatisfy({$0.isFinite && abs($0)<=1e6}),sy>0,sx>0 else { throw CameraFailure.message("Mapa de lente SR inválido.") }
            let values=(0..<rows*cols).map { Float(bitPattern:UInt32(u(s+76+$0*4))) }
            guard values.allSatisfy({$0.isFinite && $0>0 && $0<=32}) else { throw CameraFailure.message("Ganancia óptica fuera de rango.") }
            result.append(Self(top:u(s),left:u(s+4),bottom:u(s+8),right:u(s+12),rowPitch:u(s+24),colPitch:u(s+28),rows:rows,cols:cols,spacingY:sy,spacingX:sx,originY:oy,originX:ox,gains:values,flags:UInt32(u(offset+8))));offset=s+length
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
    /// Affine reparameterization of the original bilinear map. Keep its grid
    /// samples intact; let the floating-point RAW decoder apply gain after the
    /// 16-bit mosaic is read, preserving corner highlight headroom.
    func transformed(_ plan:SuperResolutionPlan)->Data? {
        let w=plan.width*2,h=plan.height*2,cropX=plan.originX*2,cropY=plan.originY*2
        let cw=Double(w)/plan.scaleX,ch=Double(h)/plan.scaleY
        func first(_ coordinate:Double,_ scale:Double,_ crop:Double,_ phase:Int,_ pitch:Int,_ limit:Int)->Int {
            let edge:Double=(coordinate-crop)*scale-0.5
            var value:Int=max(0,min(limit,Int(ceil(edge))))
            if pitch==2 && value%2 != phase { value+=1 };return min(limit,value)
        }
        let l=first(Double(left),plan.scaleX,cropX,left%2,colPitch,w)
        let t=first(Double(top),plan.scaleY,cropY,top%2,rowPitch,h)
        let r=max(0,min(w,Int(ceil((Double(right)-cropX)*plan.scaleX-0.5))))
        let b=max(0,min(h,Int(ceil((Double(bottom)-cropY)*plan.scaleY-0.5))))
        guard l<r,t<b else { return nil }
        func be32(_ value:UInt32)->Data { var x=value.bigEndian;return withUnsafeBytes(of:&x){Data($0)} }
        func be64(_ value:Double)->Data { var x=value.bitPattern.bigEndian;return withUnsafeBytes(of:&x){Data($0)} }
        let fields:[UInt32]=[UInt32(t),UInt32(l),UInt32(b),UInt32(r),0,1,UInt32(rowPitch),UInt32(colPitch),UInt32(rows),UInt32(cols)]
        var payload=fields.reduce(Data()){$0+be32($1)}
        payload+=be64(spacingY*Double(plan.sensorHeight)/ch)
        payload+=be64(spacingX*Double(plan.sensorWidth)/cw)
        payload+=be64((originY*Double(plan.sensorHeight)-cropY)/ch)
        payload+=be64((originX*Double(plan.sensorWidth)-cropX)/cw)
        payload+=be32(1)
        for gain in gains { payload+=be32(gain.bitPattern) }
        return be32(9)+be32(0x01030000)+be32(flags)+be32(UInt32(payload.count))+payload
    }

}
struct SuperResolutionPlan {
    let width:Int,height:Int,sensorWidth:Int,sensorHeight:Int
    let originX:Double,originY:Double,scaleX:Double,scaleY:Double
    let maps:[BayerGainMap]
    var vignette:Data?=nil
    static func make(_ frame:SensorBayerFrame,count:Int) throws -> Self? {
        guard frame.zoom>=1.25,count>=4 else { return nil }
        let crop=try BayerZoomCrop.geometry(width:frame.width*2,height:frame.height*2,original:frame.calibration.geometry,zoom:frame.zoom)
        let cw=crop.cropSize[0]/2,ch=crop.cropSize[1]/2,factor=min(frame.zoom,2)
        let w=min(2016,Int((cw*factor).rounded())),h=min(1512,Int((ch*factor).rounded()))
        var result=Self(width:w,height:h,sensorWidth:frame.width*2,sensorHeight:frame.height*2,
            originX:(Double(crop.activeArea[1])+crop.cropOrigin[0])/2,originY:(Double(crop.activeArea[0])+crop.cropOrigin[1])/2,
            scaleX:Double(w)/cw,scaleY:Double(h)/ch,maps:try BayerGainMap.read(frame.calibration.opcodeList2))
        result.vignette=try DNGVignette.remap(frame.calibration.opcodeList3,plan:result,geometry:frame.calibration.geometry)
        return result
    }
    func calibration(_ original:BayerCalibration)->BayerCalibration {
        var c=original
        c.geometry=DNGSensorGeometry(width:width*2,height:height*2,activeArea:[0,0,UInt32(height*2),UInt32(width*2)],cropOrigin:[0,0],cropSize:[Double(width*2),Double(height*2)])
        let operations=maps.compactMap{$0.transformed(self)}
        if operations.isEmpty { c.opcodeList2=nil }
        else {
            var count=UInt32(operations.count).bigEndian
            var data:Data=withUnsafeBytes(of:&count){Data($0)}
            for operation in operations { data.append(operation) };c.opcodeList2=data
        }
        c.opcodeList3=vignette
        // Both opcode lists now describe the reconstructed raster, not the
        // original full sensor. Gains remain in the developer's float domain.
        return c
    }
}

/// Preserve Apple's post-demosaic radial shading in extended floating point.
/// Rewriting the normalized polynomial avoids baking >1 gains into a 16-bit
/// mosaic, where bright corners would clip before the RAW developer runs.
enum DNGVignette {
    static func remap(_ data:Data?,plan:SuperResolutionPlan,geometry:DNGSensorGeometry?) throws -> Data? {
        guard let data else { return nil };_ = try DNGMetadata.validatedOpcodes(data)
        guard abs(plan.scaleX/plan.scaleY-1)<0.001 else { throw CameraFailure.message("La corrección radial necesita una escala SR uniforme.") }
        func u(_ o:Int)->Int { Int(data[o..<o+4].reduce(UInt32(0)){($0<<8)|UInt32($1)}) }
        func d(_ o:Int)->Double { Double(bitPattern:data[o..<o+8].reduce(UInt64(0)){($0<<8)|UInt64($1)}) }
        let area=geometry?.activeArea ?? [0,0,UInt32(plan.sensorHeight),UInt32(plan.sensorWidth)]
        let ow=Double(area[3]-area[1]),oh=Double(area[2]-area[0])
        let left=plan.originX*2-Double(area[1]),top=plan.originY*2-Double(area[0])
        let cw=Double(plan.width)*2/plan.scaleX,ch=Double(plan.height)*2/plan.scaleY
        var result=data,offset=4
        for _ in 0..<u(0) {
            let start=offset+16,length=u(offset+12)
            guard u(offset)==3,length==56 else { throw CameraFailure.message("Super Res no puede reinterpretar esta corrección óptica.") }
            var values:[Double]=(0..<7).map{d(start+$0*8)}
            guard values.allSatisfy(\.isFinite),values.prefix(5).allSatisfy({abs($0)<1000}),(-1...2).contains(values[5]),(-1...2).contains(values[6]) else { throw CameraFailure.message("Corrección radial no válida.") }
            let cx=values[5]*ow,cy=values[6]*oh
            let radius=hypot(max(abs(cx),abs(ow-cx)),max(abs(cy),abs(oh-cy)))
            let cropRadius=hypot(max(abs(cx-left),abs(left+cw-cx)),max(abs(cy-top),abs(top+ch-cy)))
            guard radius>0,cropRadius>0 else { throw CameraFailure.message("Radio óptico no válido.") }
            let ratio=cropRadius/radius
            for index in 0..<5 { values[index]*=pow(ratio,Double((index+1)*2)) }
            values[5]=(cx-left)/cw;values[6]=(cy-top)/ch
            for index in values.indices {
                var bits=values[index].bitPattern.bigEndian
                withUnsafeBytes(of:&bits) { result.replaceSubrange(start+index*8..<start+(index+1)*8,with:$0) }
            }
            offset=start+length
        };return result
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
