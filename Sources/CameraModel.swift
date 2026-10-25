import AVFoundation
import Combine
import ImageIO
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

enum CameraFlash: String, CaseIterable, Identifiable {
    case off, auto, on
    var id: String { rawValue }
    var label: String { self == .off ? "OFF" : (self == .auto ? "AUTO" : "ON") }
    var mode: AVCaptureDevice.FlashMode {
        switch self { case .off: return .off; case .auto: return .auto; case .on: return .on }
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
    @Published private(set) var resultStatistics: ImageStatistics?
    @Published private(set) var supportsFlash = false
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
    @Published private(set) var zoomFactor: Double = 1
    @Published private(set) var maximumZoom: Double = 1
    @Published private(set) var isoRange: ClosedRange<Double> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...0.33
    let lenses = CameraLens.allCases.filter { $0.device != nil }

    private let queue = DispatchQueue(label: "local.ultimatecam.session", qos: .userInitiated)
    private let processing = DispatchQueue(label: "local.ultimatecam.processing", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var rotationCoordinator:AVCaptureDevice.RotationCoordinator?
    private var configured = false
    private var configuredLens = CameraLens.wide
    private var active = false
    private var inFlight = false
    private var frames = [Data]()
    private var desiredCount = 1
    private var manualFrameDurations: [String: (min: CMTime, max: CMTime)] = [:]
    private var savedFrameDurations: (min: CMTime, max: CMTime)?
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
    private var requestedFlash = CameraFlash.off
    private var rawRequested = false
    private var rawData: Data?
    private var nightRawFrames = [Data]()
    private var hdrPlan: [FrameExposure] = []
    private var hdrExposures: [FrameExposure] = []
    private var lastHDRTimestamp: Double?
    private var nightFrameSeconds: Double = 0
    private var lastNightTimestamp: Double?
    private var exportedResult: URL?
    private var captureRecoveryRequired = false
    private var focusToken = UUID()
    private var savedKinds = Set<String>()
    private var processingCancellation: ProcessingCancellation?
    @Published private(set) var processingInProgress = false
    @Published private(set) var importFailure: String?
    @Published private(set) var importedPhotoID: UUID?
    @Published private(set) var previewAnalysisFrame: PreviewAnalysisFrame?
    private var previewTools = PreviewAnalysisOptions()
    private lazy var previewAnalyzer = PreviewAnalysisController { [weak self] frame in self?.previewAnalysisFrame=frame }

    override init() {
        super.init()
        diagnosticBridge = DiagnosticBridge(capture: { [weak self] request in
            self?.capture(stack: request.stack, count: request.count, raw: request.raw, flash: request.flash, options: request.options,mirrorSelfie:request.mirrorSelfie)
        }, command: { [weak self] object in self?.diagnosticCommand(object) })
        CaptureTrace.record("model.init", [
            "processingDelegate": responds(to: NSSelectorFromString("captureOutput:didFinishProcessingPhoto:error:")),
            "completionDelegate": responds(to: NSSelectorFromString("captureOutput:didFinishCaptureForResolvedSettings:error:"))
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
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
                try configure(configuredLens)
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            if rotationCoordinator==nil,let device=input?.device { rotationCoordinator=AVCaptureDevice.RotationCoordinator(device:device,previewLayer:nil) }
            let rawAvailable = !output.availableRawPhotoPixelFormatTypes.isEmpty
            publish { self.supportsRAW = rawAvailable }
            let available = self.session.isRunning && !self.interrupted
            previewAnalyzer.setActive(available && previewTools.enabled)
            CaptureTrace.record("session.ready", ["running": available, "inputs": session.inputs.count, "outputs": session.outputs.count])
            publish { self.ready = available }
            message("Lista. La pila es experimental y requiere una escena inmóvil.")
        } catch { message(error.localizedDescription) }
    }

    @objc private func memoryWarning() {
        queue.async {
            if self.processingCancellation != nil {
                CaptureTrace.record("processing.memoryWarning")
                self.processingCancellation?.cancel("Procesado detenido por presión de memoria; se conserva la referencia.")
            }
        }
    }

    func cancelProcessing() {
        queue.async {
            guard let cancellation = self.processingCancellation else { return }
            cancellation.cancel(self.captureStage == "importing" ? "Importación cancelada. La foto de Fotos no se ha modificado." : "Procesado cancelado; se conserva la referencia.")
            self.publish { self.processingInProgress = false }
            self.message("Recuperando referencia…")
        }
    }

    func importPhoto(_ data: Data, options: ProcessingOptions) {
        queue.async {
            guard !self.inFlight, !self.captureRecoveryRequired else { return }
            self.inFlight = true; self.transaction = UUID(); self.captureStage = "importing"
            let token = self.transaction, cancellation = ProcessingCancellation()
            self.processingCancellation = cancellation
            self.publish { self.busy = true; self.processingInProgress = true; self.status = "Procesando foto seleccionada…" }
            self.queue.asyncAfter(deadline: .now() + 90) {
                guard self.inFlight, self.transaction == token, self.captureStage == "importing" else { return }
                cancellation.cancel("La importación superó 90 segundos.")
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard self.inFlight, self.transaction == token, self.captureStage == "importing" else { return }
                    self.captureRecoveryRequired = true
                    self.finishFailure(CameraFailure.message("El procesado de importación no respondió. Reabre Ultimate CAM."))
                }
            }
            self.processing.async {
                let outcome = Result { try autoreleasepool { try ImportedPhotoProcessor.process(data, options: options, cancellation: cancellation) } }
                let previews: (UIImage?, UIImage?)
                if case .success(let result) = outcome {
                    let image = PreviewDecoder.image(result.jpeg).map { UIImage(cgImage: $0) }
                    previews = (image, result.jpeg == result.reference ? image : PreviewDecoder.image(result.reference).map { UIImage(cgImage: $0) })
                } else { previews = (nil, nil) }
                self.queue.async {
                    guard self.inFlight, self.transaction == token else { return }
                    self.processingCancellation = nil
                    switch outcome {
                    case .failure(let error): self.finishFailure(error); self.reportImportError(error.localizedDescription)
                    case .success(let result):
                        self.result = result; self.savedKinds = []; self.exportedResult = nil
                        self.inFlight = false; self.captureStage = "idle"
                        CaptureTrace.record("import.success", ["bytes": result.jpeg.count, "source": result.source])
                        self.publish {
                            self.preview = previews.0; self.referencePreview = previews.1
                            self.resultDetails = result.details; self.resultStatistics = result.statistics
                            self.hasRAWResult = false; self.hasSeparateReference = result.jpeg != result.reference
                            self.savedResult = false; self.savedJPEGOnly = false
                            self.processingInProgress = false; self.busy = false
                            self.importedPhotoID = UUID()
                            self.status = "Foto importada preparada para revisar."
                        }
                    }
                }
            }
        }
    }

    func reportImportError(_ text: String) { publish { self.importFailure = text; self.status = text } }
    func clearImportError() { publish { self.importFailure = nil } }

    func stop() {
        queue.async {
            self.active = false
            self.rotationCoordinator=nil
            self.previewAnalyzer.setActive(false)
            self.focusToken = UUID()
            self.publish { self.ready = false }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func prepareNativeHandoff(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.inFlight else { self.publish { completion(false) }; return }
            self.active=false;self.focusToken=UUID()
            self.rotationCoordinator=nil
            self.previewAnalyzer.setActive(false)
            if self.session.isRunning { self.session.stopRunning() }
            let stopped = !self.session.isRunning
            CaptureTrace.record("nativeNight.handoff",["sessionStopped":stopped])
            self.publish { self.ready=false;completion(stopped) }
        }
    }

    func resumeAfterAuxiliary() {
        queue.async {
            guard !self.inFlight else { return }
            self.configured=false
            self.activate()
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
        if let saved = manualFrameDurations.removeValue(forKey: device.uniqueID) {
            restoreFrameDurations(saved, on: device)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
        device.setExposureTargetBias(0, completionHandler: nil)
        device.unlockForConfiguration()
        let manualAvailable = device.isExposureModeSupported(.custom)
        let focusAvailable = device.isLockingFocusWithCustomLensPositionSupported
        let zoom = max(1, min(8, Double(device.maxAvailableVideoZoomFactor)))
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
        configurePreviewOutput()
        session.commitConfiguration()
        committed = true
        configuredLens=lens
        rotationCoordinator=AVCaptureDevice.RotationCoordinator(device:device,previewLayer:nil)
        let rawAvailable = !output.availableRawPhotoPixelFormatTypes.isEmpty
        publish {
            self.selectedLens = lens
            self.isoRange = isoLimits
            self.shutterRange = shutterLimits
            self.supportsRAW = rawAvailable
            self.supportsFlash = device.hasFlash && self.output.supportedFlashModes.contains(.on)
            self.supportsManualExposure = manualAvailable
            self.supportsManualFocus = focusAvailable
            self.supportsManualWB = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            self.maximumZoom = zoom
            self.zoomFactor = Double(device.videoZoomFactor)
            self.isFocusLocked = false
            self.focusStatus = device.isFocusPointOfInterestSupported ? "Toca para enfocar · mantén para bloquear" : "Lente de enfoque fijo · toca para medir la luz"
        }
        CaptureTrace.record("lens.ready", ["lens": lens.rawValue, "raw": rawAvailable,
            "manualExposure": manualAvailable, "manualFocus": focusAvailable,
            "tapFocus": device.isFocusPointOfInterestSupported,
            "manualWB": device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            "flash": device.hasFlash && output.supportedFlashModes.contains(.on)])
    }

    func setPreviewTools(_ tools:PreviewAnalysisOptions,processing:ProcessingOptions) {
        queue.async {
            let graphChanged=self.session.outputs.contains(where:{$0===self.previewAnalyzer.output}) != tools.enabled
            self.previewTools=tools;self.previewAnalyzer.configure(tools,processing:processing)
            guard self.configured,!self.inFlight else { return }
            if graphChanged { self.session.beginConfiguration();self.configurePreviewOutput();self.session.commitConfiguration() }
            self.previewAnalyzer.setActive(self.active && tools.enabled)
        }
    }
    private func configurePreviewOutput() {
        let data=previewAnalyzer.output
        if previewTools.enabled {
            if !session.outputs.contains(where:{$0===data}),session.canAddOutput(data) { session.addOutput(data) }
            if let connection=data.connection(with:.video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle=90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring=false
                    connection.isVideoMirrored=input?.device.position == .front
                }
            }
        } else if session.outputs.contains(where:{$0===data}) { session.removeOutput(data) }
        previewAnalyzer.setActive(active && previewTools.enabled)
    }

    func setBias(_ bias: Float) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(min(device.maxExposureTargetBias,
                    max(device.minExposureTargetBias, bias))) { _ in
                    CaptureTrace.record("control.bias", ["requested": bias, "applied": device.exposureTargetBias])
                }
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
                    if self.manualFrameDurations[device.uniqueID] == nil {
                        self.manualFrameDurations[device.uniqueID] = (device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration)
                    }
                    let clampedISO = min(device.activeFormat.maxISO, max(device.activeFormat.minISO, Float(iso)))
                    let duration = min(device.activeFormat.maxExposureDuration.seconds,
                                       max(device.activeFormat.minExposureDuration.seconds, seconds))
                    device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                                                 iso: clampedISO) { _ in
                        CaptureTrace.record("control.exposure", ["iso": device.iso, "seconds": device.exposureDuration.seconds, "custom": true])
                    }
                } else if iso == nil, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    if let saved = self.manualFrameDurations.removeValue(forKey: device.uniqueID) {
                        self.restoreFrameDurations(saved, on: device)
                    }
                    CaptureTrace.record("control.exposure", ["custom": false,
                        "minFrameSeconds": device.activeVideoMinFrameDuration.seconds,
                        "maxFrameSeconds": device.activeVideoMaxFrameDuration.seconds])
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
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.finishFocus(token, device: device, lock: lock, remaining: device.exposureDuration.seconds > 1.0 / 30 ? 80 : 20) }
            } catch { self.message(error.localizedDescription) }
        }
    }

    private func finishFocus(_ token: UUID, device: AVCaptureDevice, lock: Bool, remaining: Int, stable: Int = 0) {
        guard token == focusToken, active, input?.device === device else { return }
        if inFlight {
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + 0.2) { self.finishFocus(token, device: device, lock: lock, remaining: remaining - 1) }
            } else { publish { self.focusStatus = "Toca el visor para enfocar" } }
            return
        }
        // A newly requested one-shot AF can still report adjusting=false before
        // its scan starts. Wait for it to leave autoFocus and remain stable.
        if device.isAdjustingFocus || device.isAdjustingExposure || device.focusMode == .autoFocus {
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + 0.15) { self.finishFocus(token, device: device, lock: lock, remaining: remaining - 1) }
            } else {
                publish { self.focusStatus = "No se ha estabilizado el enfoque. Prueba un borde con más contraste." }
                CaptureTrace.record("focus.unsettled")
            }
            return
        }
        if stable < 2 {
            queue.asyncAfter(deadline: .now() + 0.15) {
                self.finishFocus(token, device: device, lock: lock, remaining: remaining, stable: stable + 1)
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
            let focusLocked = lock && device.isFocusPointOfInterestSupported && device.focusMode == .locked
            let exposureLocked = lock && device.exposureMode == .locked
            let locked = focusLocked || exposureLocked
            let label: String
            if focusLocked && exposureLocked { label = "AF / AE bloqueados · toca para liberar" }
            else if focusLocked { label = "Enfoque bloqueado · exposición manual" }
            else if exposureLocked { label = "Exposición bloqueada · lente fija" }
            else { label = device.isFocusPointOfInterestSupported ? "Enfoque ajustado" : "Enfoque fijo · luz ajustada" }
            publish {
                self.isFocusLocked = locked
                self.focusStatus = label
            }
            CaptureTrace.record("focus.settled", ["locked": locked, "focusLocked": focusLocked,
                "exposureLocked": exposureLocked, "position": device.lensPosition,
                "focusMode": device.focusMode.rawValue, "exposureMode": device.exposureMode.rawValue])
        } catch { message(error.localizedDescription) }
    }

    func setZoom(_ zoom: Double) {
        queue.async {
            guard zoom.isFinite, !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = min(min(8, device.maxAvailableVideoZoomFactor), max(max(1, device.minAvailableVideoZoomFactor), CGFloat(zoom)))
                let applied = Double(device.videoZoomFactor)
                self.publish { self.zoomFactor = applied }
                CaptureTrace.record("control.zoom", ["requested": zoom, "applied": device.videoZoomFactor])
            } catch { self.message(error.localizedDescription) }
        }
    }

    func setWhiteBalance(_ kelvin: Float?, tint: Float = 0) {
        queue.async {
            guard !self.inFlight, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let kelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    guard kelvin.isFinite, tint.isFinite else { return }
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: min(8000, max(2500, kelvin)), tint: min(100, max(-100, tint)))
                    var gains = device.deviceWhiteBalanceGains(for: values)
                    gains.redGain = min(device.maxWhiteBalanceGain, max(1, gains.redGain))
                    gains.greenGain = min(device.maxWhiteBalanceGain, max(1, gains.greenGain))
                    gains.blueGain = min(device.maxWhiteBalanceGain, max(1, gains.blueGain))
                    device.setWhiteBalanceModeLocked(with: gains) { _ in
                        CaptureTrace.record("control.whiteBalance", ["manual": true,
                            "temperature": values.temperature, "tint": values.tint,
                            "redGain": device.deviceWhiteBalanceGains.redGain,
                            "greenGain": device.deviceWhiteBalanceGains.greenGain,
                            "blueGain": device.deviceWhiteBalanceGains.blueGain])
                    }
                } else if kelvin == nil && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    CaptureTrace.record("control.whiteBalance", ["manual": false])
                } else { self.message("Esta cámara no admite ese control de balance de blancos.") }
            } catch { self.message(error.localizedDescription) }
        }
    }

    func capture(stack: Bool, count: Int = 3, raw: Bool = false, flash: CameraFlash = .off, options: ProcessingOptions = ProcessingOptions(),mirrorSelfie:Bool=false) {
        queue.async {
            guard self.active, self.session.isRunning, !self.interrupted, !self.inFlight, !self.captureRecoveryRequired,
                  let device = self.input?.device else { return }
            do { _ = try options.validated() } catch { self.message(error.localizedDescription); return }
            let night = options.nightStatic, hdr = options.hdrBracketing
            let burst = stack || night || hdr
            guard !raw || (!burst && !self.output.availableRawPhotoPixelFormatTypes.isEmpty) else {
                self.message(burst ? "HDR y Pila usan JPEG; RAW se activa en Foto o en Noche experimental." : "Esta cámara no admite RAW.")
                CaptureTrace.record("capture.rejected", ["reason": "RAW unavailable in this configuration"])
                return
            }
            guard flash == .off || (!burst && !raw && device.hasFlash && device.isFlashAvailable &&
                  self.output.supportedFlashModes.contains(flash.mode)) else {
                self.message("El flash no está disponible. Usa Foto JPEG y una cámara con flash preparado.")
                CaptureTrace.record("capture.rejected", ["reason": "flash unavailable in this configuration"])
                return
            }
            self.requestedFlash = flash
            self.inFlight = true
            self.transaction = UUID()
            self.frames = []
            self.nightRawFrames = []
            self.hdrPlan = []; self.hdrExposures = []; self.lastHDRTimestamp = nil
            self.nightFrameSeconds = 0
            self.lastNightTimestamp = nil
            self.desiredCount = hdr ? 3 : (burst ? min(9, max(3, count)) : 1)
            self.processingOptions = options
            self.rawRequested = (raw || (night && options.nightRAW)) && !self.output.availableRawPhotoPixelFormatTypes.isEmpty
            self.rawData = nil
            self.publish { self.busy = true }
            do {
                // Snapshot once for the whole transaction. A turn during a
                // temporal stack/HDR bracket must not change its pixel axes.
                guard let connection=self.output.connection(with:.video),let rotation=self.rotationCoordinator else {
                    throw CameraFailure.message("No se pudo preparar la orientación. Vuelve a abrir la cámara.")
                }
                let angle=try CaptureRotation.cardinal(Double(rotation.videoRotationAngleForHorizonLevelCapture))
                guard connection.isVideoRotationAngleSupported(CGFloat(angle)) else { throw CameraFailure.message("La cámara no admite esa orientación de foto.") }
                connection.videoRotationAngle=CGFloat(angle)
                let mirror=mirrorSelfie && device.position == .front
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring=false;connection.isVideoMirrored=mirror }
                else if mirror { throw CameraFailure.message("Esta cámara no admite guardar la selfie reflejada.") }
                if burst {
                    guard !device.isAdjustingExposure, !device.isAdjustingWhiteBalance,
                          !device.isAdjustingFocus else {
                        throw CameraFailure.message("Espera a que terminen el enfoque y la exposición y vuelve a capturar.")
                    }
                    guard device.isExposureModeSupported(.locked), device.isWhiteBalanceModeSupported(.locked) else {
                        throw CameraFailure.message("Esta cámara no admite los bloqueos necesarios para la pila.")
                    }
                    if (night || hdr) && (device.exposureMode == .custom || device.exposureMode == .locked || !device.isExposureModeSupported(.custom)) {
                        throw CameraFailure.message("Noche y HDR necesitan exposición automática: desactiva ISO manual o toca el visor para liberar AE. Puedes fijar solo el enfoque con el control manual.")
                    }
                    let plan = night ? try NightCapturePlan.make(iso: Double(device.iso), seconds: device.exposureDuration.seconds,
                        isoRange: Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO),
                        durationRange: device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds,
                        targetOffset: Double(device.exposureTargetOffset), budget: options.nightBudget,
                        shutterLimit: options.nightShutterLimit) : nil
                    let bracket = hdr ? try HDRCapturePlan.make(iso:Double(device.iso),seconds:device.exposureDuration.seconds,span:options.hdrSpan,
                        isoRange:Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO),
                        durationRange:device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds) : nil
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.exposureMode != .custom { self.savedExposure = device.exposureMode }
                    self.savedWhiteBalance = device.whiteBalanceMode
                    device.whiteBalanceMode = .locked
                    if device.isFocusModeSupported(.locked) {
                        self.savedFocus = device.focusMode
                        device.focusMode = .locked
                    }
                    if let bracket {
                        self.hdrPlan = bracket
                        self.savedFrameDurations = (device.activeVideoMinFrameDuration,device.activeVideoMaxFrameDuration)
                        self.queue.async { self.prepareHDRFrame() }
                        return
                    }
                    if let plan {
                        self.savedFrameDurations = (device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration)
                        self.desiredCount = plan.count
                        let token = self.transaction
                        CaptureTrace.record("night.plan", ["seconds": plan.seconds, "iso": plan.iso,
                            "count": plan.count, "source": self.rawRequested ? "RAW" : "JPEG",
                            "totalExposureSeconds": plan.seconds * Double(plan.count),
                            "compensationEV": plan.compensationEV, "meteredOffsetEV": device.exposureTargetOffset,
                            "minFrameSeconds": device.activeVideoMinFrameDuration.seconds, "maxFrameSeconds": device.activeVideoMaxFrameDuration.seconds])
                        self.message("Noche estática: \(plan.count) fotos. Apoya el iPhone hasta terminar.")
                        self.captureStage = "night-setup"
                        device.setExposureModeCustom(duration: CMTime(seconds: plan.seconds, preferredTimescale: 1_000_000),
                            iso: Float(plan.iso)) { _ in
                            self.queue.async {
                                guard self.inFlight, self.transaction == token else { return }
                                self.nightFrameSeconds = device.exposureDuration.seconds
                                CaptureTrace.record("night.exposure.applied", ["seconds": device.exposureDuration.seconds, "iso": device.iso])
                                self.captureNext()
                            }
                        }
                        self.queue.asyncAfter(deadline: .now() + 5) {
                            guard self.inFlight, self.transaction == token, self.captureStage == "night-setup" else { return }
                            self.captureRecoveryRequired = true
                            self.publish { self.ready = false }
                            self.finishFailure(CameraFailure.message("No se confirmó la exposición nocturna. Cierra y abre Ultimate CAM; no se ha repetido la captura."))
                        }
                        return
                    }
                    if device.exposureMode != .custom { device.exposureMode = .locked }
                }
                self.captureNext()
            } catch { self.finishFailure(error) }
        }
    }

    private func prepareHDRFrame() {
        guard inFlight, processingOptions.hdrBracketing, frames.count < hdrPlan.count,
              active, !interrupted, let device = input?.device else {
            finishFailure(CameraFailure.message("Secuencia HDR interrumpida.")); return
        }
        let index = frames.count
        let exposure = hdrPlan[index], token = transaction
        captureStage = "hdr-setup"
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(duration:CMTime(seconds:exposure.seconds,preferredTimescale:1_000_000_000),iso:Float(exposure.iso)) { _ in
                self.queue.async {
                    guard self.inFlight, self.transaction == token, self.captureStage == "hdr-setup", self.frames.count == index else { return }
                    CaptureTrace.record("hdr.exposure.applied",["index":self.frames.count,"seconds":device.exposureDuration.seconds,"iso":device.iso])
                    self.captureNext()
                }
            }
        } catch { finishFailure(error); return }
        queue.asyncAfter(deadline:.now()+5) {
            guard self.inFlight, self.transaction == token, self.captureStage == "hdr-setup", self.frames.count == index else { return }
            self.captureRecoveryRequired = true
            self.publish { self.ready = false }
            self.finishFailure(CameraFailure.message("No se confirmó la exposición HDR. Reabre la app; no se repetirá la captura."))
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
        settings.flashMode = requestedFlash.mode
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        let priority = PhotoCapturePolicy.priority(requested: processingOptions.singlePhotoQuality,
            count: desiredCount, raw: rawRequested, customExposure: input?.device.exposureMode == .custom,
            lockedExposure: input?.device.exposureMode == .locked)
        switch priority {
        case .speed: settings.photoQualityPrioritization = .speed
        case .balanced: settings.photoQualityPrioritization = .balanced
        case .quality: settings.photoQualityPrioritization = .quality
        }
        let identifier = settings.uniqueID
        captureStage = "requested"
        CaptureTrace.record("capture.request", ["id": identifier,
            "running": session.isRunning, "enabled": connection.isEnabled,
            "active": connection.isActive, "quality": settings.photoQualityPrioritization.rawValue,
            "width": settings.maxPhotoDimensions.width, "height": settings.maxPhotoDimensions.height,
            "count": desiredCount, "raw": rawRequested, "flash": requestedFlash.rawValue,"rotationAngle":connection.videoRotationAngle,"mirrored":connection.isVideoMirrored])
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
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let sensorExposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? -1
        let sensorISO = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? -1
        let timestamp = photo.timestamp.seconds.isFinite ? photo.timestamp.seconds : -1
        CaptureTrace.record("delegate.processing.enter", ["id": photo.resolvedSettings.uniqueID,
            "sensorTimestamp": timestamp, "exposureSeconds": sensorExposure, "iso": sensorISO,
            "raw": photo.isRawPhoto, "flashEnabled": photo.resolvedSettings.isFlashEnabled,
            "error": error?.localizedDescription ?? "none"])
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
                if isRaw {
                    if self.processingOptions.nightStatic {
                        if let last = self.lastNightTimestamp, timestamp >= 0 && timestamp <= last {
                            self.finishFailure(CameraFailure.message("El sensor devolvió un fotograma RAW repetido. No se ha fusionado ni repetido la captura.")); return
                        }
                        if sensorExposure > 0, abs(sensorExposure - self.nightFrameSeconds) > max(0.003, self.nightFrameSeconds * 0.05) {
                            self.finishFailure(CameraFailure.message("La foto no respetó la exposición nocturna solicitada. No se ha fusionado ni repetido la captura.")); return
                        }
                        if timestamp >= 0 { self.lastNightTimestamp = timestamp }
                    }
                    self.rawData = data
                } else {
                    if self.processingOptions.hdrBracketing {
                        let exposure = FrameExposure(seconds:sensorExposure,iso:sensorISO)
                        guard exposure.isValid, timestamp >= 0, self.lastHDRTimestamp.map({ timestamp > $0 }) ?? true else {
                            self.finishFailure(CameraFailure.message("Fotograma HDR sin exposición válida o repetido; no se repetirá la captura.")); return
                        }
                        self.hdrExposures.append(exposure); self.lastHDRTimestamp = timestamp
                    }
                    self.frames.append(data)
                }
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
            if self.processingOptions.nightStatic, let raw = self.rawData {
                self.nightRawFrames.append(raw)
                self.rawData = nil
            }
            if self.frames.count < self.desiredCount {
                if self.processingOptions.nightStatic {
                    let token = self.transaction
                    self.captureStage = "night-wait"
                    self.queue.asyncAfter(deadline: .now() + max(0.03, self.nightFrameSeconds)) {
                        guard self.inFlight, self.transaction == token, self.captureStage == "night-wait" else { return }
                        self.captureNext()
                    }
                } else if self.processingOptions.hdrBracketing { self.prepareHDRFrame() }
                else { self.captureNext() }
                return
            }
            self.restoreDevice()
            let captured = self.frames
            let bracketExposures = self.hdrExposures
            self.hdrPlan = []; self.hdrExposures = []
            let token = self.transaction
            let options = self.processingOptions
            let raw = self.rawData
            let rawBurst: [Data]? = self.nightRawFrames.isEmpty ? nil : self.nightRawFrames
            self.nightRawFrames = []
            self.rawData = nil
            self.frames = []
            self.captureStage = "processing"
            let cancellation = ProcessingCancellation()
            self.processingCancellation = cancellation
            self.publish { self.processingInProgress = true }
            self.message("Procesando…")
            self.queue.asyncAfter(deadline: .now() + 90) {
                guard self.inFlight, self.transaction == token, self.captureStage == "processing" else { return }
                cancellation.cancel("El procesado superó 90 segundos; se conserva la referencia.")
                self.message("Recuperando referencia…")
                // A blocked framework/GPU call cannot be interrupted cooperatively.
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard self.inFlight, self.transaction == token, self.captureStage == "processing" else { return }
                    self.captureRecoveryRequired = true
                    self.publish { self.ready = false }
                    self.finishFailure(CameraFailure.message("El procesado no respondió a la cancelación. Cierra y abre Ultimate CAM; no se repetirá la captura."))
                }
            }
            self.processing.async {
                let processingStarted = ProcessInfo.processInfo.systemUptime
                let processed = Result { try autoreleasepool {
                    do {
                        let progress: (String) -> Void = { text in
                            self.queue.async {
                                guard self.transaction == token, self.inFlight, self.captureStage == "processing" else { return }
                                self.message(text)
                            }
                        }
                        var result: CaptureResult
                        if options.hdrBracketing {
                            result = try HDRProcessor().process(captured,exposures:bracketExposures,options:options,cancellation:cancellation,progress:progress)
                        } else {
                            result = try BurstProcessor().process(captured,options:options,rawFrames:rawBurst,cancellation:cancellation,progress:progress)
                        }
                        if !options.nightStatic { result.raw = raw }
                        result.statistics = ImageStatistics.measure(result.jpeg)
                        return result
                    } catch {
                        guard let first = captured.first else { throw error }
                        CaptureTrace.record("capture.processing.fallback", ["error": error.localizedDescription])
                        return CaptureResult(jpeg: first, reference: first,
                            details: "Procesado no aplicado: se conserva la referencia. " + error.localizedDescription,
                            mergedFrames: 1, raw: rawBurst?.first ?? raw, source: "reference-fallback", statistics: ImageStatistics.measure(first))
                    }
                } }
                let reviewImages: (UIImage?, UIImage?)
                if case .success(let result) = processed {
                    let primary = PreviewDecoder.image(result.jpeg).map { UIImage(cgImage: $0) }
                    let reference = result.reference == result.jpeg ? primary : PreviewDecoder.image(result.reference).map { UIImage(cgImage: $0) }
                    reviewImages = (primary, reference)
                } else { reviewImages = (nil, nil) }
                self.queue.async {
                    guard self.transaction == token, self.inFlight else { return }
                    self.processingCancellation = nil
                    switch processed {
                    case .success(let result):
                        CaptureTrace.record("capture.success", ["bytes": result.jpeg.count,
                            "mergedFrames": result.mergedFrames, "rawBytes": result.raw?.count ?? 0,
                            "details": result.details, "fusionSource": result.source,
                            "night": options.nightStatic, "rawFrames": rawBurst?.count ?? 0,
                            "processingSeconds": ProcessInfo.processInfo.systemUptime - processingStarted])
                        self.captureStage = "idle"
                        self.result = result
                        self.savedKinds = []
                        self.exportedResult = nil
                        self.publish {
                            self.preview = reviewImages.0
                            self.referencePreview = reviewImages.1
                            self.processingInProgress = false
                            self.resultDetails = result.details
                            self.resultStatistics = result.statistics
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

    /// Caller holds the device configuration lock. Order keeps min <= max throughout.
    private func restoreFrameDurations(_ saved: (min: CMTime, max: CMTime), on device: AVCaptureDevice) {
        if CMTimeCompare(saved.min, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = saved.max
            device.activeVideoMinFrameDuration = saved.min
        } else {
            device.activeVideoMinFrameDuration = saved.min
            device.activeVideoMaxFrameDuration = saved.max
        }
    }

    private func restoreDevice() {
        guard let device = input?.device,
              savedExposure != nil || savedWhiteBalance != nil || savedFocus != nil || savedFrameDurations != nil else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let mode = savedExposure { device.exposureMode = mode }
            if let saved = savedFrameDurations {
                restoreFrameDurations(saved, on: device)
                CaptureTrace.record(processingOptions.hdrBracketing ? "hdr.device.restored" : "night.device.restored", ["minFrameSeconds": device.activeVideoMinFrameDuration.seconds,
                    "maxFrameSeconds": device.activeVideoMaxFrameDuration.seconds, "exposureMode": device.exposureMode.rawValue])
                savedFrameDurations = nil
            }
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
        captureStage = "idle"
        restoreDevice()
        processingCancellation?.cancel(); processingCancellation = nil
        frames = []
        nightRawFrames = []
        hdrPlan = []; hdrExposures = []; lastHDRTimestamp = nil
        rawData = nil
        inFlight = false
        publish { self.busy = false; self.processingInProgress = false; self.status = error.localizedDescription }
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

    private func exportResult() {
        queue.async {
            guard !self.inFlight, let result = self.result else {
                CaptureTrace.record("export.failure", ["reason": "no idle result"]); return
            }
            self.inFlight = true
            let existing = self.exportedResult
            self.processing.async {
            do {
                let directory = existing ?? CaptureTrace.file.deletingLastPathComponent()
                    .appendingPathComponent("UltimateCAM-Inspection", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                if existing == nil {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try result.jpeg.write(to: directory.appendingPathComponent("result.jpg"), options: .atomic)
                    try result.reference.write(to: directory.appendingPathComponent("reference.jpg"), options: .atomic)
                    if let raw = result.raw { try raw.write(to: directory.appendingPathComponent("reference.dng"), options: .atomic) }
                    if let raw = result.raw {
                        try BurstProcessor().exportRAWDiagnostics(raw, to: directory)
                    }
                }
                self.queue.async { self.exportedResult = directory; self.inFlight = false }
                CaptureTrace.record("export.success", ["directory": directory.path, "source": result.source,
                    "raw": result.raw != nil, "mergedFrames": result.mergedFrames])
            } catch {
                self.queue.async { self.inFlight = false }
                CaptureTrace.record("export.failure", ["reason": error.localizedDescription])
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
        case "export": exportResult()
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
                else if let value = number("value", 2500...8000) {
                    if object["tint"] == nil { setWhiteBalance(Float(value)) }
                    else if let tint = number("tint", -100...100) { setWhiteBalance(Float(value), tint: Float(tint)) }
                }
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
                    "minFrameSeconds": device.activeVideoMinFrameDuration.seconds, "maxFrameSeconds": device.activeVideoMaxFrameDuration.seconds,
                    "bias": device.exposureTargetBias, "targetOffsetEV": device.exposureTargetOffset, "zoom": device.videoZoomFactor,
                    "maxExposureSeconds": device.activeFormat.maxExposureDuration.seconds,
                    "whiteBalanceMode": device.whiteBalanceMode.rawValue,
                    "redGain": device.deviceWhiteBalanceGains.redGain, "greenGain": device.deviceWhiteBalanceGains.greenGain,
                    "blueGain": device.deviceWhiteBalanceGains.blueGain,
                    "flashAvailable": device.hasFlash && device.isFlashAvailable,
                    "running": self.session.isRunning, "busy": self.inFlight])
            }
        default: break
        }
    }
}
