import CoreImage
import Foundation
import ImageIO
import Darwin

@main struct ComputationalChecks {
    static func require(_ condition:Bool,_ message:String) throws {
        if !condition { throw CameraFailure.message(message) }
    }
    static func main() {
        setbuf(stdout,nil)
        do {
            print("Core format: bounded ring")
            let ring=TemporalFrameBuffer<Int>(capacity:4,maximumBytes:10)
            ring.append(1,time:1,bytes:4);ring.append(2,time:1.1,bytes:4);ring.append(3,time:1.2,bytes:4)
            try require(ring.snapshot(at:1.15).map(\.value)==[2],"Pre-shutter ownership/budget failed")
            try require(ring.snapshot(at:2).isEmpty,"Expired frames survived")
            ring.append(4,time:1.05,bytes:4)
            try require(ring.snapshot(at:1.1).map(\.value)==[4],"Clock regression mixed capture generations")
            ring.reset();try require(ring.snapshot(at:2).isEmpty,"Reset retained frames")
            print("Core format: motion")
            let meter=PreviewMotionMeter()
            meter.append([Float](repeating:0.2,count:64*48),time:1)
            meter.append([Float](repeating:0.2,count:64*48),time:1.1)
            try require(meter.estimate(at:1.2)==nil,"Textureless metering claimed stability")
            print("Core format: exposure")
            let plan=try NightCapturePlan.make(iso:400,seconds:1.0/30,isoRange:25...6400,durationRange:0.0001...1,budget:8,shutterLimit:1,motionLimit:1.0/250)
            try require(plan.seconds<=1.0/250 && plan.count<=16,"Motion cap did not constrain night exposure")
            var options=ProcessingOptions();options.zeroShutterLagFusion=true;options.nightStatic=true;options.nightRAW=true;options.nightMetalRAW=true
            try require(try JSONDecoder().decode(ProcessingOptions.self,from:JSONEncoder().encode(options))==options,"New recipe fields did not persist")
            _=try options.validated()
            options.nightRAW=false
            var refused=false;do { _=try options.validated() } catch { refused=true }
            try require(refused,"Metal accepted a non-RAW recipe")
            print("Core format: DNG writer")
            let calibration=BayerCalibration(pattern:[0,1,1,2],matrix:[3.2406,-1.5372,-0.4986,-0.9689,1.8758,0.0415,0.0557,-0.204,1.057],neutral:[1,1,1],illuminant:21,orientation:1)
            let values=(0..<64*48*4).map { Float16(0.18+Double($0%64)/1000).bitPattern.littleEndian }
            let dng=try FusedDNG.encode(quads:values.withUnsafeBufferPointer { Data(buffer:$0) },width:64,height:48,calibration:calibration)
            print("Core format: DNG ImageIO reader",dng.count)
            guard let source=CGImageSourceCreateWithData(dng as CFData,nil),
                  let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { throw CameraFailure.message("Working DNG is unreadable") }
            try require((props[kCGImagePropertyPixelWidth as String] as? Int)==128 && (props[kCGImagePropertyPixelHeight as String] as? Int)==96,"Working DNG geometry was lost")
            print("Core format: DNG developer")
            guard let decoder=CIRAWFilter(imageData:dng,identifierHint:"com.adobe.raw-image"),let image=decoder.outputImage else { throw CameraFailure.message("CIRAWFilter refused the fused working mosaic") }
            try require(image.extent.width>0 && image.extent.height>0,"Working mosaic did not develop")
            print("Computational source checks passed; no capture session, app launch or GPU execution.")
        } catch { fputs("\(error)\n",stderr);exit(1) }
    }
}
