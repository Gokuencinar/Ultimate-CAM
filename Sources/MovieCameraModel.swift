import AVFoundation
import CoreVideo
import VideoToolbox
import Combine
import Photos
import UIKit

/// A movie session handed to CameraView's existing preview after photo stops.
final class MovieCameraModel: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session=AVCaptureSession()
    @Published private(set) var status="Preparando vídeo…"
    @Published private(set) var ready=false
    @Published private(set) var phase=MovieRecordingState.Phase.idle
    @Published private(set) var configuration=MovieConfiguration()
    @Published private(set) var lens=CameraLens.wide
    @Published private(set) var zoom:Double=1
    @Published private(set) var maximumZoom:Double=1
    @Published private(set) var torch=false
    @Published private(set) var torchAvailable=false
    @Published private(set) var previewURL:URL?
    @Published private(set) var saved=false
    @Published private(set) var saveUncertain=false
    @Published private(set) var elapsed:Double=0
    @Published private(set) var supportsHDR10=false
    @Published private(set) var whiteBalanceLocked=false
    @Published private(set) var activeStabilization=MovieStabilizationMode.off
    private var recordingWhiteBalance:AVCaptureDevice.WhiteBalanceMode?
    let lenses=CameraLens.allCases.filter { $0.device != nil }
    private let queue=DispatchQueue(label:"com.gokuencinar.ultimatecam.movie",qos:.userInitiated)
    private let output=AVCaptureMovieFileOutput()
    private var machine=MovieRecordingState()
    private var current=MovieConfiguration()
    private var selected=CameraLens.wide
    private var device:AVCaptureDevice?
    private var rotationCoordinator:AVCaptureDevice.RotationCoordinator?
    private var active=false
    private var configured=false
    private var recordingURL:URL?
    private var recordingToken:UUID?
    private var savedOnQueue=false
    private var uncertainOnQueue=false
    private var timer:DispatchSourceTimer?
    private var startTime:CFTimeInterval=0
    private var permissionToken=UUID()
    private var shutdownCompletion:(()->Void)?
    private var directory:URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("VideoDrafts",isDirectory:true) }
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(interrupted),name:AVCaptureSession.wasInterruptedNotification,object:session)
        NotificationCenter.default.addObserver(self,selector:#selector(failed(_:)),name:AVCaptureSession.runtimeErrorNotification,object:session)
    }
    deinit { timer?.cancel();NotificationCenter.default.removeObserver(self) }
    private func ui(_ body:@escaping ()->Void) { DispatchQueue.main.async(execute:body) }
    private func syncUI(_ text:String?=nil) {
        let phase=machine.phase
        ui { self.phase=phase;if let text { self.status=text } }
    }
    func start(_ options:MovieConfiguration = MovieConfiguration(),lens:CameraLens = .wide) {
        queue.async {
        self.active=true
        guard !self.machine.busy else { return }
        let token=UUID();self.permissionToken=token
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            guard let self else { return }
            self.queue.async {
                guard self.active,self.permissionToken==token else { return }
                guard allowed else { self.ui { self.status="Permite el acceso a Cámara en Ajustes." };return }
                if options.audio {
                    AVCaptureDevice.requestAccess(for:.audio) { granted in self.queue.async {
                        guard self.active,self.permissionToken==token else { return }
                        self.activate(options,lens:lens,audioAllowed:granted)
                    } }
                } else { self.activate(options,lens:lens,audioAllowed:false) }
            }
        }
        }
    }
    func configure(_ options:MovieConfiguration,lens:CameraLens) {
        queue.async {
            guard !self.machine.busy else { return }
            if self.active { self.start(options,lens:lens) }
            else {
                do {
                    let request=try options.validated()
                    self.current=request;self.selected=lens
                    self.ui { self.configuration=request;self.lens=lens }
                } catch { self.ui { self.status=error.localizedDescription } }
            }
        }
    }
    private func isHDR10(_ format:AVCaptureDevice.Format)->Bool {
        CMFormatDescriptionGetMediaSubType(format.formatDescription)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange && format.supportedColorSpaces.contains(.HLG_BT2020)
    }
    private func avStabilization(_ mode:MovieStabilizationMode)->AVCaptureVideoStabilizationMode {
        switch mode { case .off:return .off;case .standard:return .standard;case .cinematic:return .cinematic;case .locked:return .cinematicExtended }
    }
    private func activate(_ options:MovieConfiguration,lens:CameraLens,audioAllowed:Bool) {
        guard active,!machine.busy else { return }
        ui { self.ready=false }
        do {
            var request=try options.validated();request.audio = request.audio && audioAllowed
            guard let camera=lens.device,let format=camera.formats.first(where:{ format in
                let d=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return request.matches(width:Int(d.width),height:Int(d.height),ranges:format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate },hdr10Bit:isHDR10(format)) && (request.hdrVideo || format.supportedColorSpaces.contains(.sRGB))
            }) else { throw CameraFailure.message("Esa combinación de lente, resolución, FPS y rango de color no está disponible.") }
            let newInput=try AVCaptureDeviceInput(device:camera)
            let audioInput:AVCaptureDeviceInput?
            if request.audio,let microphone=AVCaptureDevice.default(for:.audio) { audioInput=try AVCaptureDeviceInput(device:microphone) }
            else { audioInput=nil;request.audio=false }
            if session.isRunning { session.stopRunning() }
            let oldInputs=session.inputs,oldPreset=session.sessionPreset
            let oldWide=session.automaticallyConfiguresCaptureDeviceForWideColor
            let oldColor=camera.activeColorSpace,oldHDR=camera.isVideoHDREnabled,oldAutoHDR=camera.automaticallyAdjustsVideoHDREnabled
            let oldFormat=camera.activeFormat,oldMin=camera.activeVideoMinFrameDuration,oldMax=camera.activeVideoMaxFrameDuration
            session.beginConfiguration()
            do {
                guard session.canSetSessionPreset(.inputPriority) else { throw CameraFailure.message("No se puede configurar vídeo en esta cámara.") }
                session.sessionPreset = .inputPriority
                session.automaticallyConfiguresCaptureDeviceForWideColor=false
                for input in oldInputs { session.removeInput(input) }
                guard session.canAddInput(newInput) else { throw CameraFailure.message("No se pudo conectar la cámara de vídeo.") }
                session.addInput(newInput)
                if let audioInput {
                    guard session.canAddInput(audioInput) else { throw CameraFailure.message("No se pudo conectar el micrófono.") }
                    session.addInput(audioInput)
                }
                if !session.outputs.contains(output) {
                    guard session.canAddOutput(output) else { throw CameraFailure.message("La salida de vídeo no está disponible.") }
                    session.addOutput(output)
                }
                try camera.lockForConfiguration()
                camera.activeFormat=format
                camera.activeVideoMinFrameDuration=CMTime(value:1,timescale:Int32(request.fps))
                camera.activeVideoMaxFrameDuration=CMTime(value:1,timescale:Int32(request.fps))
                camera.activeColorSpace=request.hdrVideo ? .HLG_BT2020:.sRGB
                camera.automaticallyAdjustsVideoHDREnabled=false
                if format.isVideoHDRSupported { camera.isVideoHDREnabled=request.hdrVideo }
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
                camera.videoZoomFactor=max(1,camera.minAvailableVideoZoomFactor)
                request.exposureBias=Double(max(camera.minExposureTargetBias,min(camera.maxExposureTargetBias,Float(request.exposureBias))))
                camera.setExposureTargetBias(Float(request.exposureBias),completionHandler:nil)
                if camera.hasTorch { camera.torchMode = .off }
                camera.unlockForConfiguration()
                guard let connection=output.connection(with:.video) else { throw CameraFailure.message("La conexión de vídeo no está disponible.") }
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle=90 }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring=false;connection.isVideoMirrored=lens == .front }
                let supported=Set(MovieStabilizationMode.allCases.filter { $0 == .off || (connection.isVideoStabilizationSupported && format.isVideoStabilizationModeSupported(avStabilization($0))) })
                let stabilization=request.stabilization.resolved(supported:supported)
                connection.preferredVideoStabilizationMode=avStabilization(stabilization)
                let wanted:AVVideoCodecType=request.codec == .hevc ? .hevc : .h264
                guard output.availableVideoCodecTypes.contains(wanted) else { throw CameraFailure.message("El códec seleccionado no está disponible en esta configuración.") }
                let keys=Set(output.supportedOutputSettingsKeys(for:connection))
                guard keys.contains(AVVideoCodecKey) else { throw CameraFailure.message("El codificador no admite seleccionar este formato.") }
                var settings:[String:Any]=[AVVideoCodecKey:wanted]
                if request.hdrVideo {
                    guard keys.contains(AVVideoCompressionPropertiesKey) else { throw CameraFailure.message("El codificador no permite confirmar HEVC de 10 bits.") }
                    settings[AVVideoCompressionPropertiesKey]=[AVVideoProfileLevelKey:kVTProfileLevel_HEVC_Main10_AutoLevel]
                }
                output.setOutputSettings(settings,for:connection)
                ui { self.activeStabilization=stabilization }
                output.maxRecordedDuration=CMTime(seconds:600,preferredTimescale:600)
                output.maxRecordedFileSize=2_000_000_000
                output.minFreeDiskSpaceLimit=200_000_000
                session.commitConfiguration()
            } catch {
                for input in session.inputs { session.removeInput(input) }
                for input in oldInputs where session.canAddInput(input) { session.addInput(input) }
                session.sessionPreset=oldPreset;session.automaticallyConfiguresCaptureDeviceForWideColor=oldWide
                if (try? camera.lockForConfiguration()) != nil {
                    camera.activeFormat=oldFormat
                    if oldFormat.supportedColorSpaces.contains(oldColor) { camera.activeColorSpace=oldColor }
                    camera.automaticallyAdjustsVideoHDREnabled=false
                    if oldFormat.isVideoHDRSupported { camera.isVideoHDREnabled=oldHDR }
                    camera.automaticallyAdjustsVideoHDREnabled=oldAutoHDR
                    camera.activeVideoMinFrameDuration=oldMin;camera.activeVideoMaxFrameDuration=oldMax;camera.unlockForConfiguration()
                }
                session.commitConfiguration()
                if configured && active { session.startRunning() }
                throw error
            }
            device=camera;selected=lens;current=request;configured=true
            rotationCoordinator=AVCaptureDevice.RotationCoordinator(device:camera,previewLayer:nil)
            session.startRunning()
            let running=session.isRunning
            let hdrAvailable=camera.formats.contains { candidate in
                let d=CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                return Int(d.width)==request.resolution.width && Int(d.height)==request.resolution.height && self.isHDR10(candidate) && candidate.videoSupportedFrameRateRanges.contains { $0.minFrameRate<=Double(request.fps) && $0.maxFrameRate>=Double(request.fps) }
            }
            ui { self.supportsHDR10=hdrAvailable; self.ready=running;self.configuration=request;self.lens=lens;self.zoom=1
                self.maximumZoom=Double(min(camera.activeFormat.videoMaxZoomFactor,8));self.torch=false
                self.torchAvailable=camera.hasTorch && camera.isTorchAvailable
                self.status=running ? "\(request.resolution.label) · \(request.fps) FPS · \(request.audio ? "con audio" : "sin audio") · \(request.hdrVideo ? "HDR 10 bits":"SDR")" : "No se pudo iniciar la sesión de vídeo." }
            recoverDraftIfNeeded()
        } catch { ui { self.ready=self.session.isRunning && self.configured;self.status=error.localizedDescription } }
    }
    func record(mirrorSelfie:Bool=false) {
        queue.async {
            guard self.active,self.configured,self.session.isRunning,self.machine.phase == .idle else { return }
            do {
                guard let connection=self.output.connection(with:.video),let rotation=self.rotationCoordinator else { throw CameraFailure.message("No se pudo preparar la orientación del vídeo.") }
                let angle=try CaptureRotation.cardinal(Double(rotation.videoRotationAngleForHorizonLevelCapture))
                guard connection.isVideoRotationAngleSupported(CGFloat(angle)) else { throw CameraFailure.message("La cámara no admite esa orientación de vídeo.") }
                connection.videoRotationAngle=CGFloat(angle)
                let mirror=mirrorSelfie && self.selected == .front
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring=false;connection.isVideoMirrored=mirror }
                else if mirror { throw CameraFailure.message("Esta cámara no admite guardar el vídeo frontal reflejado.") }
                try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
                try self.lockRecordingWhiteBalance()
                guard let token=self.machine.begin() else { self.restoreRecordingWhiteBalance();return }
                let url=self.directory.appendingPathComponent("UltimateCAM-\(token.uuidString).mov")
                self.recordingURL=url;self.recordingToken=token;self.savedOnQueue=false;self.uncertainOnQueue=false;self.startTime=0
                self.ui { self.saved=false;self.saveUncertain=false;self.previewURL=nil;self.elapsed=0 }
                self.syncUI("Iniciando grabación…")
                self.output.startRecording(to:url,recordingDelegate:self)
                self.queue.asyncAfter(deadline:.now()+30) {
                    guard self.recordingToken==token,self.startTime==0,self.machine.phase == .recording else { return }
                    self.stopOnQueue();self.syncUI("La cámara no confirmó el inicio del vídeo. Si no termina, cierra Ultimate CAM. No se repetirá la grabación.")
                }
            } catch { self.restoreRecordingWhiteBalance();self.ui { self.status=error.localizedDescription } }
        }
    }
    private func lockRecordingWhiteBalance() throws {
        guard current.lockWhiteBalance else { return }
        guard let d=device,d.isWhiteBalanceModeSupported(.locked),!d.isAdjustingWhiteBalance else { throw CameraFailure.message("Espera a que se estabilice el balance de blancos o desactiva su bloqueo.") }
        try d.lockForConfiguration();defer { d.unlockForConfiguration() }
        recordingWhiteBalance=d.whiteBalanceMode
        var gains=d.deviceWhiteBalanceGains
        func gain(_ value:Float)->Float { min(d.maxWhiteBalanceGain,max(1,value.isFinite ? value:1)) }
        gains.redGain=gain(gains.redGain);gains.greenGain=gain(gains.greenGain);gains.blueGain=gain(gains.blueGain)
        d.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
        ui { self.whiteBalanceLocked=true }
    }
    private func restoreRecordingWhiteBalance() {
        guard let mode=recordingWhiteBalance else { return };recordingWhiteBalance=nil
        if let d=device,(try? d.lockForConfiguration()) != nil {
            if d.isWhiteBalanceModeSupported(mode) { d.whiteBalanceMode=mode };d.unlockForConfiguration()
        };ui { self.whiteBalanceLocked=false }
    }
    func setExposureBias(_ value:Double) {
        guard value.isFinite,(-2...2).contains(value) else { return }
        queue.async {
            var actual=Float(value)
            if self.active,let d=self.device {
                do {
                    try d.lockForConfiguration();defer { d.unlockForConfiguration() }
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    actual=max(d.minExposureTargetBias,min(d.maxExposureTargetBias,actual));d.setExposureTargetBias(actual,completionHandler:nil)
                } catch { self.ui { self.status=error.localizedDescription };return }
            }
            self.current.exposureBias=Double(actual);let published=Double(actual)
            self.ui { self.configuration.exposureBias=published }
        }
    }
    func stopRecording() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        guard machine.stop() else { return };timer?.cancel();timer=nil
        syncUI("Terminando archivo de vídeo…");output.stopRecording()
    }
    func fileOutput(_ output:AVCaptureFileOutput,didStartRecordingTo fileURL:URL,from connections:[AVCaptureConnection]) {
        queue.async {
            guard self.recordingURL==fileURL,self.machine.phase == .recording else { return }
            self.startTime=CACurrentMediaTime();self.syncUI("Grabando")
            let timer=DispatchSource.makeTimerSource(queue:self.queue);timer.schedule(deadline:.now(),repeating:0.25)
            timer.setEventHandler { [weak self] in guard let self else { return };let seconds=CACurrentMediaTime()-self.startTime;self.ui { self.elapsed=seconds } }
            self.timer=timer;timer.resume()
        }
    }
    func fileOutput(_ output:AVCaptureFileOutput,didFinishRecordingTo fileURL:URL,from connections:[AVCaptureConnection],error:Error?) {
        queue.async {
            guard self.recordingURL==fileURL,let token=self.recordingToken else { return }
            self.timer?.cancel();self.timer=nil;self.restoreRecordingWhiteBalance()
            let requireHDR=self.current.hdrVideo
            let finished=error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            Task {
                let inspected:Result<MovieRecordedAsset,Error>
                do {
                    let info=try await MovieRecordedAsset.inspect(fileURL)
                    guard !requireHDR || info.hdr10Bit else { throw CameraFailure.message("El archivo no confirmó HDR de 10 bits; se conserva para revisión.") }
                    inspected = .success(info)
                }
                catch { inspected = .failure(error) }
                self.queue.async {
                    let valid=finished && (try? inspected.get()) != nil
                    guard self.machine.finished(token,valid:valid) else { return }
                    if valid,case .success(let info)=inspected {
                        self.ui { self.previewURL=fileURL;self.saved=false;self.elapsed=info.duration }
                        self.syncUI("\(info.width) × \(info.height) · \(String(format:"%.1f",info.duration)) s · \(info.bytes/1_000_000) MB")
                    } else { self.syncUI(error?.localizedDescription ?? "No se pudo validar el vídeo. El archivo permanece en VideoDrafts.") }
                    if !self.active { self.session.stopRunning() }
                    else if self.rotationCoordinator==nil,let device=self.device {
                        self.rotationCoordinator=AVCaptureDevice.RotationCoordinator(device:device,previewLayer:nil)
                    }
                    let completion=self.shutdownCompletion;self.shutdownCompletion=nil
                    let ready=self.active && self.session.isRunning && self.configured
                    self.ui { self.ready=ready;completion?() }
                }
            }
        }
    }
    private func recoverDraftIfNeeded() {
        guard machine.phase == .idle else { return }
        let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey],options:.skipsHiddenFiles)) ?? []
        let drafts=files.filter {
            $0.lastPathComponent.hasPrefix("UltimateCAM-") && $0.pathExtension == "mov" &&
            UUID(uuidString:String($0.deletingPathExtension().lastPathComponent.dropFirst(12))) != nil &&
            (try? $0.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true
        }
            .sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        if let url=drafts.first,machine.recover() {
            recordingURL=url;recordingToken=machine.token
            savedOnQueue=FileManager.default.fileExists(atPath:url.appendingPathExtension("saved").path)
            uncertainOnQueue = !savedOnQueue && FileManager.default.fileExists(atPath:url.appendingPathExtension("saving").path)
            let saved=savedOnQueue,uncertain=uncertainOnQueue
            ui { self.previewURL=url;self.saved=saved;self.saveUncertain=uncertain }
            syncUI(uncertain ? "El guardado anterior quedó sin confirmación. Comprueba Fotos antes de descartarlo; no se repetirá la transacción." : "Vídeo conservado. Revísalo antes de grabar otro.")
        }
    }
    func save() {
        queue.async {
            guard !self.savedOnQueue,!self.uncertainOnQueue,let url=self.recordingURL,let token=self.machine.beginSave() else { return }
            do { try Data("pending".utf8).write(to:url.appendingPathExtension("saving"),options:.atomic) }
            catch { _ = self.machine.saved(token);self.syncUI("No se pudo registrar el guardado; el vídeo se conserva.");return }
            self.syncUI("Guardando vídeo…")
            PHPhotoLibrary.requestAuthorization(for:.addOnly) { status in
                guard status == .authorized || status == .limited else {
                    self.queue.async { if self.machine.saved(token) {
                        try? FileManager.default.removeItem(at:url.appendingPathExtension("saving"))
                        self.syncUI("Permite añadir vídeos a Fotos. El archivo se conserva.")
                    } };return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request=PHAssetCreationRequest.forAsset(),options=PHAssetResourceCreationOptions()
                    options.originalFilename=url.lastPathComponent;options.uniformTypeIdentifier=AVFileType.mov.rawValue
                    request.addResource(with:.video,fileURL:url,options:options)
                }) { success,error in self.queue.async {
                    guard self.machine.saved(token) else { return }
                    self.savedOnQueue=success;self.ui { self.saved=success }
                    if success { try? Data("saved".utf8).write(to:url.appendingPathExtension("saved"),options:.atomic) }
                    else { try? FileManager.default.removeItem(at:url.appendingPathExtension("saving")) }
                    self.syncUI(success ? "Vídeo guardado en Fotos." : (error?.localizedDescription ?? "Fotos no completó el guardado; no se reintentará automáticamente."))
                } }
            }
        }
    }
    func clear(completion:@escaping ()->Void = {}) {
        queue.async {
            guard self.machine.phase == .review,let url=self.recordingURL else { return }
            do { try FileManager.default.removeItem(at:url) }
            catch { self.ui { self.status="No se pudo eliminar el borrador: \(error.localizedDescription)" };return }
            guard self.machine.discard() else { return }
            for suffix in ["saved","saving"] { try? FileManager.default.removeItem(at:url.appendingPathExtension(suffix)) }
            self.recordingURL=nil;self.recordingToken=nil;self.savedOnQueue=false;self.uncertainOnQueue=false
            self.ui { self.previewURL=nil;self.saved=false;self.saveUncertain=false;self.elapsed=0;completion() };self.syncUI("Lista para grabar.")
        }
    }
    func shutdown(completion:@escaping ()->Void = {}) {
        queue.async {
            if !self.active && !self.session.isRunning && self.machine.phase != .finishing { self.ui { completion() };return }
            self.active=false
            self.rotationCoordinator=nil
            self.permissionToken=UUID()
            if self.machine.phase == .recording { self.stopOnQueue() }
            if let device=self.device,device.hasTorch,(try? device.lockForConfiguration()) != nil { device.torchMode = .off;device.unlockForConfiguration() }
            if self.machine.phase == .finishing {
                self.shutdownCompletion=completion
                self.ui { self.ready=false;self.torch=false }
            } else {
                self.restoreRecordingWhiteBalance();self.session.stopRunning()
                self.ui { self.ready=false;self.torch=false;completion() }
            }
        }
    }
    func focus(_ point:CGPoint,locked:Bool) {
        queue.async {
            guard let d=self.device,self.active,(try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest=point }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest=point }
            let f:AVCaptureDevice.FocusMode=locked ? .locked : .autoFocus
            let e:AVCaptureDevice.ExposureMode=locked ? .locked : .continuousAutoExposure
            if d.isFocusModeSupported(f) { d.focusMode=f };if d.isExposureModeSupported(e) { d.exposureMode=e }
        }
    }
    func setZoom(_ value:Double,smooth:Bool=false) {
        queue.async { guard value.isFinite,let d=self.device,(try? d.lockForConfiguration()) != nil else { return }
            let selected=min(max(1,value),min(8,Double(d.activeFormat.videoMaxZoomFactor)))
            if smooth { d.ramp(toVideoZoomFactor:CGFloat(selected),withRate:4) }
            else { d.cancelVideoZoomRamp();d.videoZoomFactor=CGFloat(selected) }
            d.unlockForConfiguration();self.ui { self.zoom=selected } }
    }
    func toggleTorch() {
        queue.async { guard let d=self.device,d.hasTorch,d.isTorchAvailable,(try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() };d.torchMode=d.torchMode == .on ? .off : .on
            let enabled=d.torchMode == .on;self.ui { self.torch=enabled } }
    }
    @objc private func interrupted() { queue.async { self.stopOnQueue();self.ui { self.ready=false;self.status="Vídeo interrumpido; se conserva el archivo recibido." } } }
    @objc private func failed(_ notification:Notification) { interrupted() }
}
