import AVFoundation
import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

private enum ControlPanel: String, CaseIterable, Identifiable, Hashable {
    case capture = "Fusión", manual = "Manual", processing = "Detalle", color = "Color", profiles = "Perfiles"
    var id: String { rawValue }
    static let advanced:[ControlPanel] = [.manual,.capture,.processing]
}

private enum ImportedProcessingFile {
    case lut(id: String, title: String)
    case profile(Data)
}

private enum AuxiliaryCameraMode:String,Identifiable {
    case panorama,sphere
    var id:String { rawValue }
}

private enum CompositionGuide: String, CaseIterable, Identifiable {
    case thirds = "Tercios", golden = "Áurea", center = "Centro", diagonal = "Diagonales"
    var id: String { rawValue }
}

private struct ViewfinderGrid: View {
    var guide: CompositionGuide
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let fractions: [CGFloat] = guide == .golden ? [0.382, 0.618] : [1.0/3, 2.0/3]
                if guide == .center {
                    path.move(to: CGPoint(x: geometry.size.width / 2 - 18, y: geometry.size.height / 2))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2 + 18, y: geometry.size.height / 2))
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 - 18))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 + 18))
                } else if guide == .diagonal {
                    path.move(to: .zero); path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.move(to: CGPoint(x: geometry.size.width, y: 0)); path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                }
                for fraction in (guide == .thirds || guide == .golden ? fractions : []) {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }.stroke(.white.opacity(0.32), lineWidth: 0.6)
        }.allowsHitTesting(false)
    }
}

