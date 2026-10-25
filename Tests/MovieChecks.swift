import AVFoundation
import CoreVideo
import Foundation
import Darwin

@main struct MovieChecks {
    static func check(_ condition:Bool,_ message:String) throws { if !condition { throw CameraFailure.message(message) } }
    static func main() async {
        do { try await run();print("MOVIE CHECKS PASSED · state, formats and a real synthetic MOV; no device recording") }
        catch { fputs("MOVIE CHECK FAILED: \(error)\n",stderr);exit(1) }
    }
    static func run() async throws {
        var state=MovieRecordingState()
        try check(!state.stop() && state.beginSave()==nil,"Idle operation accepted")
        let first=state.begin()!
        try check(state.busy && state.begin()==nil && !state.discard(),"Concurrent recording or discard accepted")
        try check(!state.finished(UUID(),valid:true),"Stale recording delegate accepted")
        try check(state.stop() && !state.stop(),"Stop is not idempotent")
        try check(state.finished(first,valid:true) && state.phase == .review,"Recording did not reach review")
        try check(!state.finished(first,valid:false),"Repeated finalization changed review")
        let save=state.beginSave()!
        try check(state.beginSave()==nil && !state.discard() && !state.saved(UUID()),"Save transaction overlap accepted")
        try check(state.saved(save) && state.discard(),"Save/discard did not release the recording")
        let second=state.begin()!
        try check(!state.finished(first,valid:true) && state.finished(second,valid:false) && state.phase == .idle,"Stale completion corrupted the next recording")
        try check(state.recover() && !state.recover() && state.discard(),"Recovery state not exclusive")
        var config=MovieConfiguration()
        try check(config.matches(width:1920,height:1080,ranges:[24...60]),"Supported format rejected")
        try check(!config.matches(width:3840,height:2160,ranges:[24...60]),"Wrong resolution accepted")
        config.fps=60
        try check(!config.matches(width:1920,height:1080,ranges:[24...30]),"Unsupported frame rate accepted")
        try check(try JSONDecoder().decode(MovieConfiguration.self,from:JSONEncoder().encode(config))==config,"Video configuration serialization changed values")
        config.fps=120
        do { _=try config.validated();throw CameraFailure.message("Invalid FPS accepted") }
        catch CameraFailure.message(let text) where text != "Invalid FPS accepted" { }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("synthetic.mov")
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:48])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,
            sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:48])
        writer.add(input);try check(writer.startWriting(),"Cannot start synthetic writer");writer.startSession(atSourceTime:.zero)
        for frame in 0..<30 {
            let deadline=Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
            try check(input.isReadyForMoreMediaData,"Synthetic writer stalled")
            var pixel:CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault,64,48,kCVPixelFormatType_32BGRA,nil,&pixel)==kCVReturnSuccess,"Cannot create pixel buffer")
            CVPixelBufferLockBaseAddress(pixel!,[])
            let bytes=CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(pixel!)
            for y in 0..<48 { for x in 0..<64 {
                bytes[y*stride+x*4]=UInt8(x*4);bytes[y*stride+x*4+1]=UInt8(y*5);bytes[y*stride+x*4+2]=UInt8(frame*8);bytes[y*stride+x*4+3]=255
            } }
            CVPixelBufferUnlockBaseAddress(pixel!,[])
            try check(adaptor.append(pixel!,withPresentationTime:CMTime(value:Int64(frame),timescale:30)),"Synthetic frame append failed")
        }
        input.markAsFinished();await writer.finishWriting()
        try check(writer.status == .completed,"Synthetic MOV could not finish")
        let result=try await MovieRecordedAsset.inspect(url)
        try check(result.width==64 && result.height==48 && result.duration>0.9 && result.duration<1.1 && result.bytes>100,"Production movie validator read wrong metadata")
        let bad=directory.appendingPathComponent("broken.mov");try Data("not a movie".utf8).write(to:bad)
        do { _=try await MovieRecordedAsset.inspect(bad);throw CameraFailure.message("Corrupt movie accepted") }
        catch CameraFailure.message(let text) where text == "Corrupt movie accepted" { throw CameraFailure.message(text) }
        catch { }
    }
}
