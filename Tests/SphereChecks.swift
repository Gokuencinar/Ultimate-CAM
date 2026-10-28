import CoreImage
import ImageIO
import Foundation
import Darwin
import simd

@main struct SphereChecks {
    static func check(_ condition:Bool,_ text:String) throws { if !condition { throw CameraFailure.message(text) } }
    static func main() {
        do { try run();print("SPHERE CHECKS PASSED · synthetic poses, projection, coverage and actual GPano metadata; no hardware") }
        catch { fputs("SPHERE CHECK FAILED: \(error)\n",stderr);exit(1) }
    }
    static func run() throws {
        try checkRealignment()
        let completed=Set(0..<22),remaining=SphereTarget.all[22]
        try check(SphereNodeSelection.next(captured:completed,direction:remaining.direction)?.id==22,"Sphere target disappeared after the 22nd view")
        try check(SphereNodeSelection.next(captured:Set(0..<62),direction:remaining.direction)==nil,"Completed sphere still suggests a view")
        let fov=CaptureProjection.longSideFOV(equivalent35mm:26,aspect:4.0/3)!
        try check(fov>66 && fov<69,"Portrait capture incorrectly uses the full-frame width for its diagonal equivalent")
        try checkMeridianBlend()
        try checkTiltedCapture()
        let upright=simd_float3x3(simd_quatf(angle:Float.pi/2,axis:SIMD3(1,0,0)))
        let down=SIMD3<Float>(0,0,-1)
        let initial=SphereMotionSnapshot(rotation:upright,gravity:upright.transpose*down,rotationSpeed:0,timestamp:1)
        let reference=try SphereReference(initial)
        try check(simd_length(try reference.pose(initial).forward-SIMD3(0,0,1))<0.001,"First camera view is not relative heading zero")
        let turned=simd_float3x3(simd_quatf(angle:-Float.pi/2,axis:SIMD3(0,0,1)))*upright
        let right=try reference.pose(SphereMotionSnapshot(rotation:turned,gravity:turned.transpose*down,rotationSpeed:0,timestamp:2))
        try check(simd_length(right.forward-SIMD3(1,0,0))<0.001,"Right turn changed pitch or reversed heading")
        let inverse=SphereMotionSnapshot(rotation:upright.transpose,gravity:initial.gravity,rotationSpeed:0,timestamp:1)
        try check(simd_length(try SphereReference(inverse).pose(inverse).forward-SIMD3(0,0,1))<0.001,"Gravity could not disambiguate matrix convention")
        try check(SphereTarget.all.count==62 && Set(SphereTarget.all.map(\.id)).count==62,"Sphere grid duplicated target IDs")
        let context=CIContext(options:[.useSoftwareRenderer:true]),space=CGColorSpace(name:CGColorSpace.sRGB)!
        let directions:[SIMD3<Float>]=[SIMD3(0,0,1),SIMD3(1,0,0),SIMD3(-1,0,0),SIMD3(0,0,-1),SIMD3(0,1,0),SIMD3(0,-1,0)]
        let colors:[CIColor]=[.red,.green,.blue,.yellow,.magenta,.cyan]
        var frames=[SphereImageFrame]()
        for (index,forward) in directions.enumerated() {
            let seed:SIMD3<Float>=abs(forward.y)>0.9 ? SIMD3(0,0,1):SIMD3(0,1,0)
            let right=simd_normalize(simd_cross(seed,forward)),up=simd_normalize(simd_cross(forward,right))
            let matrix=simd_float3x3(columns:(SIMD3(right.x,up.x,-forward.x),SIMD3(right.y,up.y,-forward.y),SIMD3(right.z,up.z,-forward.z)))
            let image=CIImage(color:colors[index]).cropped(to:CGRect(x:0,y:0,width:128,height:128))
            let data=context.pngRepresentation(of:image,format:.RGBA8,colorSpace:space)!
            frames.append(SphereImageFrame(data:data,pose:SpherePose(sphereToDevice:matrix,forward:forward),fieldOfView:110))
        }
        let result=try SphereProcessor().process(frames,width:512)
        let source=CGImageSourceCreateWithData(result.jpeg as CFData,nil)!
        let cg=CGImageSourceCreateImageAtIndex(source,0,nil)!
        try check(cg.width==512 && cg.height==256,"Sphere output is not equirectangular 2:1")
        let image=CIImage(cgImage:cg)
        func sample(_ x:Int,_ y:Int) -> [Float] {
            var values=[Float](repeating:0,count:4)
            values.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:space) }
            return values
        }
        let front=sample(256,128),rightColor=sample(384,128),left=sample(128,128)
        try check(front[0]>0.9 && front[1]<0.1 && rightColor[1]>0.9 && rightColor[0]<0.1 && left[2]>0.9,"Projection rotated or reflected camera directions")
        let viewer=SphereViewerRenderer()
        func viewSample(_ yaw:Double,_ pitch:Double) throws -> [Float] {
            let frame=try viewer.render(cg,yaw:yaw,pitch:pitch,fieldOfView:70,width:128,height:80)
            var values=[Float](repeating:0,count:4)
            values.withUnsafeMutableBytes { context.render(CIImage(cgImage:frame),toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:64,y:40,width:1,height:1),format:.RGBAf,colorSpace:space) }
            return values
        }
        let vFront=try viewSample(0,0),vRight=try viewSample(Double.pi/2,0),vUp=try viewSample(0,Double.pi/2),vDown=try viewSample(0,-Double.pi/2)
        try check(vFront[0]>0.9 && vFront[1]<0.1 && vRight[1]>0.9 && vRight[0]<0.1,"360 viewer heading is reflected or offset")
        try check(vUp[0]>0.9 && vUp[2]>0.9 && vUp[1]<0.1 && vDown[0]<0.1 && vDown[1]>0.9 && vDown[2]>0.9,"360 viewer flipped the poles")
        let seamA=try viewSample(Double.pi-0.001,0),seamB=try viewSample(-Double.pi+0.001,0)
        try check(zip(seamA,seamB).allSatisfy { abs($0-$1)<0.02 } && seamA[0]>0.9 && seamA[1]>0.9,"360 viewer exposes a gap at the longitude seam")
        let metadata=CGImageSourceCopyMetadataAtIndex(source,0,nil)!
        try check(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:ProjectionType" as CFString) as String? == "equirectangular","JPEG has no GPano projection metadata")
        try check(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:FullPanoWidthPixels" as CFString) as String? == "512","GPano dimensions differ from actual file")
        let partial=try SphereProcessor().process(Array(frames.prefix(4)),width:512)
        guard let partialImage=PreviewDecoder.image(partial.jpeg,maximumDimension:512) else { throw CameraFailure.message("Partial sphere produced no JPEG") }
        try check(partialImage.width==512 && partialImage.height==256 && partial.details.contains("parcial"),"Four-view sphere failed 2:1 geometry / honest coverage")
        var point=[Float](repeating:0,count:4)
        point.withUnsafeMutableBytes { context.render(CIImage(cgImage:partialImage),toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:256,y:255,width:1,height:1),format:.RGBAf,colorSpace:space) }
        try check(point[0]+point[1]+point[2]>0.08 && point.allSatisfy(\.isFinite),"Partial sphere left uncovered sky black/invalid")
        let aimed=try reference.pose(initial)
        let node=SphereNodeSelection.completedTarget(planned:0,pose:aimed,first:true)
        try check(node==0,"Captured reticle did not complete its reserved node")
        let after=try? SphereAim.make(initial,reference:reference,captured:[0],now:1.1)
        try check(after==nil || after?.target.id != node,"Completed node was targeted twice")
        for target in SphereTarget.all {
            let p=SphereNodeSelection.point(yaw:Double(target.yaw),pitch:Double(target.pitch),size:CGSize(width:375,height:110))
            try check(p.x>=12 && p.x<=363 && p.y>=12 && p.y<=98,"A sphere map node touches a clipped border")
        }
        let positions=SphereTarget.all.map { SphereNodeSelection.point(yaw:Double($0.yaw),pitch:Double($0.pitch),size:CGSize(width:375,height:110)).x/375 }
        try check(positions.filter{$0<0.499}.count==30 && positions.filter{$0>0.501}.count==30,"62-node banner does not span both halves symmetrically")
        try check(abs(positions.reduce(0,+)/62-0.5)<0.00001 && abs(positions.min()!+positions.max()!-1)<0.00001,"Sphere banner is offset from its container centre")
        let frozen=SphereCaptureOrientation.resolve(captured:nil,atShutter:aimed,target:SphereTarget.all[0])
        try check(SphereCaptureOrientation.valid(frozen) && simd_length(frozen.forward-aimed.forward)<0.0001,"A missing callback attitude lost the shutter orientation")
        for target in SphereTarget.all {
            let fallback=SphereCaptureOrientation.resolve(captured:nil,atShutter:nil,target:target)
            try check(SphereCaptureOrientation.valid(fallback) && simd_length(fallback.forward-target.direction)<0.0001,"Reserved node did not supply a valid relative orientation")
            try check(SphereNodeSelection.completedTarget(planned:target.id,pose:fallback,first:false)==target.id,"Fallback orientation did not complete its reserved node")
        }
        let screen=SphereNodeSelection.projected(SphereTarget.all[0],pose:aimed,size:CGSize(width:375,height:812))
        try check(screen != nil && abs(screen!.x-187.5)<0.01 && abs(screen!.y-406)<0.01,"Sphere target projection disagrees with the portrait reticle")
        var gate=SphereAutoCaptureGate()
        try check(!gate.update(target:0,stable:true,time:1) && !gate.update(target:0,stable:true,time:1.39) && gate.update(target:0,stable:true,time:1.4),"Auto sphere ignored the 0.4 second dwell")
        _=gate.update(target:1,stable:true,time:2);_=gate.update(target:1,stable:false,time:2.3)
        try check(!gate.update(target:1,stable:true,time:2.4),"Unstable aim retained an automatic capture")
        var rejected=false
        do { _=try SphereProcessor().process(Array(frames.prefix(2)),width:512,minimumCoverage:0.995) } catch { rejected=true }
        try check(rejected,"Incomplete sphere was labeled complete")
    }
    static func checkRealignment() throws {
        let w=512,h=256,e=CGRect(x:0,y:0,width:w,height:h)
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        var seed:UInt32=213,values=[Float](repeating:1,count:w*h*4)
        for i in 0..<w*h {
            seed=seed &* 1664525 &+ 1013904223
            let v=Float(20+(seed>>24)%200)/255
            for c in 0..<3 { values[i*4+c]=v }
        }
        let a=CIImage(bitmapData:values.withUnsafeBufferPointer{Data(buffer:$0)},bytesPerRow:w*16,size:e.size,format:.RGBAf,colorSpace:space)
            .clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1]).cropped(to:e)
        let b=a.transformed(by:CGAffineTransform(translationX:5,y:-2)),cover=CIImage(color:.white).cropped(to:e)
        let delta=try SphereProcessor().alignment(b,coverage:cover,reference:a,referenceCoverage:cover,width:w)
        try check(delta != nil && abs(delta!.x+5)<0.8 && abs(delta!.y-2)<0.8,"Sphere visual drift correction failed its measured overlap")
        let pose=SphereCaptureOrientation.resolve(captured:nil,atShutter:nil,target:SphereTarget.all[0])
        let corrected=pose.corrected(yaw:0.05,pitch:0.02)
        try check(SphereCaptureOrientation.valid(corrected) && corrected.forward.x>0.04 && corrected.forward.y>0.015,"Pose correction inverted camera axes")
    }
    static func checkMeridianBlend() throws {
        let w=256,h=128,e=CGRect(x:0,y:0,width:w,height:h),space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(options:[.workingColorSpace:space])
        var a=[Float](repeating:1,count:w*h*4),b=a,aw=a,bw=a
        for y in 0..<h { for x in 0..<w {
            let angle=2*Float.pi*(Float(x)+0.5)/Float(w),v:Float=0.3+0.06*cos(angle)+0.04*sin(Float(y)*0.13)
            for c in 0..<3 {
                let j=(y*w+x)*4+c;a[j]=v;b[j]=v*0.6
                aw[j]=(x<44 || x>=212) ? 0:1;bw[j]=(x<80 || x>=176) ? 1:0
                // A moved object at the wrapped overlap must be avoided too.
                if x>=184 && x<198 && y>42 && y<82 { b[j]+=0.15 }
            }
        } }
        func image(_ p:[Float])->CIImage { CIImage(bitmapData:p.withUnsafeBufferPointer{Data(buffer:$0)},bytesPerRow:w*16,size:e.size,format:.RGBAf,colorSpace:space) }
        let result=try MultiBandStitcher.blend(image(a),coverage:image(aw),image(b),coverage:image(bw),extent:e,context:context,wrapX:true)
        var out=a
        out.withUnsafeMutableBytes { context.render(result.image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:e,format:.RGBAf,colorSpace:space) }
        var before=0.0,after=0.0,seamError=0.0
        for y in 4..<h-4 { for x in 0..<w {
            let j=(y*w+x)*4
            let moving=x>=184 && x<198 && y>42 && y<82
            if !moving { before+=pow(Double(b[j]-a[j]),2);after+=pow(Double(out[j]-a[j]),2) }
            if x==0 { seamError+=abs(Double(out[j]-out[(y*w+w-1)*4])) }
        } }
        print("Sphere wrapped gain",result.gain,"join error ratio",after/before,"meridian discontinuity",seamError/Double(h-8))
        try check(after<before*0.1,"Wrapped sphere gain / multiband did not improve exposure continuity")
        try check(seamError/Double(h-8)<0.003,"Multiband join opened the longitude meridian")
    }

    static func checkTiltedCapture() throws {
        let down=SIMD3<Float>(0,0,-1)
        let tilted=simd_float3x3(simd_quatf(angle:Float.pi/3,axis:SIMD3(1,0,0)))
        let sample=SphereMotionSnapshot(rotation:tilted,gravity:tilted.transpose*down,rotationSpeed:0.2,timestamp:10)
        let aim=try SphereAim.make(sample,reference:nil,captured:[],now:10.1)
        try check(abs(aim.target.pitch+30)<0.01,"A tilted first view was disabled or assigned to the wrong sphere row")
        try check(SphereAim.acceptsMotion(sample,seconds:0.001,fieldOfView:70),"Brief exposure rejected harmless finger motion")
        try check(!SphereAim.acceptsMotion(sample,seconds:0.5,fieldOfView:70),"Long blurred sphere exposure was accepted")
        var staleAccepted=false
        do { _=try SphereAim.make(sample,reference:nil,captured:[],now:11);staleAccepted=true } catch { }
        try check(!staleAccepted,"Stale IMU data was assigned to a new view")
        let upright=simd_float3x3(simd_quatf(angle:Float.pi/2,axis:SIMD3(1,0,0)))
        let opposite=simd_float3x3(simd_quatf(angle:Float.pi,axis:SIMD3(0,0,1)))*upright
        let first=SphereMotionSnapshot(rotation:opposite,gravity:opposite.transpose*down,rotationSpeed:0,timestamp:1)
        let direct=try SphereReference(first)
        let inverse=try SphereReference(SphereMotionSnapshot(rotation:opposite.transpose,gravity:first.gravity,rotationSpeed:0,timestamp:1))
        let turn=simd_float3x3(simd_quatf(angle:Float.pi+0.5,axis:SIMD3(0,0,1)))*upright
        // Learn convention away from the symmetric first orientation, retain
        // it at the poles where gravity cannot resolve heading/roll alone.
        for (i,m) in [turn,simd_float3x3(simd_quatf(angle:0.8,axis:SIMD3(0,0,1)))].enumerated() {
            let g=m.transpose*down
            let a=try direct.pose(SphereMotionSnapshot(rotation:m,gravity:g,rotationSpeed:0,timestamp:Double(i+2)))
            let b=try inverse.pose(SphereMotionSnapshot(rotation:m.transpose,gravity:g,rotationSpeed:0,timestamp:Double(i+2)))
            for c in 0..<3 { try check(simd_length(a.sphereToDevice[c]-b.sphereToDevice[c])<0.001,"Matrix convention flipped sphere roll at a pole") }
        }
        print("TILTED / 180-DEGREE / POLAR SPHERE CAPTURE CHECKS PASSED")
    }

}
