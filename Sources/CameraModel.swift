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
    @Published private(set) var supportsRAW = false
    @Published private(set) var supportsManualExposure = false
    @Published private(set) var supportsManualFocus = false
    @Published private(set) var supportsManualWB = false
    @Published private(set) var selectedLens = CameraLens.wide
    @Published private(set) var focusStatus = "Toca el visor para enfocar"
    @Published private(set) var isFocusLocked = false
    @Published private(set) var hasRAWResult = false
    @Published private(set) var hasSeparateReference = false
    @Published private(set) var savedResult = false
    @Published private(set) var savedJPEGOnly = false
    @Published private(set) var maximumZoom: Double = 1
    @Published private(set) var isoRange: ClosedRange<Double> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...0.33
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
    private var diagnosticBridge: DiagnosticBridge?
    private var processingOptions = ProcessingOptions()
    private var rawRequested = false
    private var rawData: Data?
    private var captureRecoveryRequired = false
    private var focusToken = UUID()
    private var savedKinds = Set<String>()

    override init() {
        super.init()
        diagnosticBridge = DiagnosticBridge(capture: { [weak self] request in
            self?.capture(stack: request.stack, count: request.count, raw: request.raw, options: request.options)
        }, command: { [weak self] object in self?.diagnosticCommand(object) })
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
        if captureRecoveryRequired {
            publish { self.ready = false }
            message("La captura anterior no terminó. Cierra Ultimate CAM desde el selector de apps y vuelve a abrirla.")
            return
        }
        do {
            if !configured {
                try configure(.wide)
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            let rawAvailable = !output.availableRawPhotoPixelFormatTypes.isEmpty
            publish { self.supportsRAW = rawAvailable }
            let available = self.session.isRunning && !self.interrupted
            CaptureTrace.record("session.ready", ["running": available, "inputs": session.inputs.count, "outputs": session.outputs.count])
            publish { self.ready = available }
            message("Lista. La pila es experimental y requiere una escena inmóvil.")
        } catch { message(error.localizedDescription) }
    }

    func stop() {
        queue.async {
            self.active = false
            self.focusToken = UUID()
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
            self.publish { self.ready = false }
            do {
                try self.configure(lens)
                let rawAvailable = !self.output.availableRawPhotoPixelFormatTypes.isEmpty
                self.publish { self.supportsRAW = rawAvailable; self.ready = self.session.isRunning }
                self.message("Cámara \(lens.label) lista.")
            } catch {
                self.publish { self.ready = self.session.isRunning }
                self.message(error.localizedDescription)
            }
        }
    }

    private func configure(_ lens: CameraLens) throws {
        guard let device = lens.device else { throw CameraFailure.message("Cámara no disponible.") }
        let next = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        var committed = false
        defer { if !committed { session.commitConfiguration() } }
        session.sessionPreset = .photo
        let old = input
        if let old { session.removeInput(old) }
        guard session.canAddInput(next) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            throw CameraFailure.message("No se pudo cambiar de cámara.")
        }
        session.addInput(next)
        input = next
        if !session.outputs.contains(where: { $0 === output }) {
            guard session.canAddOutput(output) else { throw CameraFailure.message("No se puede configurar la salida de fotos.") }
            session.addOutput(output)
        }
        let isoLimits = Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO)
        let shutterLimits = max(1.0 / 100000, device.activeFormat.minExposureDuration.seconds)...max(1.0 / 100000, device.activeFormat.maxExposureDuration.seconds)
        focusToken = UUID()
        try device.lockForConfiguration()
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
        device.setExposureTargetBias(0, completionHandler: nil)
        device.unlockForConfiguration()
        let manualAvailable = device.isExposureModeSupported(.custom)
        let focusAvailable = device.isLockingFocusWithCustomLensPositionSupported
        let zoom = max(1, min(8, Double(device.activeFormat.videoMaxZoomFactor)))
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
        session.commitConfiguration()
        committed = true
        let rawAvailable = !output.availableRawPhotoPixelFormatTypes.isEmpty
        publish {
            self.selectedLens = lens
            self.isoRange = isoLimits
            self.shutterRange = shutterLimits
            self.supportsRAW = rawAvailable
            self.supportsManualExposure = manualAvailable
            self.supportsManualFocus = focusAvailable
            self.supportsManualWB = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            self.maximumZoom = zoom
            self.isFocusLocked = false
            self.focusStatus = device.isFocusPointOfInterestSupported ? "Toca para enfocar · mantén para bloquear" : "Lente de enfoque fijo · toca para medir la luz"
        }
        CaptureTrace.record("lens.ready", ["lens": lens.rawValue, "raw": rawAvailable,
            "manualExposure": manualAvailable, "manualFocus": focusAvailable,
            "tapFocus": device.isFocusPointOfInterestSupported,
            "manualWB": device.isLockingWhiteBalanceWithCustomDeviceGainsSupported])
    }

    func setBias(_ bias: Float) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(min(device.maxExposureTargetBias,
                    max(device.minExposureTargetBias, bias)), completionHandler: nil)
                CaptureTrace.record("control.bias", ["requested": bias, "applied": device.exposureTargetBias])
            } catch { self.message(error.localizedDescription) }
        }
    }

    func setManualExposure(iso: Double?, seconds: Double = 1.0 / 60) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let iso, device.isExposureModeSupported(.custom) {
                    let clampedISO = min(device.activeFormat.maxISO, max(device.activeFormat.minISO, Float(iso)))
                    let duration = min(device.activeFormat.maxExposureDuration.seconds,
                                       max(device.activeFormat.minExposureDuration.seconds, seconds))
                    device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                                                 iso: clampedISO) { _ in
                        CaptureTrace.record("control.exposure", ["iso": device.iso, "seconds": device.exposureDuration.seconds, "custom": true])
                    }
                } else if iso == nil, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    CaptureTrace.record("control.exposure", ["custom": false])
                }
            } catch { self.message(error.localizedDescription) }
        }
    }

    func setFocus(_ position: Double?) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                self.focusToken = UUID()
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let position, device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: Float(min(1, max(0, position)))) { _ in
                        CaptureTrace.record("control.focus", ["manual": true, "position": device.lensPosition])
                    }
                    self.publish { self.focusStatus = "Enfoque manual"; self.isFocusLocked = false }
                } else if position == nil, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    self.publish { self.focusStatus = "Enfoque automático"; self.isFocusLocked = false }
                    CaptureTrace.record("control.focus", ["manual": false])
                }
            } catch { self.message(error.localizedDescription) }
        }
    }

    func focus(at point: CGPoint, lock: Bool = false) {
        queue.async {
            guard !self.inFlight, self.active, let device = self.input?.device else { return }
            let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            let token = UUID()
            self.focusToken = token
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.exposureMode != .custom && device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                self.publish { self.isFocusLocked = false; self.focusStatus = device.isFocusPointOfInterestSupported ? "Enfocando…" : "Enfoque fijo · ajustando la luz" }
                CaptureTrace.record("focus.request", ["x": point.x, "y": point.y, "lock": lock,
                    "supported": device.isFocusPointOfInterestSupported, "lens": self.selectedLens.rawValue])
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.finishFocus(token, device: device, lock: lock, remaining: 20) }
            } catch { self.message(error.localizedDescription) }
        }
    }

    private func finishFocus(_ token: UUID, device: AVCaptureDevice, lock: Bool, remaining: Int) {
        guard token == focusToken, active, input?.device === device, !inFlight else { return }
        if device.isAdjustingFocus || device.isAdjustingExposure {
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + 0.15) { self.finishFocus(token, device: device, lock: lock, remaining: remaining - 1) }
            } else {
                publish { self.focusStatus = "No se ha estabilizado el enfoque. Prueba un borde con más contraste." }
                CaptureTrace.record("focus.unsettled")
            }
            return
        }
        do {
            if lock {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.exposureMode != .custom && device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
            }
            publish {
                self.isFocusLocked = lock
                self.focusStatus = lock ? "AF / AE bloqueados · toca para liberar" :
                    (device.isFocusPointOfInterestSupported ? "Enfoque ajustado" : "Enfoque fijo · luz ajustada")
            }
            CaptureTrace.record("focus.settled", ["locked": lock, "position": device.lensPosition,
                "focusMode": device.focusMode.rawValue, "exposureMode": device.exposureMode.rawValue])
        } catch { message(error.localizedDescription) }
    }

    func setZoom(_ zoom: Double) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(zoom)))
                CaptureTrace.record("control.zoom", ["requested": zoom, "applied": device.videoZoomFactor])
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
                    CaptureTrace.record("control.whiteBalance", ["manual": true, "temperature": kelvin])
                } else if kelvin == nil && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    CaptureTrace.record("control.whiteBalance", ["manual": false])
                } else { self.message("Esta cámara no admite ese control de balance de blancos.") }
            } catch { self.message(error.localizedDescription) }
        }
    }

    func capture(stack: Bool, count: Int = 3, raw: Bool = false, options: ProcessingOptions = ProcessingOptions()) {
        queue.async {
            guard self.active, self.session.isRunning, !self.interrupted, !self.inFlight, !self.captureRecoveryRequired,
                  let device = self.input?.device else { return }
            self.inFlight = true
            self.transaction = UUID()
            self.frames = []
            self.desiredCount = stack ? min(9, max(3, count)) : 1
            self.processingOptions = options
            self.rawRequested = raw && !stack && !self.output.availableRawPhotoPixelFormatTypes.isEmpty
            self.rawData = nil
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
                    if device.exposureMode != .custom {
                        self.savedExposure = device.exposureMode
                        device.exposureMode = .locked
                    }
                    self.savedWhiteBalance = device.whiteBalanceMode
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
        guard let connection = output.connection(with: .video), connection.isEnabled, connection.isActive else {
            finishFailure(CameraFailure.message("La salida de fotografía no está activa. Vuelve a abrir la app."))
            return
        }
        message("Capturando \(frames.count + 1)/\(desiredCount). Mantén la cámara inmóvil.")
        let settings: AVCapturePhotoSettings
        if rawRequested, let rawFormat = output.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        // Use one sensor exposure per request; our own burst performs the merge.
        // This also honors custom/locked ISO and shutter settings, per Apple's API contract.
        settings.photoQualityPrioritization = .speed
        let identifier = settings.uniqueID
        captureStage = "requested"
        CaptureTrace.record("capture.request", ["id": identifier,
            "running": session.isRunning, "enabled": connection.isEnabled,
            "active": connection.isActive, "quality": settings.photoQualityPrioritization.rawValue,
            "width": settings.maxPhotoDimensions.width, "height": settings.maxPhotoDimensions.height,
            "count": desiredCount, "raw": rawRequested])
        captureID = identifier
        expectedFrameCount = frames.count + 1
        output.capturePhoto(with: settings, delegate: self)
        CaptureTrace.record("capture.submitted", ["id": identifier])
        queue.asyncAfter(deadline: .now() + 30) {
            guard self.captureID == identifier else { return }
            CaptureTrace.record("capture.timeout", ["id": identifier, "stage": self.captureStage])
            self.captureRecoveryRequired = true
            self.publish { self.ready = false }
            self.finishFailure(CameraFailure.message("La cámara no respondió en 30 segundos. Cierra Ultimate CAM desde el selector de apps y vuelve a abrirla; no se repetirá la captura."))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        CaptureTrace.record("delegate.processing.enter", ["id": photo.resolvedSettings.uniqueID,
            "raw": photo.isRawPhoto, "error": error?.localizedDescription ?? "none"])
        // didFinishCapture follows processing; enqueue both on the same serial queue.
        let data = photo.fileDataRepresentation()
        let identifier = photo.resolvedSettings.uniqueID
        let isRaw = photo.isRawPhoto
        queue.async {
            CaptureTrace.record("delegate.processing.queued", ["id": identifier, "expected": self.captureID ?? -1, "bytes": data?.count ?? 0])
            guard self.inFlight, self.captureID == identifier else { return }
            self.captureStage = "processed"
            if let error { self.finishFailure(error) }
            else if let data {
                if isRaw { self.rawData = data }
                else { self.frames.append(data) }
            }
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
            if self.rawRequested && self.rawData == nil {
                self.finishFailure(CameraFailure.message("No se recibió el DNG solicitado."))
                return
            }
            if self.frames.count < self.desiredCount { self.captureNext(); return }
            self.restoreDevice()
            let captured = self.frames
            let token = self.transaction
            let options = self.processingOptions
            let raw = self.rawData
            self.frames = []
            self.message("Procesando…")
            self.processing.async {
                let processed = Result { try autoreleasepool {
                    var result = try BurstProcessor().process(captured, options: options)
                    result.raw = raw
                    return result
                } }
                self.queue.async {
                    guard self.transaction == token, self.inFlight else { return }
                    switch processed {
                    case .success(let result):
                        CaptureTrace.record("capture.success", ["bytes": result.jpeg.count,
                            "mergedFrames": result.mergedFrames, "rawBytes": result.raw?.count ?? 0,
                            "details": result.details])
                        self.result = result
                        self.savedKinds = []
                        self.publish {
                            self.preview = UIImage(data: result.jpeg)
                            self.referencePreview = UIImage(data: result.reference)
                            self.resultDetails = result.details
                            self.hasRAWResult = result.raw != nil
                            self.hasSeparateReference = result.jpeg != result.reference
                            self.savedResult = false
                            self.savedJPEGOnly = false
                            if result.raw != nil { self.resultDetails += " · Incluye RAW/DNG" }
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
        rawData = nil
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

    func save(jpegOnly: Bool = false, includeReference: Bool = false) {
        queue.async {
            guard !self.inFlight, let result = self.result else { return }
            let kind = jpegOnly ? "jpeg" : "all"
            guard !self.savedKinds.contains(kind) else {
                self.message("Esta captura ya está guardada.")
                CaptureTrace.record("save.duplicateBlocked", ["kind": kind])
                return
            }
            self.inFlight = true
            self.publish { self.busy = true }
            self.message("Guardando en Fotos…")
            CaptureTrace.record("save.request", ["raw": result.raw != nil && !jpegOnly,
                "jpegOnly": jpegOnly, "reference": includeReference])
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
                guard authorization == .authorized || authorization == .limited else {
                    self.queue.async {
                        self.inFlight = false
                        self.publish { self.busy = false }
                        self.message("Permite añadir fotos en Ajustes. La captura sigue disponible para reintentar.")
                        CaptureTrace.record("save.denied", ["authorization": authorization.rawValue])
                    }
                    return
                }
                self.processing.async {
                    PhotoLibraryWriter.save(result, jpegOnly: jpegOnly, includeReference: includeReference) { outcome in
                        self.queue.async {
                            self.inFlight = false
                            self.publish { self.busy = false }
                            switch outcome {
                            case .success(let ids):
                                self.savedKinds.insert(kind)
                                CaptureTrace.record("save.success", ["assets": ids, "raw": result.raw != nil && !jpegOnly])
                                self.publish {
                                    if jpegOnly { self.savedJPEGOnly = true }
                                    else { self.savedResult = true }
                                }
                                self.message(result.raw != nil && !jpegOnly ? "RAW + JPEG guardados en Fotos." : "Foto guardada en Fotos.")
                            case .failure(let error):
                                let value = error as NSError
                                CaptureTrace.record("save.failure", ["domain": value.domain, "code": value.code,
                                    "description": value.localizedDescription,
                                    "underlying": (value.userInfo[NSUnderlyingErrorKey] as? NSError)?.description ?? "none"])
                                self.message("No se pudo guardar (\(value.domain) \(value.code)). La captura sigue disponible. \(result.raw != nil ? "Puedes guardar solo el JPEG." : "")")
                            }
                        }
                    }
                }
            }
        }
    }

    private func diagnosticCommand(_ object: [String: String]) {
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let text = object[key], let value = Double(text), value.isFinite, range.contains(value) else { return nil }
            return value
        }
        switch object["action"] {
        case "save":
            guard ["all", "jpeg"].contains(object["format"] ?? "all") else { return }
            save(jpegOnly: object["format"] == "jpeg", includeReference: object["reference"] == "true")
        case "focus":
            guard let x = number("x", 0...1), let y = number("y", 0...1) else { return }
            focus(at: CGPoint(x: x, y: y), lock: object["lock"] == "true")
        case "lens":
            guard let value = object["lens"], let lens = CameraLens(rawValue: value) else { return }
            switchLens(lens)
        case "control":
            switch object["parameter"] {
            case "bias": if let value = number("value", -2...2) { setBias(Float(value)) }
            case "zoom": if let value = number("value", 1...8) { setZoom(value) }
            case "focus":
                if object["value"] == "auto" { setFocus(nil) }
                else if let value = number("value", 0...1) { setFocus(value) }
            case "whiteBalance":
                if object["value"] == "auto" { setWhiteBalance(nil) }
                else if let value = number("value", 2500...8000) { setWhiteBalance(Float(value)) }
            case "exposure":
                if object["iso"] == "auto" { setManualExposure(iso: nil) }
                else if let iso = number("iso", 1...100000), let seconds = number("seconds", 0.000001...10) { setManualExposure(iso: iso, seconds: seconds) }
            default: break
            }
        case "inspect":
            queue.async {
                guard let device = self.input?.device else { return }
                CaptureTrace.record("diagnostic.state", ["raw": !self.output.availableRawPhotoPixelFormatTypes.isEmpty,
                    "focusPosition": device.lensPosition, "focusMode": device.focusMode.rawValue,
                    "focusPointX": device.focusPointOfInterest.x, "focusPointY": device.focusPointOfInterest.y,
                    "adjustingFocus": device.isAdjustingFocus, "iso": device.iso,
                    "seconds": device.exposureDuration.seconds, "exposureMode": device.exposureMode.rawValue,
                    "bias": device.exposureTargetBias, "zoom": device.videoZoomFactor,
                    "whiteBalanceMode": device.whiteBalanceMode.rawValue,
                    "running": self.session.isRunning, "busy": self.inFlight])
            }
        default: break
        }
    }
}