struct CameraView: View {
    @AppStorage("hardwareCaptureButtons") private var hardwareButtons=true
    @AppStorage("mirrorSelfies") private var mirrorSelfies=false
    @StateObject private var camera = CameraModel()
    @StateObject private var movie = MovieCameraModel()
    @State private var videoMode = false
    @State private var showMovieReview = false
    @StateObject private var profiles = ProcessingProfiles()
    @State private var guide = CompositionGuide.thirds
    @State private var profileName = ""
    @State private var importFile = false
    @State private var importingLUT = false
    @State private var importingDocument = false
    @State private var pngLUTLayout = PNGLUTLayout.agcTiles
    @State private var exportFile = false
    @State private var exportData = ProfileFile(data: Data())
    @State private var fileMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackLens = CameraLens.wide
    @State private var stack = ProcessInfo.processInfo.arguments.contains("-stack-mode")
    @State private var showControls = ProcessInfo.processInfo.arguments.contains("-show-controls")
    @State private var showQuickControls = false
    @State private var colorPanel = ColorPanel.basic
    @State private var panel: ControlPanel = ProcessInfo.processInfo.arguments.contains("-processing-controls") ? .processing : .capture
    @State private var settingsPath=[ControlPanel]()
    @State private var bias: Double = 0
    @State private var manualWB = false
    @State private var temperature: Double = 5000
    @State private var tint: Double = 0
    @State private var grid = true
    @State private var showResult = false
    @State private var showPhotoPicker = false
    @State private var pendingPhotoImport = false
    @State private var pendingNativeNight = false
    @State private var auxiliaryMode:AuxiliaryCameraMode?
    @State private var openingVideo = false
    @State private var modeTransitionID=UUID()
    @State private var modeTransitionTask:Task<Void,Never>?
    @State private var previewTools = PreviewAnalysisOptions()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var showReference = false
    @State private var includeReference = false
    @State private var stackCount = 3
    @State private var rawEnabled = false
    @State private var flash = CameraFlash.off
    @State private var manualExposure = false
    @State private var iso: Double = 100
    @State private var shutterStops = log2(1.0 / 60)
    @State private var options = ProcessingOptions()
    @State private var timerSeconds = 0
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var countdownID = UUID()
    @State private var manualFocus = false
    @State private var focusPosition: Double = 0.5
    private var zoom: Double { camera.zoomFactor }
    private var lens: CameraLens { camera.selectedLens }
    private var rawAvailable:Bool {
        #if DEBUG && targetEnvironment(simulator)
        // UI-only capability fixture. The actual model/session remains unable
        // to capture RAW on the simulator; this code is absent on the device.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-raw-support") { return true }
        #endif
        return camera.supportsRAW
    }
    private var captureTitle:String {
        if options.nativeNight { return "Noche · iOS" }
        if options.hdrBracketing { return options.hdrMetalRAW ? "HDR · RAW Metal":"HDR · 3 exposiciones" }
        if options.nightStatic { return options.nightMetalRAW ? "Noche · RAW Metal":(options.nightRAW ? "Noche · RAW":"Noche · JPEG") }
        if stack { return "Pila de \(stackCount)" }
        if options.portraitAmount>0 { return "Retrato · personas" }
        if options.usesPreviewZSL && !rawEnabled { return "Cámara · ZSL Visor 1280p" }
        return rawEnabled ? "RAW + JPEG":"Cámara"
    }
    private var movieBusy:Bool { [.recording,.finishing,.saving].contains(movie.phase) }
    private var controlsEnabled: Bool { !camera.busy && !movieBusy && !loadingPhoto && !openingVideo && countdown == 0 }
    private var intrinsicMetalFusion:Bool { (options.nightStatic && options.nightMetalRAW) || (options.hdrBracketing && options.hdrMetalRAW) }
    private var intrinsicAdaptiveFusion:Bool { intrinsicMetalFusion || (options.nightStatic && (options.nightWeightedFusion || options.nightSpectralFusion)) }
    private var hardwareCaptureReady:Bool {
        hardwareButtons && (videoMode ? (movie.phase == .recording || (movie.ready && movie.phase == .idle)) : camera.ready) && !camera.busy && !loadingPhoto && !openingVideo &&
        scenePhase == .active && auxiliaryMode==nil && !showControls && !showResult && !showMovieReview && !showPhotoPicker &&
        !importFile && !exportFile && !importingDocument && camera.importFailure==nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            viewfinder.ignoresSafeArea()
                .overlay {
                    if openingVideo {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().allowsHitTesting(false)
                            .accessibilityIdentifier("camera.modeTransition").transition(.opacity)
                    }
                }.animation(.easeInOut(duration:0.2),value:openingVideo)
        }
        .onCameraCaptureEvent(isEnabled:hardwareCaptureReady) { event in
            guard event.phase == .ended else { return }
            CaptureTrace.record("ui.hardwareCapture",["timerActive":countdown>0])
            if videoMode { recordVideo() } else if countdown>0 { cancelCountdown() } else { takePhoto() }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Group { if videoMode { videoHeader } else { header } }.padding(.horizontal, 20).padding(.vertical, 10)
                if showQuickControls && !videoMode { quickControls.padding(.horizontal, 16).padding(.bottom, 12) }
            }
            .background {
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if (!videoMode && (camera.isFocusLocked || manualFocus || zoom>1.01)) || (videoMode && movie.zoom>1.01) { focusInfo.padding(.horizontal, 20).padding(.bottom, 8) }
                if camera.processingInProgress {
                    Button("Detener procesado y conservar original") { camera.cancelProcessing() }
                        .font(.footnote.bold()).buttonStyle(.bordered).tint(CameraPalette.accent).padding(.bottom, 8)
                }
                bottomDock
            }
            .background {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
            }
        }
        .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; if auxiliaryMode == nil && !openingVideo { if videoMode { movie.start(movie.configuration,lens:movie.lens) } else { camera.start() } }; loadProfile(profiles.options(for: lens.rawValue) ?? ProcessingOptions()) }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; cancelCountdown();cancelModeTransition(); profiles.flush() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true; if auxiliaryMode == nil && !openingVideo { if videoMode { movie.start(movie.configuration,lens:movie.lens) } else { camera.start() } } }
            else if phase == .background {
                UIApplication.shared.isIdleTimerDisabled = false
                cancelCountdown()
                cancelModeTransition()
                profiles.flush()
                camera.stop()
                movie.shutdown()
            }
        }
        .onChange(of: camera.selectedLens) { _, next in
            resetUIControls()
            if !loadProfile(profiles.options(for: next.rawValue) ?? ProcessingOptions()) { options = ProcessingOptions() }
            if next != .front { lastBackLens = next }
        }
        .onChange(of: options) { _, value in
            if value.singlePhotoQuality == .quality && value.zeroShutterLagFusion { options.zeroShutterLagFusion=false }
            profiles.remember(options,lens:lens.rawValue)
        }
        .onChange(of: options) { _, value in camera.setPreviewTools(previewTools,processing:value) }
        .onChange(of: previewTools) { _, value in camera.setPreviewTools(value,processing:options) }
        .onChange(of: camera.busy) { _, value in if !value { camera.setPreviewTools(previewTools,processing:options) } }
        .onChange(of: bias) { _, value in camera.setBias(Float(value)) }
        .onChange(of: stack) { _, value in if value { rawEnabled = false; flash = .off } }
        .onChange(of: rawEnabled) { _, value in if value { flash = .off } }
        .sheet(isPresented: $showControls, onDismiss: {
            settingsPath=[]
            if pendingPhotoImport { pendingPhotoImport = false; showPhotoPicker = true }
            else if pendingNativeNight { pendingNativeNight = false; activateNativeNight() }
        }) { settings }
        .sheet(isPresented: $showResult) { review }
        .sheet(isPresented: $showMovieReview) { MovieReview(camera:movie) }
        .fullScreenCover(item:$auxiliaryMode,onDismiss:{ resetUIControls();camera.resumeAfterAuxiliary() }) { mode in
            switch mode { case .panorama: GuidedPanoramaView();case .sphere: GuidedSphereView() }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images,
                      preferredItemEncoding: .current)
        .task(id: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            loadingPhoto = true
            defer { loadingPhoto = false; selectedPhoto = nil }
            do {
                guard let file = try await item.loadTransferable(type: PhotoImportTransfer.self) else {
                    throw CameraFailure.message("Fotos no devolvió la imagen seleccionada.")
                }
                defer { try? FileManager.default.removeItem(at: file.url) }
                try Task.checkCancellation()
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                camera.importPhoto(data, options: options)
            } catch is CancellationError { }
            catch { camera.reportImportError(error.localizedDescription) }
        }
        .onChange(of: camera.importedPhotoID) { _, value in if value != nil { showResult = true } }
        .alert(camera.importFailure != nil ? "No se pudo importar" : "Noche nativa", isPresented: Binding(
            get: { camera.importFailure != nil },
            set: { if !$0 { camera.clearImportError() } })) {
            Button("Aceptar",role:.cancel) { camera.clearImportError() }
        } message: { Text(camera.importFailure ?? "") }
    }

    private var header: some View {
        HStack(spacing:16) {
            Button { showQuickControls.toggle() } label: {
                Image(systemName:showQuickControls ? "chevron.up" : "chevron.down")
                    .font(.system(size:16,weight:.semibold)).frame(width:44,height:44)
                    .background(.black.opacity(0.55),in:Circle())
            }.accessibilityLabel("Ajustes rápidos").accessibilityIdentifier("camera.quickSettings")
            Spacer(minLength:0)
            Text(captureTitle)
                .font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.8))
            if abs(bias)>=0.05 && !manualExposure {
                Button { bias=0 } label: {
                    Text(String(format:"%+.1f EV",bias)).font(.system(size:11,weight:.semibold).monospacedDigit())
                        .foregroundStyle(CameraPalette.accent).padding(.horizontal,8).frame(minHeight:36)
                        .background(.black.opacity(0.65),in:Capsule())
                }.accessibilityIdentifier("camera.headerExposureBias").accessibilityLabel("Restablecer exposición")
                    .accessibilityValue(String(format:"%.1f",bias))
            }
            Spacer(minLength:0)
            Menu {
                Toggle("Cuadrícula",isOn:$grid)
                Picker("Composición",selection:$guide) { ForEach(CompositionGuide.allCases) { Text($0.rawValue).tag($0) } }
                Divider()
                Toggle("Histograma del visor",isOn:$previewTools.histogram)
                Toggle("Resaltar enfoque",isOn:$previewTools.peaking)
                Toggle("Cebras de luces",isOn:$previewTools.zebras)
                Toggle("Vista de color y LUT · 5 FPS",isOn:$previewTools.colorLook)
            } label: { Image(systemName:"viewfinder").foregroundStyle(previewTools.enabled ? CameraPalette.accent:Color.white).font(.system(size:19)).frame(width:44,height:44).background(.black.opacity(0.55),in:Circle()) }
                .accessibilityLabel("Guías y herramientas del visor").accessibilityIdentifier("camera.previewTools").disabled(!controlsEnabled)
        }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: videoMode ? movie.session:camera.session, zoom: videoMode ? movie.zoom:zoom, focus: { point, locked in
                if videoMode { movie.focus(point,locked:locked) }
                else { manualFocus = false;camera.focus(at: point, lock: locked) }
            }, changeZoom: { value in if videoMode { movie.setZoom(value) } else { camera.setZoom(value) } })
                .allowsHitTesting(controlsEnabled || (videoMode && movie.phase == .recording))
            GeometryReader { geometry in
                if !videoMode,let frame=camera.previewAnalysisFrame {
                    if let color=frame.color {
                        Image(decorative:color,scale:1).resizable().scaledToFill()
                            .frame(width:geometry.size.width,height:geometry.size.height).clipped()
                    }
                    if let overlay=frame.overlay {
                        Image(decorative:overlay,scale:1).resizable().interpolation(.none).scaledToFill()
                            .frame(width:geometry.size.width,height:geometry.size.height).clipped()
                    }
                }
            }.allowsHitTesting(false)
            if grid { ViewfinderGrid(guide: guide) }
            if !videoMode,previewTools.histogram,let frame=camera.previewAnalysisFrame {
                VStack { HStack { Spacer();PreviewMeterView(metrics:frame.metrics) };Spacer() }.padding(.top,110).padding(.trailing,18)
            }
            if !videoMode,let notice=camera.previewAnalysisFrame?.notice {
                VStack { Spacer();Text(notice).font(.caption).padding(8).background(.black.opacity(0.8)).padding(.bottom,230) }.allowsHitTesting(false)
            }
            if countdown > 0 {
                Text("\(countdown)").font(.system(size: 80, weight: .light, design: .rounded))
                    .shadow(color: .black, radius: 10).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var quickControls: some View {
        VStack(spacing:8) {
        HStack(spacing: 8) {
            quickButton(PhotoModePolicy.formatLabel(options,photoRAW:rawEnabled),symbol:"square.stack.3d.up",
                        selected:options.nightStatic ? options.nightMetalRAW:(options.hdrBracketing ? options.hdrMetalRAW:rawEnabled)) {
                let next=PhotoModePolicy.toggledRAW(options,photoRAW:rawEnabled,supportsRAW:rawAvailable)
                options=next.options;rawEnabled=next.photoRAW
            }.disabled(options.nativeNight || !rawAvailable || (stack && !options.nightStatic && !options.hdrBracketing))
                .accessibilityIdentifier("camera.quickFormat").accessibilityValue(PhotoModePolicy.formatLabel(options,photoRAW:rawEnabled))
            Spacer()
            Menu {
                ForEach(CameraFlash.allCases) { item in
                    Button("Flash \(item.label)") { flash = item }
                }
            } label: {
                Label(flash.label, systemImage: flash == .off ? "bolt.slash.fill" : "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(flash == .off ? Color.white : CameraPalette.accent)
                    .padding(.horizontal, 10).frame(height: 40)
                    .background(.black.opacity(0.75), in: Capsule())
            }.accessibilityLabel("Flash \(flash.label)")
                .disabled(!controlsEnabled || !camera.supportsFlash || stack || rawEnabled || options.nativeNight)
            quickButton(timerSeconds == 0 ? "OFF" : "\(timerSeconds)s", symbol: "timer", selected: timerSeconds > 0) {
                timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
            }
            quickButton("", symbol: "grid", selected: grid) { grid.toggle() }
        }
        if !manualExposure { exposureCompensation }
        }
    }

    private var exposureCompensation:some View {
        HStack(spacing:10) {
            Image(systemName:"sun.max.fill").foregroundStyle(CameraPalette.accent).accessibilityHidden(true)
            Slider(value:$bias,in:-2...2,step:0.1).accessibilityLabel("Compensación de exposición")
                .accessibilityIdentifier("camera.exposureBias")
            Button { bias=0 } label: {
                Text(String(format:"%+.1f EV",bias)).font(.system(size:12,weight:.semibold).monospacedDigit()).frame(minWidth:68,minHeight:40)
            }.accessibilityLabel("Restablecer exposición").accessibilityIdentifier("camera.resetExposureBias")
                .accessibilityValue(String(format:"%.1f",bias))
        }.padding(.horizontal,12).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:16))
            .tint(CameraPalette.accent).disabled(!controlsEnabled)
    }

    private var focusInfo: some View {
        HStack {
            if !videoMode && (manualFocus || camera.isFocusLocked) {
            Text(manualFocus ? "Enfoque manual · toca para volver a AF" : camera.focusStatus)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.7), in: Capsule())
                .allowsHitTesting(false)
            if camera.isFocusLocked {
                Button {
                    manualFocus = false
                    camera.focus(at: CGPoint(x: 0.5, y: 0.5))
                } label: {
                    Image(systemName: "lock.open.fill").frame(width: 44, height: 44)
                        .background(.black.opacity(0.7), in: Circle())
                }.accessibilityLabel("Liberar bloqueo de cámara")
                    .disabled(!controlsEnabled)
            }
            }
            Spacer(minLength:0)
            if (videoMode ? movie.zoom:zoom)>1.01 {
                Button {
                    if videoMode { movie.setZoom(1,smooth:true) } else { camera.setZoom(1,smooth:true) }
                } label: {
                    Text("\(videoMode ? movie.zoom:zoom, specifier: "%.1f")×").font(.caption.monospacedDigit().bold())
                        .padding(.horizontal,12).frame(minHeight:44).background(.black.opacity(0.7),in:Capsule())
                }.accessibilityIdentifier("camera.resetZoom").accessibilityLabel("Restablecer zoom a 1×")
                    .disabled(!controlsEnabled && !(videoMode && movie.phase == .recording))
            }
        }
    }

    private func quickButton(_ text: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if !text.isEmpty { Text(text).font(.system(size: 11, weight: .bold)) }
            }
            .foregroundStyle(selected ? CameraPalette.accent : .white)
            .padding(.horizontal, 12).frame(height: 40)
            .background(.black.opacity(0.75), in: Capsule())
        }.disabled(!controlsEnabled)
        .accessibilityLabel(symbol == "grid" ? "Cuadrícula" : (symbol == "timer" ? "Temporizador \(text)" : "Formato \(text)"))
    }

    private var bottomDock: some View {
        VStack(spacing: 10) {
            if videoMode { videoCaptureControls } else {
            HStack(spacing:12) {
                Button { settingsPath=[.profiles];showControls = true } label: { Image(systemName:"person.crop.square").frame(width:44,height:44) }
                    .accessibilityLabel("Perfiles de lente")
                Spacer(minLength:0)
                HStack(spacing:4) {
                    ForEach(camera.lenses.filter { $0 != .front }) { item in
                        Button { camera.switchLens(item) } label: {
                            Text(item.label).font(.system(size:13,weight:.semibold))
                                .foregroundStyle(lens == item ? .black : .white)
                                .frame(width:42,height:36).background(lens == item ? CameraPalette.accent : Color(white:0.14),in:Capsule())
                        }.accessibilityLabel("Cámara \(item.label)")
                    }
                }.padding(4).background(.black.opacity(0.6),in:Capsule())
                Spacer(minLength:0)
                Button { settingsPath=[.color];showControls = true } label: { Image(systemName:"cube.transparent").frame(width:44,height:44) }
                    .accessibilityLabel("LUT y color")
            }.disabled(!controlsEnabled)
            HStack {
                Menu {
                    Button("Revisar última captura") { showResult = true }.disabled(camera.preview == nil)
                    Button("Importar desde Fotos") { showPhotoPicker = true }
                } label: {
                    Group {
                        if let preview = camera.preview { Image(uiImage: preview).resizable().scaledToFill() }
                        else { Image(systemName: "photo.on.rectangle").font(.title3).foregroundStyle(.white.opacity(0.7)) }
                    }.frame(width: 50, height: 50).background(Color(white: 0.15))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.4),lineWidth:2))
                }.accessibilityLabel("Galería e importación").accessibilityIdentifier("camera.gallery").disabled(!controlsEnabled)
                Spacer()
                Button { countdown > 0 ? cancelCountdown() : takePhoto() } label: {
                    ZStack {
                        Circle().stroke(camera.busy ? .white.opacity(0.25):.white, lineWidth: 3)
                        if camera.busy {
                            Circle().trim(from:0,to:camera.captureProgress).stroke(CameraPalette.accent,style:StrokeStyle(lineWidth:4,lineCap:.round))
                                .rotationEffect(.degrees(-90)).animation(.linear(duration:0.18),value:camera.captureProgress)
                        }
                        Circle().fill(countdown > 0 ? CameraPalette.accent : .white).padding(7)
                        if camera.busy && camera.opticalCaptureInProgress { Image(systemName:"camera.aperture").font(.title2).foregroundStyle(.black) }
                        else if camera.busy { ProgressView().tint(.black).scaleEffect(1.2) }
                        else if countdown > 0 { Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.black) }
                    }.frame(width: 72, height: 72)
                }.accessibilityLabel(countdown > 0 ? "Cancelar temporizador" : (options.nightStatic ? "Capturar noche estática" : (stack ? "Capturar pila de \(stackCount) fotos" : "Tomar foto")))
                    .accessibilityIdentifier("camera.shutter").disabled(camera.busy || loadingPhoto || (!camera.ready && countdown == 0))
                Spacer()
                Button { camera.switchLens(lens == .front ? lastBackLens : .front) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 23))
                        .frame(width: 50, height: 50).background(Color(white: 0.15), in: Circle())
                }.accessibilityLabel("Cambiar entre cámara frontal y trasera")
                    .disabled(!controlsEnabled || !camera.ready || !camera.lenses.contains(.front))
            }
            }
            modeSelector
            if !videoMode && (camera.busy || !camera.ready) {
                Text(capturePhaseText).font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth:.infinity,minHeight:30).accessibilityIdentifier("camera.status")
            }
        }.padding(.horizontal,20).padding(.top,10).padding(.bottom,5).tint(CameraPalette.accent)
    }

    private var capturePhaseText:String {
        guard camera.busy else { return camera.status }
        if camera.opticalCaptureInProgress { return options.nativeNight ? "Noche de iOS · mantén firme el iPhone…":"Mantén firme el iPhone…" }
        if camera.captureProgress>=1 || camera.processingInProgress { return "Procesando foto · ya puedes mover el iPhone" }
        return "Preparando captura…"
    }

    private var modeSelector:some View {
            HStack(spacing:4) {
                ScrollViewReader { proxy in ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:4) {
                        modeButton("Noche",selected:options.nightStatic) { applyPreset("Noche estática") }.accessibilityIdentifier("camera.mode.night").id("night")
                        modeButton("Cámara",selected:!options.nativeNight && !stack && !options.nightStatic && !options.hdrBracketing && options.portraitAmount==0) { options.nativeNight=false;options.nightStatic=false;options.hdrBracketing=false;options.portraitAmount=0;stack=false }.accessibilityIdentifier("camera.mode.photo").id("photo")
                        modeButton("Retrato",selected:!stack && !options.hdrBracketing && options.portraitAmount>0) {
                            options.nativeNight=false;options.nightStatic=false;options.hdrBracketing=false;options.portraitAmount=0.5;stack=false
                        }.accessibilityIdentifier("camera.mode.portrait").id("portrait")
                        modeButton("HDR",selected:options.hdrBracketing) { activateHDR() }.accessibilityIdentifier("camera.mode.hdr").id("hdr")
                        modeButton("Pila",selected:stack && !options.nightStatic && !options.hdrBracketing) { options.nativeNight=false;options.nightStatic=false;options.hdrBracketing=false;options.portraitAmount=0;stack=true }.accessibilityIdentifier("camera.mode.stack").id("stack")
                        modeButton("Vídeo",selected:videoMode,photoMode:false) { enterVideo() }.accessibilityIdentifier("camera.mode.video").id("video")
                        modeButton("Panorama",selected:false) { openAuxiliary(.panorama) }.accessibilityIdentifier("camera.mode.panorama")
                        modeButton("Esfera",selected:false) { openAuxiliary(.sphere) }.accessibilityIdentifier("camera.mode.sphere")
                        modeButton("iOS",selected:options.nativeNight) { activateNativeNight() }.accessibilityIdentifier("camera.mode.nativeNight").id("native")
                    }
                }.accessibilityIdentifier("camera.modes")
                    .onChange(of:selectedPhotoMode) { _,value in withAnimation(.easeOut(duration:0.2)) { proxy.scrollTo(value,anchor:.center) } }
                }
                Button { showControls = true } label: { Image(systemName:"gearshape").font(.system(size:19)).frame(width:44,height:44) }
                    .accessibilityIdentifier("camera.settings")
                    .accessibilityLabel("Ajustes de cámara")
            }.disabled(!controlsEnabled)
    }

    private var selectedPhotoMode:String {
        if videoMode { return "video" }
        if options.nativeNight { return "native" };if options.nightStatic { return "night" };if options.hdrBracketing { return "hdr" }
        if stack { return "stack" };return options.portraitAmount>0 ? "portrait":"photo"
    }

    private func modeButton(_ title: String, selected: Bool, photoMode:Bool=true, action: @escaping () -> Void) -> some View {
        let highlighted=selected && (!photoMode || !videoMode)
        return Button { if videoMode && photoMode { leaveVideo(then:action) } else if !videoMode || photoMode { action() } } label: {
            Text(title).font(.system(size: 13, weight: .bold)).tracking(1)
                .foregroundStyle(highlighted ? CameraPalette.accent : .white.opacity(0.65))
                .padding(.horizontal, 12).frame(height: 38)
                .background(highlighted ? Color(white: 0.16) : .clear, in: Capsule())
        }.accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func openAuxiliary(_ mode:AuxiliaryCameraMode) {
        openingVideo=true
        camera.prepareNativeHandoff { accepted in
            openingVideo=false
            if accepted && scenePhase == .active { auxiliaryMode=mode }
            else if scenePhase == .active { camera.start() }
        }
    }

    private func enterVideo() {
        guard controlsEnabled,!videoMode else { return }
        cancelCountdown();showQuickControls=false
        beginModeTransition { token in
            camera.prepareNativeHandoff { accepted in
                guard token==modeTransitionID,scenePhase == .active else { return }
                if accepted { videoMode=true;movie.start(movie.configuration,lens:lens) }
                else { camera.start() }
                finishModeTransition(token)
            }
        }
    }
    private func leaveVideo(then action:@escaping ()->Void) {
        guard !movieBusy,!openingVideo else { return }
        beginModeTransition { token in
            movie.shutdown {
                guard token==modeTransitionID,scenePhase == .active else { return }
                videoMode=false;resetUIControls()
                // Rebuild photo input settings after movie changed activeFormat.
                camera.resumeAfterAuxiliary();action();finishModeTransition(token)
            }
        }
    }
    private func beginModeTransition(_ operation:@escaping (UUID)->Void) {
        modeTransitionTask?.cancel();modeTransitionID=UUID();openingVideo=true
        let token=modeTransitionID
        modeTransitionTask=Task { @MainActor in
            do { try await Task.sleep(nanoseconds:200_000_000) } catch { return }
            guard token==modeTransitionID,scenePhase == .active else { return }
            operation(token)
        }
    }
    private func finishModeTransition(_ token:UUID) {
        modeTransitionTask=Task { @MainActor in
            // Cover the session handoff until ready, with a bounded fallback
            // for simulator/denied-permission sessions that never become ready.
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds:50_000_000) } catch { return }
                guard token==modeTransitionID,scenePhase == .active else { return }
                if videoMode ? movie.ready:camera.ready { break }
            }
            guard token==modeTransitionID else { return }
            openingVideo=false;modeTransitionTask=nil
        }
    }
    private func cancelModeTransition() {
        modeTransitionTask?.cancel();modeTransitionTask=nil;modeTransitionID=UUID();openingVideo=false
    }
    private func recordVideo() {
        if movie.phase == .recording { movie.stopRecording() }
        else if movie.phase == .review { showMovieReview=true }
        else { movie.record(mirrorSelfie:mirrorSelfies) }
    }
    private func updateMovie(_ change:(inout MovieConfiguration)->Void) {
        var request=movie.configuration;change(&request);movie.configure(request,lens:movie.lens)
    }
    private var videoHeader:some View {
        HStack(spacing:12) {
            Button { movie.toggleTorch() } label: { Image(systemName:movie.torch ? "bolt.fill":"bolt.slash").frame(width:44,height:44) }
                .accessibilityLabel("Antorcha").disabled(!movie.torchAvailable || movie.phase == .finishing)
            Spacer(minLength:0)
            if movie.phase == .recording {
                Text(String(format:"%02d:%02d",Int(movie.elapsed)/60,Int(movie.elapsed)%60))
                    .font(.headline.monospacedDigit()).padding(.horizontal,14).padding(.vertical,8)
                    .background(.red,in:Capsule()).accessibilityIdentifier("video.timer")
            } else {
                Menu { ForEach(MovieResolution.allCases) { resolution in Button(resolution.label) { updateMovie { $0.resolution=resolution } } } }
                    label: { Text(movie.configuration.resolution.label).font(.subheadline.bold()).padding(10).background(.ultraThinMaterial,in:Capsule()) }
                    .accessibilityIdentifier("video.quickResolution").disabled(movieBusy || openingVideo)
                Menu { ForEach([24,30,60],id:\.self) { fps in Button("\(fps) FPS") { updateMovie { $0.fps=fps } } } }
                    label: { Text("\(movie.configuration.fps) FPS").font(.subheadline.bold()).padding(10).background(.ultraThinMaterial,in:Capsule()) }
                    .accessibilityIdentifier("video.quickFPS").disabled(movieBusy || openingVideo)
            }
            Spacer(minLength:0)
        }
    }
    private var videoCaptureControls:some View {
        VStack(spacing:14) {
            HStack(spacing:8) {
                ForEach(movie.lenses.filter { $0 != .front }) { item in
                    Button(item.label) { movie.configure(movie.configuration,lens:item) }
                        .font(.subheadline.bold()).frame(width:44,height:36)
                        .background(movie.lens==item ? CameraPalette.accent:Color(white:0.14),in:Capsule())
                        .foregroundStyle(movie.lens==item ? .black:.white)
                }
            }.disabled(movieBusy || openingVideo)
            HStack {
                Button { showMovieReview=true } label: { Image(systemName:"play.rectangle").font(.title2).frame(width:50,height:50) }
                    .accessibilityLabel("Revisar vídeo").accessibilityIdentifier("video.gallery").disabled(movie.previewURL==nil || movieBusy)
                Spacer()
                Button { recordVideo() } label: {
                    ZStack {
                        Circle().stroke(.white,lineWidth:3).frame(width:76,height:76)
                        RoundedRectangle(cornerRadius:movie.phase == .recording ? 6:32).fill(.red)
                            .frame(width:movie.phase == .recording ? 30:60,height:movie.phase == .recording ? 30:60)
                        if movie.phase == .finishing || movie.phase == .saving { ProgressView().tint(.white) }
                    }
                }.accessibilityIdentifier("video.record").accessibilityLabel(movie.phase == .recording ? "Detener vídeo":(movie.phase == .review ? "Revisar vídeo":"Grabar vídeo"))
                    .disabled(openingVideo || [.finishing,.saving].contains(movie.phase) || (!movie.ready && movie.phase != .review))
                Spacer()
                Button { movie.configure(movie.configuration,lens:movie.lens == .front ? lastBackLens:.front) } label: {
                    Image(systemName:"arrow.triangle.2.circlepath.camera").font(.title2).frame(width:50,height:50)
                }.accessibilityLabel("Cambiar cámara").disabled(movieBusy || openingVideo || !movie.lenses.contains(.front))
            }
            if !movie.ready || movie.phase == .finishing || movie.phase == .review {
                Text(movie.phase == .review ? "Vídeo listo para revisar":movie.status).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
        }
    }

    private var settings: some View {
        NavigationStack(path:$settingsPath) {
            settingsHome
            .navigationDestination(for:ControlPanel.self) { item in
                switch item {
                case .color:cleanSettingsPage("Color y estilo") { colorSettings }
                case .profiles:cleanSettingsPage("Perfiles") { profileSettings }
                default:advancedSettings
                }
            }
            .navigationTitle("Ajustes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Listo") { showControls=false }.disabled(importingDocument) } }
            .tint(CameraPalette.accent)
        }.preferredColorScheme(.dark).tint(CameraPalette.accent).presentationBackground(.ultraThinMaterial)
            .presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(importingDocument)
            .fileImporter(isPresented:$importFile,allowedContentTypes:importingLUT ? [.data]:[.json],onCompletion:importDocument)
            .fileExporter(isPresented:$exportFile,document:exportData,contentType:.json,defaultFilename:"UltimateCAM-profile") { result in
                switch result { case .success:fileMessage="Perfil exportado.";case .failure(let error):fileMessage=error.localizedDescription }
            }
    }
    private var settingsHome:some View {
        Form {
            Section {
                Picker(selection:$options.singlePhotoQuality) { ForEach(SinglePhotoQuality.allCases) { Text($0.label).tag($0) } }
                    label: { Label("Procesado",systemImage:"sparkles") }.disabled(videoMode || stack || rawEnabled  )
                Toggle(isOn:Binding(get:{rawEnabled},set:{rawEnabled=$0;if $0 { options.zeroShutterLagFusion=false }})) { Label("Formato RAW",systemImage:"camera.aperture") }
                    .disabled(videoMode || !rawAvailable || stack)
                Toggle(isOn:$options.preserveHDR) { Label("Conservar HDR",systemImage:"sun.max") }.accessibilityIdentifier("output.preserveHDR")
                NavigationLink { cleanSettingsPage("Modo Noche") { nightOptions } } label: { Label("Modo Noche",systemImage:"moon.stars") }
                    .accessibilityIdentifier("settings.night")
                Picker("Temporizador",selection:$timerSeconds) { Text("No").tag(0);Text("3 s").tag(3);Text("10 s").tag(10) }
            } header: { Label("Calidad e imagen",systemImage:"camera") }.disabled(videoMode)
            Section {
                MovieSettingsFields(camera:movie)
            } header: { Label("Vídeo",systemImage:"video") } footer: { Text("Calidad según la lente seleccionada.").font(.caption) }
            Section {
                NavigationLink { cleanSettingsPage("Color y estilo") { colorSettings } } label: { Label("Color y LUT",systemImage:"camera.filters") }.accessibilityIdentifier("settings.color")
                NavigationLink { cleanSettingsPage("Perfiles") { profileSettings } } label: { Label("Mis perfiles",systemImage:"person.crop.square") }.accessibilityIdentifier("settings.profiles")
            } header: { Label("Color y estilo",systemImage:"paintpalette") }
            Section {
                Toggle(isOn:$grid) { Label("Cuadrícula",systemImage:"grid") }
                Toggle(isOn:$mirrorSelfies) { Label("Selfies reflejadas",systemImage:"arrow.left.and.right.righttriangle.left.righttriangle.right") }.accessibilityIdentifier("capture.mirrorSelfies")
                Toggle(isOn:$hardwareButtons) { Label("Botones de volumen",systemImage:"speaker.wave.2") }.accessibilityIdentifier("capture.hardwareButtons")
                NavigationLink { advancedSettings } label: { Label("Avanzado",systemImage:"slider.horizontal.3") }.accessibilityIdentifier("settings.advanced").disabled(videoMode)
            } header: { Label("Controles",systemImage:"hand.tap") }
        }.scrollContentBackground(.hidden).listRowSpacing(6).listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight,52)
            .background { LinearGradient(colors:[Color(white:0.12),.black],startPoint:.topLeading,endPoint:.bottomTrailing).opacity(0.65) }
            .disabled(camera.busy || movieBusy || countdown>0 || importingDocument)
    }
    private func cleanSettingsPage<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        Form { content() }.scrollContentBackground(.hidden).listStyle(.insetGrouped).listRowSpacing(6)
            .background(.ultraThinMaterial).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var nightOptions:some View {
        Section {
            Picker("Duración",selection:$options.nightBudget) { ForEach([2.0,4,8,16],id:\.self) { Text("\(Int($0)) s").tag($0) } }
                .pickerStyle(.segmented)
            Toggle("Adaptar al movimiento",isOn:$options.nightMotionMetering)
            Toggle("RAW de alta calidad · beta",isOn:Binding(get:{options.nightMetalRAW},set:{ value in
                options.nightMetalRAW=value;options.nightRAW=value;if value { options.nightSpectralFusion=false }
            })).disabled(!rawAvailable && !options.nightMetalRAW)
            Toggle("Guardar DNG fusionado",isOn:$options.saveFusedDNG).disabled(!options.nightMetalRAW)
                .accessibilityIdentifier("night.saveFusedDNG")
            Picker("Noche de iOS",selection:$options.nativeNightMaximum) { Text("Auto").tag(false);Text("Máximo").tag(true) }
            Text(camera.nativeNightIssue == nil ? "Noche de iOS disponible en esta cámara.":"Noche de iOS: " + (camera.nativeNightIssue ?? "No compatible")).font(.caption).foregroundStyle(.secondary)
            Button("Usar Noche de iOS aquí") { pendingNativeNight=true;showControls=false }
                .accessibilityIdentifier("processing.nativeNight")
        } footer: { Text("Apoya el iPhone para escenas oscuras inmóviles.") }
    }
    private var advancedSettings:some View {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ControlPanel.advanced) { item in
                            Button(item.rawValue) { panel = item }
                                .buttonStyle(.bordered).tint(panel == item ? CameraPalette.accent : .white)
                                .accessibilityIdentifier("settings.tab." + item.rawValue)
                        }
                    }.padding(.horizontal).padding(.vertical, 12)
                }.accessibilityIdentifier("settings.tabs")
                if importingDocument { ProgressView("Importando archivo…").padding() }
                Form {
                    switch panel {
                    case .capture: captureSettings
                    case .manual: manualSettings
                    case .processing: processingSettings
                    case .color,.profiles: EmptyView()
                    }
                }.disabled(camera.busy || countdown > 0 || importingDocument)
                    .scrollContentBackground(.hidden).background(CameraPalette.surface)
            }
            .navigationTitle("Avanzado").navigationBarTitleDisplayMode(.inline)
    }

    private func importDocument(_ result: Result<URL, Error>) {
        guard !importingDocument else { return }
        guard case let .success(url) = result else {
            if case let .failure(error) = result { fileMessage = error.localizedDescription }; return
        }
        let access = url.startAccessingSecurityScopedResource()
        let isLUT = importingLUT, layout = pngLUTLayout
        importingDocument = true
        Task { @MainActor in
            defer { importingDocument = false; if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let payload = try await Task.detached(priority: .userInitiated) { () throws -> ImportedProcessingFile in
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 16*1024*1024 else {
                        throw CameraFailure.message("Selecciona un archivo de hasta 16 MB.")
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 16*1024*1024+1) ?? Data()
                    guard data.count == size else { throw CameraFailure.message("El archivo cambió o no se pudo leer completo.") }
                    if isLUT {
                        let name = url.deletingPathExtension().lastPathComponent
                        let lut = data.starts(with: PNGLUT.signature) ?
                            try PNGLUT.parse(data, layout: layout, name: name) : try CubeLUT.parse(data, name: name)
                        return .lut(id: try ColorLUTStore.save(lut), title: lut.title)
                    }
                    return .profile(data)
                }.value
                switch payload {
                case let .lut(id,title): options.lutID = id; fileMessage = "LUT importada: " + title
                case let .profile(data): if loadProfile(try profiles.importDocument(data)) { fileMessage = "Perfil importado." }
                }
            } catch { fileMessage = error.localizedDescription }
        }
    }

    private var captureSettings: some View {
        Group {
            Section("Fusión del visor") {
                Toggle("Fusión del visor · 1280p",isOn:Binding(get:{options.usesPreviewZSL},set:{ value in
                    options.zeroShutterLagFusion=value
                    if value { options.singlePhotoQuality = .balanced }
                }))
                    .disabled(rawEnabled || stack || options.portraitAmount>0).accessibilityIdentifier("capture.zsl")
                Text("Salida reducida a 1280 px. Calidad iOS utiliza la captura nativa y desactiva esta fusión.").font(.caption).foregroundStyle(.secondary)
            }
            if options.nightStatic {
                Section("Captura nocturna") {
                    Picker("Exposición máxima por foto", selection: $options.nightShutterLimit) {
                        Text("1/30 s").tag(1.0/30); Text("1/8 s").tag(0.125); Text("1/4 s").tag(0.25)
                        Text("1/2 s").tag(0.5); Text("1 s").tag(1.0)
                    }.accessibilityIdentifier("night.shutterLimit")
                    Toggle("Fusión espectral experimental",isOn:Binding(get:{options.nightSpectralFusion},set:{ value in
                        options.nightSpectralFusion=value;if value { options.rejectMotion=true;options.nightMetalRAW=false }
                    })).accessibilityIdentifier("night.spectralFusion")
                    if options.nightSpectralFusion {
                        optionSlider("Mezcla espectral",value:$options.nightSpectralStrength,range:0.25...4)
                        Text("Mayor mezcla favorece el promedio; menor conserva más la referencia.").font(.caption).foregroundStyle(.secondary)
                        Text("Fusión adicional de ruido, limitada a 2048 px.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Fusión con pesos por píxel", isOn: $options.nightWeightedFusion).disabled(options.nightSpectralFusion || intrinsicMetalFusion)
                    Text("La duración total incluye captura y procesado.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if options.hdrBracketing {
                Section("HDR por horquillado") {
                    Toggle("HDR Bayer con Metal",isOn:$options.hdrMetalRAW).disabled(!rawAvailable && !options.hdrMetalRAW).accessibilityIdentifier("hdr.metalRAW")
                    Toggle("Guardar DNG fusionado",isOn:$options.saveFusedDNG).disabled(!options.hdrMetalRAW)
                    if options.hdrMetalRAW { Text("HDR RAW de alta calidad en fase beta.").font(.footnote).foregroundStyle(.secondary) }
                    Picker("Separación respecto a la referencia",selection:$options.hdrSpan) { Text("±1 EV").tag(1.0);Text("±2 EV").tag(2.0);Text("±3 EV").tag(3.0) }
                    Text("Combina tres exposiciones para recuperar luces y sombras.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Pila de imágenes") {
                Picker("Fotogramas", selection: $stackCount) { ForEach([3,5,7,9], id: \.self) { Text("\($0) fotos").tag($0) } }
                Picker("Lado largo máximo", selection: $options.maximumDimension) {
                    Text("2048 px · ligera").tag(2048.0); Text("2560 px · equilibrada").tag(2560.0); Text("4096 px · más memoria").tag(4096.0)
                }.disabled(intrinsicMetalFusion)
                Toggle("Referencia más nítida",isOn:Binding(get:{intrinsicMetalFusion || options.chooseSharpestReference},set:{options.chooseSharpestReference=$0})).disabled(intrinsicMetalFusion)
                Toggle("Rechazo de movimiento",isOn:Binding(get:{options.rejectMotion || intrinsicMetalFusion},set:{options.rejectMotion=$0})).disabled(intrinsicMetalFusion || (options.nightStatic && options.nightSpectralFusion))
                Toggle("Alineación local experimental", isOn: $options.localAlignment).disabled(intrinsicMetalFusion)
                Toggle("Rechazo adaptativo experimental",isOn:Binding(get:{intrinsicMetalFusion || (options.rejectMotion && (intrinsicAdaptiveFusion || options.adaptiveMotionRejection))},set:{options.adaptiveMotionRejection=$0}))
                    .disabled(!options.rejectMotion || intrinsicAdaptiveFusion)
                if options.rejectMotion && !intrinsicMetalFusion && !(options.nightStatic && options.nightSpectralFusion) && (options.adaptiveMotionRejection || intrinsicAdaptiveFusion) {
                    optionSlider("Tolerancia al movimiento", value: $options.motionSigma, range: 1.5...6)
                }
                if intrinsicMetalFusion { Text("Metal utiliza su propia alineación piramidal por teselas y rechazo según el ruido. Los controles de la ruta RGB no se aplican.").font(.footnote).foregroundStyle(.secondary) }
                Text("La alineación local consume más tiempo. El rechazo adaptativo estima diferencias RGB; necesita una escena mayoritariamente inmóvil.").font(.footnote).foregroundStyle(.secondary)
                Text("Mantén el teléfono estable. La app descarta imágenes que no consigue alinear.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var manualSettings: some View {
        Group {
            Section("Exposición") {
                if options.nativeNight || options.nightStatic || options.hdrBracketing {
                    Text("Noche y HDR calculan ISO y exposición. El enfoque y el balance de blancos se pueden ajustar antes de capturar.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("ISO y obturación manuales", isOn: Binding(get: { manualExposure }, set: { enabled in
                    manualExposure = enabled
                    iso = min(camera.isoRange.upperBound, max(camera.isoRange.lowerBound, iso))
                    shutterStops = min(log2(camera.shutterRange.upperBound), max(log2(camera.shutterRange.lowerBound), shutterStops))
                    applyExposure()
                })).disabled(!camera.supportsManualExposure || options.nightStatic || options.hdrBracketing)
                if manualExposure {
                    valueLabel("ISO", "\(Int(iso))")
                    Slider(value: $iso, in: camera.isoRange, step: 1).onChange(of: iso) { _, _ in applyExposure() }
                    valueLabel("Obturación", shutterLabel)
                    Slider(value: $shutterStops, in: log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound))
                        .onChange(of: shutterStops) { _, _ in applyExposure() }
                }
            }
            Section("Enfoque") {
                Toggle("Enfoque manual", isOn: Binding(get: { manualFocus }, set: { enabled in
                    manualFocus = enabled; camera.setFocus(enabled ? focusPosition : nil)
                })).disabled(!camera.supportsManualFocus)
                if manualFocus {
                    Slider(value: $focusPosition, in: 0...1).onChange(of: focusPosition) { _, value in camera.setFocus(value) }
                    HStack {
                        Button("Cerca") { focusPosition = 0.15 }
                        Spacer()
                        Button("Lejos") { focusPosition = 0.9 }
                    }
                }
                Text("Toca para enfocar. Mantén pulsado para bloquear.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Color y zoom") {
                Toggle("Balance de blancos manual", isOn: Binding(get: { manualWB }, set: { enabled in
                    manualWB = enabled; camera.setWhiteBalance(enabled ? Float(temperature) : nil, tint: Float(tint))
                })).disabled(!camera.supportsManualWB)
                if manualWB {
                    valueLabel("Temperatura", "\(Int(temperature)) K")
                    Slider(value: $temperature, in: 2500...8000, step: 100).onChange(of: temperature) { _, value in camera.setWhiteBalance(Float(value), tint: Float(tint)) }
                    valueLabel("Matiz verde / magenta", String(format: "%+.0f", tint))
                    Slider(value: $tint, in: -100...100, step: 1).onChange(of: tint) { _, value in
                        camera.setWhiteBalance(Float(temperature), tint: Float(value))
                    }
                    Button("Matiz neutro") { tint = 0 }
                }
                valueLabel("Zoom digital", String(format: "%.1f×", zoom))
                Slider(value: Binding(get: { zoom }, set: { camera.setZoom($0) }),
                       in: 1...max(1.001, camera.maximumZoom)).disabled(camera.maximumZoom <= 1)
            }
            Section { Button("Restablecer controles automáticos") { resetUIControls(); camera.switchLens(lens) } }
        }
    }

    private var processingSettings: some View {
        Group {
            Section("Detalle y textura") {
                optionSlider("Ruido de color", value: $options.chromaDenoise, range: 0...1)
                optionSlider("Contraste local", value: $options.localContrast, range: 0...1.5)
                optionSlider("Detalle fino", value: $options.fineDetail, range: 0...1)
                optionSlider("Radio de nitidez", value: $options.sharpenRadius, range: 0.5...4)
            }
            Section("Ajustes del JPEG") {
                valueLabel("Reducción de ruido", String(format: "%.0f %%", options.noiseReduction / 0.08 * 100))
                Slider(value: $options.noiseReduction, in: 0...0.08)
                valueLabel("Nitidez", String(format: "%.0f %%", options.sharpening / 0.8 * 100))
                Slider(value: $options.sharpening, in: 0...0.8)
                valueLabel("Sombras", String(format: "%.0f %%", options.liftShadows * 100))
                Slider(value: $options.liftShadows, in: 0...1)
                Text("Los ajustes afectan al JPEG. El DNG conserva los datos originales. Una foto individual mantiene la resolución completa.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var colorSettings: some View {
        Group {
            Section {
                Picker("Herramientas de color",selection:$colorPanel) { ForEach(ColorPanel.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }
            if colorPanel == .basic {
            Section("Luz y color del resultado") {
                optionSlider("Exposición", value: $options.postExposure, range: -2...2)
                optionSlider("Compresión de luces", value: $options.highlightCompression, range: 0...1)
                optionSlider("Contraste", value: $options.contrast, range: 0.5...1.5)
                optionSlider("Saturación", value: $options.saturation, range: 0...2)
                optionSlider("Intensidad de color", value: $options.vibrance, range: -1...1)
                optionSlider("Gamma", value: $options.gamma, range: 0.5...2)
                optionSlider("Viñeta", value: $options.vignette, range: 0...1)
            }
            } else { ColorRecipeEditor(panel:colorPanel,recipe:$options.color) }
            Section("LUT 3D") {
                Picker("Distribución PNG cuadrado", selection: $pngLUTLayout) {
                    ForEach(PNGLUTLayout.allCases) { Text($0.label).tag($0) }
                }
                Button("Importar LUT .cube o .png") { importingLUT = true; importFile = true }
                if options.lutID != nil {
                    Text("LUT personalizada activa").foregroundStyle(CameraPalette.accent)
                    optionSlider("Intensidad LUT", value: $options.lutIntensity, range: 0...1)
                    Button("Quitar LUT") { options.lutID = nil }
                }
                Text("Importa .cube o PNG de hasta 16 MB.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Salida JPEG") {
                Picker("Espacio de color", selection: $options.outputColor) { ForEach(OutputColor.allCases) { Text($0.label).tag($0) } }
                Picker("Proporción", selection: $options.aspect) { ForEach(PhotoAspect.allCases) { Text($0.label).tag($0) } }
                Toggle("Elegir calidad JPEG", isOn: Binding(get: { options.jpegQuality != nil }, set: { options.jpegQuality = $0 ? 0.95 : nil }))
                if options.jpegQuality != nil {
                    Slider(value: Binding(get: { options.jpegQuality ?? 0.95 }, set: { options.jpegQuality = $0 }), in: 0.5...1)
                    Text("Calidad: \(Int((options.jpegQuality ?? 0.95) * 100)) %")
                }
                Text("Conserva HDR en imágenes compatibles.").font(.footnote).foregroundStyle(.secondary)
            }
            if let fileMessage { Section { Text(fileMessage).font(.footnote) } }
        }
    }

    private var profileSettings: some View {
        Group {
            Section("Perfil de procesado") {
                Text("Los ajustes de procesado se recuerdan para cada lente. No se guardan ISO, enfoque ni balance manual.").font(.footnote).foregroundStyle(.secondary)
                TextField("Nombre del perfil", text: $profileName).accessibilityIdentifier("profile.name")
                Button("Guardar perfil actual") {
                    do { try profiles.save(name: profileName, options: options); fileMessage = "Perfil guardado." }
                    catch { fileMessage = error.localizedDescription }
                }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Importar perfil JSON") { importingLUT = false; importFile = true }
                Button("Exportar perfil actual") {
                    do { exportData = ProfileFile(data: try profiles.exportDocument(name: profileName.isEmpty ? "Mi perfil" : profileName, options: options)); exportFile = true }
                    catch { fileMessage = error.localizedDescription }
                }
            }
            Section("Mis perfiles") {
                if profiles.profiles.isEmpty { Text("Todavía no hay perfiles guardados.").foregroundStyle(.secondary) }
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Button { if loadProfile(profile.options) { fileMessage = "Aplicado: " + profile.name } } label: { Label(profile.name, systemImage: "slider.horizontal.3") }
                        Spacer()
                        Button(role: .destructive) { profiles.remove(profile.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Eliminar " + profile.name)
                    }
                }
            }
            if let fileMessage { Section { Text(fileMessage).font(.footnote) } }
            if let error = profiles.error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }
        }
    }

    @discardableResult
    private func loadProfile(_ value: ProcessingOptions) -> Bool {
        do {
            _ = try value.validated()
            if let id = value.lutID { _ = try ColorLUTStore.load(id) }
            options = value
            if value.nightStatic || value.hdrBracketing { stack = true; rawEnabled = false; flash = .off; manualExposure = false; camera.setManualExposure(iso: nil) }
            return true
        } catch { fileMessage = "No se aplicó el perfil: " + error.localizedDescription; return false }
    }

    private func optionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            valueLabel(title, String(format: "%.2f", value.wrappedValue))
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private func valueLabel(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(CameraPalette.accent) }
    }
    private func resetUIControls() {
        bias = 0; manualWB = false; manualExposure = false; manualFocus = false
        rawEnabled = false; tint = 0; flash = .off
    }
    private func activateNativeNight() {
        options=PhotoModePolicy.nativeNight(from:options)
        stack=false;rawEnabled=false;flash = .off;manualExposure=false
        camera.setManualExposure(iso:nil)
        if let issue=camera.nativeNightIssue { camera.reportImportError(issue) }
    }
    private func activateHDR() {
        options=PhotoModePolicy.hdr(from:options,supportsRAW:rawAvailable)
        stack=true;rawEnabled=false;flash = .off;manualExposure=false
        camera.setManualExposure(iso:nil)
    }
    private func applyPreset(_ name: String) {
        let selected:PhotoProcessingPreset=name == "Noche estática" ? .night:(name == "Detalle" ? .detail:.natural)
        options=PhotoModePolicy.preset(selected,from:options,supportsRAW:rawAvailable)
        if options.nightStatic {
            stack = true; rawEnabled = false; flash = .off; stackCount = 9
            options.maximumDimension = 4096
            manualExposure = false
            camera.setManualExposure(iso: nil)
        }
    }
    private var shutterLabel: String {
        let seconds = pow(2, shutterStops)
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.2f s", seconds)
    }
    private func applyExposure() { camera.setManualExposure(iso: manualExposure ? iso : nil, seconds: pow(2, shutterStops)) }
    private func cancelCountdown() {
        countdownID = UUID()
        countdownTask?.cancel(); countdownTask = nil; countdown = 0
    }
    private func takePhoto() {
        let selectedFlash = flash
        let captureStack = stack, count = stackCount, raw = rawEnabled, processing = options,mirror=mirrorSelfies
        if timerSeconds == 0 { camera.capture(stack: captureStack, count: count, raw: raw, flash: selectedFlash, options: processing,mirrorSelfie:mirror); return }
        let delay = timerSeconds
        let id = UUID()
        countdownID = id
        countdownTask = Task { @MainActor in
            do {
                for value in stride(from: delay, through: 1, by: -1) {
                    guard countdownID == id else { return }
                    countdown = value
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard countdownID == id else { return }
                countdown = 0
                countdownTask = nil
                camera.capture(stack: captureStack, count: count, raw: raw, flash: selectedFlash, options: processing,mirrorSelfie:mirror)
            } catch { if countdownID == id { countdown = 0; countdownTask = nil } }
        }
    }

    private var review: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if camera.hasSeparateReference {
                        Picker("Imagen", selection: $showReference) { Text("Resultado").tag(false); Text("Referencia").tag(true) }.pickerStyle(.segmented)
                    }
                    if let image = showReference && camera.hasSeparateReference ? camera.referencePreview : camera.preview {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 15))
                    }
                    Text(camera.resultDetails).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    if !showReference, let statistics = camera.resultStatistics { ResultHistogram(statistics: statistics) }
                    if camera.hasRAWResult {
                        Label(camera.hasFusedRAWResult ? "RAW fusionado + JPEG":"RAW original + JPEG", systemImage: "square.stack.3d.up").font(.subheadline.bold()).foregroundStyle(CameraPalette.accent)
                        Text(camera.hasFusedRAWResult ? "El DNG contiene el mosaico fusionado. El JPEG con ajustes se guarda aparte.":"Fotos recibirá el DNG original con su JPEG de cámara. El JPEG editado se guarda aparte.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if camera.hasSeparateReference {
                        Toggle("Guardar también la referencia", isOn: $includeReference)
                    }
                }.padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text(camera.status).font(.footnote).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Button {
                        camera.save(includeReference: includeReference)
                    } label: {
                        Label(camera.savedResult ? "Guardado" : (camera.hasRAWResult ? "Guardar RAW + JPEG" : "Guardar foto"), systemImage: camera.savedResult ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).tint(CameraPalette.accent).foregroundStyle(.black)
                        .disabled(camera.busy || camera.savedResult).accessibilityIdentifier("review.save")
                    if camera.hasRAWResult {
                        Button(camera.savedJPEGOnly ? "JPEG guardado" : "Guardar solo JPEG") { camera.save(jpegOnly: true) }
                            .disabled(camera.busy || camera.savedJPEGOnly).accessibilityIdentifier("review.saveJPEG")
                    }
                    if camera.busy { ProgressView().tint(CameraPalette.accent) }
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("Última captura").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { showResult = false } } }
        }.tint(CameraPalette.accent).preferredColorScheme(.dark)
    }
}
