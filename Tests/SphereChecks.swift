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
        let metadata=CGImageSourceCopyMetadataAtIndex(source,0,nil)!
        try check(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:ProjectionType" as CFString) as String? == "equirectangular","JPEG has no GPano projection metadata")
        try check(CGImageMetadataCopyStringValueWithPath(metadata,nil,"GPano:FullPanoWidthPixels" as CFString) as String? == "512","GPano dimensions differ from actual file")
        var rejected=false
        do { _=try SphereProcessor().process(Array(frames.prefix(2)),width:512) } catch { rejected=true }
        try check(rejected,"Incomplete sphere was labeled complete")
    }
}
