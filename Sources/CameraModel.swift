import AVFoundation
import Combine
import Photos
import UIKit

enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide, wide, telephoto, front
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ultraWide: return "0,5×"
        case .wide: return "1×"
        case .telephoto: return "2×"
        case .front: return "Frontal"
        }
    }
    var device: AVCaptureDevice? {
        let type: AVCaptureDevice.DeviceType
        switch self {
        case .ultraWide: type = .builtInUltraWideCamera
        case .telephoto: type = .builtInTelephotoCamera
        default: type = .builtInWideAngleCamera
        }
        return AVCaptureDevice.default(type, for: .video, position: self == .front ? .front : .back)
    }
}

/// All AVFoundation session mutations and capture state belong to `queue`.
/// Published UI values are changed only on the main queue.
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var status = "Solicita acceso a la cámara para empezar."
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var preview: UIImage?
    @Published private(set) var referencePreview: UIImage?
    @Published private(set) var resultDetails = ""
    let lenses = CameraLens.allCases.filter { $0.device != nil }

    private let queue = DispatchQueue(label: "local.ultimatecam.session", qos: .userInitiated)
    private let processing = DispatchQueue(label: "local.ultimatecam.processing", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var active = false
    private var inFlight = false
    private var frames = [Data]()
    private var desiredCount = 1
    private var savedExposure: AVCaptureDevice.ExposureMode?
    private var savedWhiteBalance: AVCaptureDevice.WhiteBalanceMode?
    private var savedFocus: AVCaptureDevice.FocusMode?
    private var captureID: Int64?
    private var expectedFrameCount = 0
    private var transaction = UUID()
    private var result: CaptureResult?
    private var interrupted = false
    private var captureStage = "idle"

    override init() {
        super.init()
        CaptureTrace.record("model.init", [
            "processingDelegate": responds(to: NSSelectorFromString("captureOutput:didFinishProcessingPhoto:error:")),
            "completionDelegate": responds(to: NSSelectorFromString("captureOutput:didFinishCaptureForResolvedSettings:error:"))
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted),
            name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeError),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func publish(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) }
    private func message(_ text: String) { publish { self.status = text } }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.activate() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.queue.async { self.activate() } }
                else { self.message("Permite el acceso a Cámara en Ajustes para continuar.") }
            }
        default: message("Permite el acceso a Cámara en Ajustes para continuar.")
        }
    }

    private func activate() {
        active = true
        do {
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .photo
                if !session.outputs.contains(where: { $0 === output }) {
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw CameraFailure.message("No se puede configurar la salida de fotos.")
                    }
                    session.addOutput(output)
                }
                session.commitConfiguration()
                try configure(.wide)
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            let available = self.session.isRunning && !self.interrupted
            CaptureTrace.record("session.ready", ["running": available, "inputs": session.inputs.count, "outputs": session.outputs.count])
            publish { self.ready = available }
            message("Lista. La pila es experimental y requiere una escena inmóvil.")
        } catch { message(error.localizedDescription) }
    }

    func stop() {
        queue.async {
            self.active = false
            self.publish { self.ready = false }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    @objc private func sessionInterrupted() {
        queue.async {
            self.interrupted = true
            self.publish { self.ready = false }
            self.message("Cámara interrumpida. Espera a que vuelva a estar disponible.")
        }
    }
    @objc private func interruptionEnded() {
        queue.async {
            self.interrupted = false
            if self.active {
                if !self.inFlight { self.activate() }
                else {
                    let available = self.session.isRunning
                    self.publish { self.ready = available }
                }
            }
        }
    }
    @objc private func runtimeError(_ note: Notification) {
        let description = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "Error de la sesión de cámara. Vuelve a abrir la app."
        queue.async {
            CaptureTrace.record("session.error", ["description": description])
            self.publish { self.ready = false }
            if self.captureID != nil { self.finishFailure(CameraFailure.message(description)) }
            else { self.message(description) }
        }
    }

    func switchLens(_ lens: CameraLens) {
        queue.async {
            guard !self.inFlight, self.configured else { return }
            do {
                try self.configure(lens)
                self.message("\(lens.label) · RAW disponible: \(self.output.availableRawPhotoPixelFormatTypes.isEmpty ? "no" : "sí"). Captura actual: JPEG.")
            } catch { self.message(error.localizedDescription) }
        }
    }

    private func configure(_ lens: CameraLens) throws {
        guard let device = lens.device else { throw CameraFailure.message("Cámara no disponible.") }
        let next = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let old = input
        if let old { session.removeInput(old) }
        guard session.canAddInput(next) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            throw CameraFailure.message("No se pudo cambiar de cámara.")
        }
        session.addInput(next)
        input = next
        output.maxPhotoQualityPrioritization = .quality
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { output.maxPhotoDimensions = dimensions }
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    func setBias(_ bias: Float) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(min(device.maxExposureTargetBias,
                    max(device.minExposureTargetBias, bias)), completionHandler: nil)
            } catch { self.message(error.localizedDescription) }
        }
    }

    func setWhiteBalance(_ kelvin: Float?) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let kelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                    var gains = device.deviceWhiteBalanceGains(for: values)
                    gains.redGain = min(device.maxWhiteBalanceGain, max(1, gains.redGain))
                    gains.greenGain = min(device.maxWhiteBalanceGain, max(1, gains.greenGain))
                    gains.blueGain = min(device.maxWhiteBalanceGain, max(1, gains.blueGain))
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                } else if kelvin == nil && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                } else { self.message("Esta cámara no admite ese control de balance de blancos.") }
            } catch { self.message(error.localizedDescription) }
        }
    }

    func capture(stack: Bool) {
        queue.async {
            guard self.active, self.session.isRunning, !self.interrupted, !self.inFlight,
                  let device = self.input?.device else { return }
            self.inFlight = true
            self.transaction = UUID()
            self.frames = []
            self.desiredCount = stack ? 3 : 1
            self.publish { self.busy = true }
            do {
                if stack {
                    guard !device.isAdjustingExposure, !device.isAdjustingWhiteBalance,
                          !device.isAdjustingFocus else {
                        throw CameraFailure.message("Espera a que terminen el enfoque y la exposición y vuelve a capturar.")
                    }
                    guard device.isExposureModeSupported(.locked), device.isWhiteBalanceModeSupported(.locked) else {
                        throw CameraFailure.message("Esta cámara no admite los bloqueos necesarios para la pila.")
                    }
                    try device.lockForConfiguration()
                    self.savedExposure = device.exposureMode
                    self.savedWhiteBalance = device.whiteBalanceMode
                    device.exposureMode = .locked
                    device.whiteBalanceMode = .locked
                    if device.isFocusModeSupported(.locked) {
                        self.savedFocus = device.focusMode
                        device.focusMode = .locked
                    }
                    device.unlockForConfiguration()
                }
                self.captureNext()
            } catch { self.finishFailure(error) }
        }
    }

    private func captureNext() {
        guard active, !interrupted, session.isRunning else {
            finishFailure(CameraFailure.message("Captura interrumpida. No se ha guardado nada."))
            return
        }
        guard output.availablePhotoCodecTypes.contains(.jpeg) else {
            finishFailure(CameraFailure.message("JPEG no disponible en esta configuración."))
            return
        }
        message("Capturando \(frames.count + 1)/\(desiredCount). Mantén la cámara inmóvil.")
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        let identifier = settings.uniqueID
        captureStage = "requested"
        let connection = output.connection(with: .video)
        CaptureTrace.record("capture.request", ["id": identifier,
            "running": session.isRunning, "enabled": connection?.isEnabled ?? false,
            "active": connection?.isActive ?? false, "quality": settings.photoQualityPrioritization.rawValue,
            "width": settings.maxPhotoDimensions.width, "height": settings.maxPhotoDimensions.height,
            "count": desiredCount])
        captureID = identifier
        expectedFrameCount = frames.count + 1
        output.capturePhoto(with: settings, delegate: self)
        CaptureTrace.record("capture.submitted", ["id": identifier])
        queue.asyncAfter(deadline: .now() + 30) {
            guard self.captureID == identifier else { return }
            CaptureTrace.record("capture.timeout", ["id": identifier, "stage": self.captureStage])
            self.finishFailure(CameraFailure.message("La cámara no respondió en 30 segundos. No se repetirá la captura automáticamente."))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        CaptureTrace.record("delegate.processing.enter", ["id": photo.resolvedSettings.uniqueID, "error": error?.localizedDescription ?? "none"])
        // didFinishCapture follows processing; enqueue both on the same serial queue.
        let data = photo.fileDataRepresentation()
        let identifier = photo.resolvedSettings.uniqueID
        queue.async {
            CaptureTrace.record("delegate.processing.queued", ["id": identifier, "expected": self.captureID ?? -1, "bytes": data?.count ?? 0])
            guard self.inFlight, self.captureID == identifier else { return }
            self.captureStage = "processed"
            if let error { self.finishFailure(error) }
            else if let data { self.frames.append(data) }
            else { self.finishFailure(CameraFailure.message("La cámara no ha devuelto datos de imagen.")) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        CaptureTrace.record("delegate.finished.enter", ["id": resolvedSettings.uniqueID, "error": error?.localizedDescription ?? "none"])
        queue.async {
            guard self.inFlight, self.captureID == resolvedSettings.uniqueID else { return }
            self.captureID = nil
            if let error { self.finishFailure(error); return }
            guard self.frames.count == self.expectedFrameCount else {
                self.finishFailure(CameraFailure.message("Captura incompleta. No se ha repetido ni guardado ninguna foto."))
                return
            }
            if self.frames.count < self.desiredCount { self.captureNext(); return }
            self.restoreDevice()
            let captured = self.frames
            let token = self.transaction
            self.frames = []
            self.message("Procesando…")
            self.processing.async {
                let processed = Result { try autoreleasepool { try BurstProcessor().process(captured) } }
                self.queue.async {
                    guard self.transaction == token, self.inFlight else { return }
                    switch processed {
                    case .success(let result):
                        self.result = result
                        self.publish {
                            self.preview = UIImage(data: result.jpeg)
                            self.referencePreview = UIImage(data: result.reference)
                            self.resultDetails = result.details
                            self.busy = false
                            self.status = "Captura preparada. Revisa el resultado antes de guardarlo."
                        }
                        self.inFlight = false
                    case .failure(let error): self.finishFailure(error)
                    }
                }
            }
        }
    }

    private func restoreDevice() {
        guard let device = input?.device,
              savedExposure != nil || savedWhiteBalance != nil || savedFocus != nil else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let mode = savedExposure { device.exposureMode = mode }
            if let mode = savedWhiteBalance { device.whiteBalanceMode = mode }
            if let mode = savedFocus { device.focusMode = mode }
            savedExposure = nil
            savedWhiteBalance = nil
            savedFocus = nil
        } catch { message("No se pudieron restaurar los ajustes: \(error.localizedDescription)") }
    }

    private func finishFailure(_ error: Error) {
        CaptureTrace.record("capture.failure", ["description": error.localizedDescription])
        transaction = UUID()
        captureID = nil
        restoreDevice()
        frames = []
        inFlight = false
        publish { self.busy = false; self.status = error.localizedDescription }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        CaptureTrace.record("delegate.begin", ["id": resolvedSettings.uniqueID])
        queue.async { if self.captureID == resolvedSettings.uniqueID { self.captureStage = "began" } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        CaptureTrace.record("delegate.willCapture", ["id": resolvedSettings.uniqueID])
        queue.async { if self.captureID == resolvedSettings.uniqueID { self.captureStage = "exposing" } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        CaptureTrace.record("delegate.didCapture", ["id": resolvedSettings.uniqueID])
        queue.async { if self.captureID == resolvedSettings.uniqueID { self.captureStage = "exposed" } }
    }

    func save() {
        queue.async {
            guard !self.inFlight, let result = self.result else { return }
            self.inFlight = true
            self.publish { self.busy = true }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
                guard authorization == .authorized || authorization == .limited else {
                    self.queue.async { self.finishFailure(CameraFailure.message("Permite añadir fotos en Ajustes. La captura sigue disponible para reintentar.")) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "UltimateCAM-result.jpg"
                    request.addResource(with: .photo, data: result.jpeg, options: options)
                    if result.jpeg != result.reference {
                        let reference = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = "UltimateCAM-reference.jpg"
                        reference.addResource(with: .photo, data: result.reference, options: options)
                    }
                }) { success, error in
                    self.queue.async {
                        self.inFlight = false
                        self.publish {
                            self.busy = false
                            self.status = success ? "Guardado en Fotos." : (error?.localizedDescription ?? "No se pudo guardar.")
                        }
                    }
                }
            }
        }
    }
}
