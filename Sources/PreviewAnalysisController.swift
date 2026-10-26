import AVFoundation
import CoreImage
import UIKit

struct PreviewAnalysisFrame {
    let metrics:PreviewLumaMetrics
    let overlay:CGImage?
    let color:CGImage?
    let notice:String?
}

final class PreviewAnalysisController:NSObject,AVCaptureVideoDataOutputSampleBufferDelegate {
    let output=AVCaptureVideoDataOutput()
    let history=TemporalFrameBuffer<CGImage>()
    let motion=PreviewMotionMeter()
    private var previousBufferTime=0.0
    private var buffering=false
    private var motionEnabled=false
    private var lastPTS=Double.nan
    private let queue=DispatchQueue(label:"com.gokuencinar.ultimatecam.preview-analysis",qos:.utility)
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let lock=NSLock()
    private var active=false
    private var generation=UUID()
    private var configurationGeneration=UUID()
    private var configurationReady=false
    private var deliveryPending=false
    private var options=PreviewAnalysisOptions()
    private var recipe:CubeLUT?
    private var customLUT:CubeLUT?
    private var processing=ProcessingOptions()
    private var notice:String?
    private var previousTime:CFTimeInterval=0
    private let completion:(PreviewAnalysisFrame?)->Void
    init(completion:@escaping (PreviewAnalysisFrame?)->Void) {
        self.completion=completion;super.init()
        output.alwaysDiscardsLateVideoFrames=true
        output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.automaticallyConfiguresOutputBufferDimensions=false
        output.deliversPreviewSizedOutputBuffers=true
        output.setSampleBufferDelegate(self,queue:queue)
    }
    func setActive(_ value:Bool) {
        lock.lock();active=value;generation=UUID();lock.unlock()
        if !value { history.reset();motion.reset();DispatchQueue.main.async { self.completion(nil) } }
    }
    func configure(_ options:PreviewAnalysisOptions,processing:ProcessingOptions) {
        lock.lock();generation=UUID();let token=generation;configurationGeneration=token;configurationReady=false;lock.unlock()
        queue.async {
            self.lock.lock();let valid=self.configurationGeneration==token;self.lock.unlock()
            guard valid else { return }
            self.options=options;self.previousTime=0
            self.processing=processing;self.notice=nil
            self.buffering=processing.zeroShutterLagFusion
            self.motionEnabled=processing.nightStatic && processing.nightMotionMetering
            self.history.reset();self.motion.reset();self.previousBufferTime=0;self.lastPTS = .nan
            do {
                self.recipe=options.colorLook && processing.color.needsCube ? try ColorRecipeLUT.make(processing.color) : nil
                self.customLUT=options.colorLook ? try processing.lutID.map { try ColorLUTStore.load($0) } : nil
            } catch { self.recipe=nil;self.customLUT=nil;self.notice="Vista de color: \(error.localizedDescription)" }
            self.lock.lock();if self.configurationGeneration==token { self.configurationReady=true };self.lock.unlock()
            DispatchQueue.main.async { self.lock.lock();let valid=self.generation==token;self.lock.unlock();if valid { self.completion(nil) } }
        }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        lock.lock();let enabled=active && configurationReady,token=generation,pending=deliveryPending;lock.unlock()
        guard enabled,let pixel=CMSampleBufferGetImageBuffer(sampleBuffer),CVPixelBufferGetPlaneCount(pixel)>0 else { return }
        let host=ProcessInfo.processInfo.systemUptime
        if (buffering || motionEnabled) && host-previousBufferTime>=1.0/15 {
            previousBufferTime=host
            let pts=CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if !pts.isFinite || (lastPTS.isFinite && pts<=lastPTS) { history.reset();motion.reset() }
            lastPTS=pts
            if pts.isFinite {
                let image=CIImage(cvPixelBuffer:pixel)
                if motionEnabled {
                    let thumbnail=image.transformed(by:CGAffineTransform(scaleX:64/image.extent.width,y:48/image.extent.height))
                    var values=[Float](repeating:0,count:64*48*4)
                    values.withUnsafeMutableBytes { context.render(thumbnail,toBitmap:$0.baseAddress!,rowBytes:64*16,bounds:CGRect(x:0,y:0,width:64,height:48),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) }
                    lock.lock()
                    if active && generation==token { motion.append((0..<64*48).map { values[$0*4]*0.2126+values[$0*4+1]*0.7152+values[$0*4+2]*0.0722 },time:host) }
                    lock.unlock()
                }
                if buffering {
                    let scale=min(1,1280/max(image.extent.width,image.extent.height))
                    let small=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    if let copy=context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) {
                        // setActive(false) may have raced this render; never
                        // repopulate a previous lens/session after invalidation.
                        lock.lock();let valid=active && generation==token
                        if valid { history.append(copy,time:host,bytes:copy.bytesPerRow*copy.height) };lock.unlock()
                    }
                }
            }
        }
        guard !pending,options.enabled,CACurrentMediaTime()-previousTime>=0.2 else { return }
        previousTime=CACurrentMediaTime()
        let type=CVPixelBufferGetPixelFormatType(pixel)
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(type) else { return }
        CVPixelBufferLockBaseAddress(pixel,.readOnly)
        let width=CVPixelBufferGetWidthOfPlane(pixel,0),height=CVPixelBufferGetHeightOfPlane(pixel,0),stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,0)
        guard let address=CVPixelBufferGetBaseAddressOfPlane(pixel,0) else { CVPixelBufferUnlockBaseAddress(pixel,.readOnly);return }
        let metrics=PreviewLumaAnalyzer.measure(UnsafeBufferPointer(start:address.assumingMemoryBound(to:UInt8.self),count:stride*height),
            width:width,height:height,rowBytes:stride,videoRange:type==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,options:options)
        CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
        guard let metrics else { return }
        let overlay:CGImage?
        if options.peaking || options.zebras,let provider=CGDataProvider(data:metrics.overlayRGBA as CFData) {
            overlay=CGImage(width:metrics.width,height:metrics.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:metrics.width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        } else { overlay=nil }
        var color:CGImage?
        var message=notice
        if options.colorLook && notice==nil {
            let image=CIImage(cvPixelBuffer:pixel)
            let scale=min(1,720/max(image.extent.width,image.extent.height))
            let small=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            do {
                let result=try JPEGRenderer.finish(small,options:processing,colorTable:recipe,customTable:customLUT)
                color=context.createCGImage(result,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                if color==nil { message="No se pudo renderizar la vista de color." }
            } catch { message=error.localizedDescription }
        }
        let frame=PreviewAnalysisFrame(metrics:metrics,overlay:overlay,color:color,notice:message)
        lock.lock();deliveryPending=true;lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock();let valid=self.active && self.generation==token;self.deliveryPending=false;self.lock.unlock()
            if valid { self.completion(frame) }
        }
    }
}
