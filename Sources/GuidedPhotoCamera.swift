import AVFoundation
import Combine
import CoreImage
import UIKit

struct GuidedPhotoFrame:Identifiable {
    let id=UUID()
    let data:Data
}

/// One explicitly requested JPEG at a time for guided captures. No automatic
/// sweep, retries, PhotoKit writes or background shutter requests.
final class GuidedPhotoCamera:NSObject,ObservableObject,AVCapturePhotoCaptureDelegate {
    let session=AVCaptureSession()
    @Published private(set) var ready=false
    @Published private(set) var busy=false
    @Published private(set) var status="Preparando captura guiada…"
    @Published private(set) var frame:GuidedPhotoFrame?
    private let queue=DispatchQueue(label:"com.gokuencinar.ultimatecam.guided-photo",qos:.userInitiated)
    private let processing=DispatchQueue(label:"com.gokuencinar.ultimatecam.guided-photo-decode",qos:.userInitiated)
    private let output=AVCapturePhotoOutput()
    private var device:AVCaptureDevice?
    private var configured=false
    private var active=false
    private var expected:Int64?
    private var received:Data?
    private var captureError:Error?
    private var recoveryRequired=false
    private var locked=false
    private var permissionToken=UUID()
    private func ui(_ body:@escaping ()->Void) { DispatchQueue.main.async(execute:body) }
    func start() {
        queue.async {
            self.active=true;let token=UUID();self.permissionToken=token
            AVCaptureDevice.requestAccess(for:.video) { granted in self.queue.async {
                guard self.active,self.permissionToken==token,!self.recoveryRequired else { return }
                guard granted else { self.ui { self.status="Permite el acceso a Cámara en Ajustes." };return }
                do {
                    if !self.configured {
                        guard let device=CameraLens.wide.device else { throw CameraFailure.message("No hay cámara principal disponible.") }
                        let input=try AVCaptureDeviceInput(device:device)
                        self.session.beginConfiguration();self.session.sessionPreset = .photo
                        guard self.session.canAddInput(input),self.session.canAddOutput(self.output) else { self.session.commitConfiguration();throw CameraFailure.message("No se pudo configurar la captura guiada.") }
                        self.session.addInput(input);self.session.addOutput(self.output)
                        self.output.maxPhotoQualityPrioritization = .balanced
                        if let dimensions=device.activeFormat.supportedMaxPhotoDimensions.filter({Int64($0.width)*Int64($0.height)<=12_500_000}).max(by:{Int64($0.width)*Int64($0.height)<Int64($1.width)*Int64($1.height)}) {
                            self.output.maxPhotoDimensions=dimensions
                        }
                        if let connection=self.output.connection(with:.video),connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle=90 }
                        self.session.commitConfiguration();self.device=device;self.configured=true
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.ui { self.ready=true;self.status="Cámara principal · mantén la misma posición y solapa cada foto." }
                } catch { self.ui { self.status=error.localizedDescription } }
            } }
        }
    }
    func stop(completion:@escaping ()->Void = {}) {
        queue.async {
            self.active=false;self.permissionToken=UUID()
            if self.session.isRunning { self.session.stopRunning() }
            self.ui { self.ready=false;completion() }
        }
    }
    func capture() {
        queue.async {
            guard self.active,self.session.isRunning,self.expected==nil,!self.recoveryRequired else { return }
            let settings=AVCapturePhotoSettings(format:[AVVideoCodecKey:AVVideoCodecType.jpeg])
            settings.flashMode = .off;settings.photoQualityPrioritization = .balanced
            settings.maxPhotoDimensions=self.output.maxPhotoDimensions
            self.expected=settings.uniqueID;self.received=nil;self.captureError=nil
            let id=settings.uniqueID;self.ui { self.busy=true;self.status="Capturando fotograma…" }
            self.output.capturePhoto(with:settings,delegate:self)
            self.queue.asyncAfter(deadline:.now()+30) {
                guard self.expected==id else { return }
                self.expected=nil;self.recoveryRequired=true
                if self.session.isRunning { self.session.stopRunning() }
                self.ui { self.ready=false;self.busy=false;self.status="La cámara no respondió. Cierra este modo para recuperarla; no se repetirá la captura." }
            }
        }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishProcessingPhoto photo:AVCapturePhoto,error:Error?) {
        let data=photo.fileDataRepresentation(),id=photo.resolvedSettings.uniqueID
        queue.async { guard self.expected==id else { return };self.received=data;self.captureError=error }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings,error:Error?) {
        queue.async {
            guard self.expected==resolvedSettings.uniqueID else { return }
            let data=self.received,failure=error ?? self.captureError
            self.received=nil
            guard failure==nil,let data else {
                self.expected=nil;self.ui { self.busy=false;self.status=failure?.localizedDescription ?? "La cámara no entregó un JPEG." };return
            }
            if !self.locked,let d=self.device,(try? d.lockForConfiguration()) != nil {
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                d.unlockForConfiguration();self.locked=true
            }
            self.processing.async {
                let result=Result { try autoreleasepool {
                    guard let source=CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("No se pudo leer el fotograma.") }
                    let scale=min(1,1600/max(source.extent.width,source.extent.height))
                    let image=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    return try JPEGRenderer.render(image,extent:image.extent,options:ProcessingOptions(),context:CIContext(options:[.cacheIntermediates:false])).data
                } }
                self.queue.async {
                    guard self.expected==resolvedSettings.uniqueID else { return };self.expected=nil
                    switch result {
                    case .success(let jpeg):self.ui { self.frame=GuidedPhotoFrame(data:jpeg);self.busy=false;self.status="Fotograma listo. Desplaza la cámara dejando la mitad de la escena en común." }
                    case .failure(let error):self.ui { self.busy=false;self.status=error.localizedDescription }
                    }
                }
            }
        }
    }
    func unlock() {
        queue.async {
            guard self.expected==nil,let d=self.device,(try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            d.unlockForConfiguration();self.locked=false
        }
    }
}
