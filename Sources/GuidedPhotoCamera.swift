import AVFoundation
import Combine
import CoreImage
import UIKit

struct GuidedPhotoFrame:Identifiable {
    let id=UUID()
    let data:Data
    var motion:SphereMotionSnapshot?=nil
    var fieldOfView:Double=70
    var exposureSeconds:Double=1.0/60
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
    private var hasFrame=false
    private var permissionToken=UUID()
    var motionProvider:(()->SphereMotionSnapshot?)?
    private var capturedMotion:SphereMotionSnapshot?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(sessionFailed(_:)),name:AVCaptureSession.wasInterruptedNotification,object:session)
        NotificationCenter.default.addObserver(self,selector:#selector(sessionFailed(_:)),name:AVCaptureSession.runtimeErrorNotification,object:session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func sessionFailed(_ notification:Notification) {
        let error=(notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
        queue.async {
            guard self.active else { return }
            self.recoveryRequired=true;self.expected=nil;self.received=nil
            if self.session.isRunning { self.session.stopRunning() }
            self.ui { self.ready=false;self.busy=false;self.status=error ?? "La sesión se interrumpió. Cierra este modo y vuelve a abrirlo; no se repetirá la captura." }
        }
    }
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
                        self.session.commitConfiguration()
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                        device.videoZoomFactor=max(1,device.minAvailableVideoZoomFactor)
                        device.setExposureTargetBias(0,completionHandler:nil)
                        if device.hasTorch { device.torchMode = .off }
                        device.unlockForConfiguration()
                        self.device=device;self.configured=true
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
            let interrupted=self.expected != nil
            self.expected=nil;self.received=nil;self.capturedMotion=nil
            if interrupted { self.recoveryRequired=true }
            if self.session.isRunning { self.session.stopRunning() }
            self.ui {
                self.ready=false;self.busy=false
                if interrupted { self.status="La captura se interrumpió. Cierra este modo y vuelve a abrirlo; no se repetirá." }
                completion()
            }
        }
    }
    func pauseForModeChange(_ completion:@escaping (Bool)->Void) {
        queue.async {
            guard self.expected==nil else { self.ui { completion(false) };return }
            self.active=false;self.permissionToken=UUID()
            if self.session.isRunning { self.session.stopRunning() }
            self.ui { self.ready=false;completion(true) }
        }
    }
    func resetSequence() {
        queue.async {
            guard !self.active,!self.session.isRunning,self.expected==nil else { return }
            self.unlockControls();self.received=nil;self.capturedMotion=nil;self.captureError=nil
            self.recoveryRequired=false;self.configured=false
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration();self.device=nil
            self.ui { self.frame=nil;self.ready=false;self.busy=false }
        }
    }
    func capture() {
        queue.async {
            guard self.active,self.session.isRunning,self.expected==nil,!self.recoveryRequired else { return }
            if !self.locked,let device=self.device,device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance {
                self.ui { self.status="Espera a que terminen el enfoque y la medición antes de añadir la primera foto." };return
            }
            do { try self.lockControls() }
            catch { self.ui { self.status=error.localizedDescription };return }
            let settings=AVCapturePhotoSettings(format:[AVVideoCodecKey:AVVideoCodecType.jpeg])
            settings.flashMode = .off;settings.photoQualityPrioritization = .balanced
            settings.maxPhotoDimensions=self.output.maxPhotoDimensions
            self.expected=settings.uniqueID;self.received=nil;self.captureError=nil
            self.capturedMotion=nil
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
    func photoOutput(_ output:AVCapturePhotoOutput,willCapturePhotoFor resolvedSettings:AVCaptureResolvedPhotoSettings) {
        let snapshot=motionProvider?()
        queue.async { if self.expected==resolvedSettings.uniqueID { self.capturedMotion=snapshot } }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings,error:Error?) {
        queue.async {
            guard self.expected==resolvedSettings.uniqueID else { return }
            let data=self.received,failure=error ?? self.captureError
            let motion=self.capturedMotion,fieldOfView=Double(self.device?.activeFormat.videoFieldOfView ?? 70)
            let exposureSeconds=self.device?.exposureDuration.seconds ?? 1.0/60
            self.received=nil
            guard failure==nil,let data else {
                self.expected=nil;if !self.hasFrame { self.unlockControls() }
                self.ui { self.busy=false;self.status=failure?.localizedDescription ?? "La cámara no entregó un JPEG." };return
            }
            self.processing.async {
                let result=Result { try autoreleasepool {
                    guard let source=CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("No se pudo leer el fotograma.") }
                    let scale=min(1,1600/max(source.extent.width,source.extent.height))
                    let image=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    return try JPEGRenderer.render(image,extent:image.extent,options:ProcessingOptions(),context:CIContext(options:[.cacheIntermediates:false]),metadataReference:data).data
                } }
                self.queue.async {
                    guard self.active,self.expected==resolvedSettings.uniqueID else { return };self.expected=nil
                    switch result {
                    case .success(let jpeg):self.hasFrame=true;self.ui { self.frame=GuidedPhotoFrame(data:jpeg,motion:motion,fieldOfView:fieldOfView,exposureSeconds:exposureSeconds);self.busy=false;self.status="Fotograma listo. Desplaza la cámara dejando la mitad de la escena en común." }
                    case .failure(let error):if !self.hasFrame { self.unlockControls() };self.ui { self.busy=false;self.status=error.localizedDescription }
                    }
                }
            }
        }
    }
    func focus(_ point:CGPoint) {
        queue.async {
            guard self.active,self.expected==nil,!self.recoveryRequired,let device=self.device else { return }
            guard !self.locked else { self.ui { self.status="Enfoque y exposición bloqueados para mantener las uniones. Empieza de nuevo para medir otro punto." };return }
            do {
                try device.lockForConfiguration();defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest=point }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest=point }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                self.ui { self.status="Enfocando y midiendo la primera vista…" }
            } catch { self.ui { self.status=error.localizedDescription } }
        }
    }
    func unlock() {
        queue.async {
            guard self.expected==nil else { return };self.unlockControls()
        }
    }
    private func lockControls() throws {
        guard !locked else { return }
        guard let d=device,d.isExposureModeSupported(.locked),d.isWhiteBalanceModeSupported(.locked) else { throw CameraFailure.message("La cámara no permite bloquear la medición para las uniones.") }
        try d.lockForConfiguration();defer { d.unlockForConfiguration() }
        d.exposureMode = .locked;d.whiteBalanceMode = .locked
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        locked=true
    }
    private func unlockControls() {
        guard let d=device,(try? d.lockForConfiguration()) != nil else { return }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        d.unlockForConfiguration();locked=false;hasFrame=false
    }
}
