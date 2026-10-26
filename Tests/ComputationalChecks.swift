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
            let values=(0..<256*192*4).map { Float16(0.18+Double($0%64)/1000).bitPattern.littleEndian }
            print("Core format: half values",values.count)
            let quadData=values.withUnsafeBufferPointer { Data(buffer:$0) }
            print("Core format: half bytes",quadData.count)
            let dng=try FusedDNG.encode(quads:quadData,width:256,height:192,calibration:calibration)
            print("Core format: DNG ImageIO reader",dng.count)
            guard let source=CGImageSourceCreateWithData(dng as CFData,[kCGImageSourceTypeIdentifierHint:"com.adobe.raw-image"] as CFDictionary),
                  let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { throw CameraFailure.message("Working DNG is unreadable") }
            try require((props[kCGImagePropertyPixelWidth as String] as? Int) != nil,"DNG properties missing")
            print("Core format: DNG developer")
            guard let decoder=CIRAWFilter(imageData:dng,identifierHint:"com.adobe.raw-image"),let image=decoder.outputImage else { throw CameraFailure.message("CIRAWFilter refused the fused working mosaic") }
            print("Developed DNG:",decoder.nativeSize,image.extent,decoder.scaleFactor)
            try require(image.extent.width==512 && image.extent.height==384,"Working mosaic did not develop")
            print("Core format: native 12MP packing")
            var sensor=[UInt16](repeating:1000,count:4032*3024)
            sensor[0]=1100;sensor[1]=1200;sensor[4032]=1300;sensor[4033]=1400
            let native=try sensor.withUnsafeBufferPointer { try BayerQuadPacking.pack($0,rowElements:4032,originX:0,originY:0,cropWidth:4032,cropHeight:3024,step:1,black:[100,100,100,100],white:16000) }
            try require(native.count==4032*3024*2,"Native Bayer data was downsampled")
            try native.withUnsafeBytes { bytes in
                for phase in 0..<4 {
                    let value=Float(Float16(bitPattern:bytes.loadUnaligned(fromByteOffset:phase*2,as:UInt16.self)))
                    try require(abs(value-Float(1000+phase*100)/15900)<0.0001,"Bayer phase or black normalization mismatch")
                }
            }
            let mapped=try BayerScratchStorage.store(native)
            mapped.storage.discardResidentPages()
            try require(mapped.data==native,"Mapped burst payload changed after page discard")
            let nativeDNG=try FusedDNG.encode(quads:mapped.data,width:2016,height:1512,calibration:calibration)
            guard let nativeSource=CGImageSourceCreateWithData(nativeDNG as CFData,[kCGImageSourceTypeIdentifierHint:"com.adobe.raw-image"] as CFDictionary),
                  let nativeProps=CGImageSourceCopyPropertiesAtIndex(nativeSource,0,nil) as? [String:Any] else { throw CameraFailure.message("Native DNG unreadable") }
            try require((nativeProps[kCGImagePropertyPixelWidth as String] as? Int) != nil,"Native DNG properties missing")
            guard let nativeDecoder=CIRAWFilter(imageData:nativeDNG,identifierHint:"com.adobe.raw-image"),let nativeImage=nativeDecoder.outputImage else { throw CameraFailure.message("Native Bayer DNG did not develop") }
            try require(nativeImage.extent.width==4032 && nativeImage.extent.height==3024,"Native DNG lost 12MP geometry")
            print("Computational source checks passed; no capture session, app launch or GPU execution.")
        } catch { fputs("\(error)\n",stderr);exit(1) }
    }
}
