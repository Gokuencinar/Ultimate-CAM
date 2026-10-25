import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

private enum ControlPanel: String, CaseIterable, Identifiable {
    case capture = "Captura", manual = "Manual", processing = "Procesado", color = "Color", profiles = "Perfiles"
    var id: String { rawValue }
}

private enum ImportedProcessingFile {
    case lut(id: String, title: String)
    case profile(Data)
}

private enum AuxiliaryCameraMode:String,Identifiable {
    case video,panorama
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
    @StateObject private var camera = CameraModel()
    @StateObject private var nativeNight = NativeNightCoordinator()
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
    private var preset: String {
        if options.nightStatic { return options.localAlignment && options.adaptiveMotionRejection ? "Estático avanzado" : "Noche estática" }
        if options.advancedRendering { return "Personalizado" }
        if options.noiseReduction == 0 && options.sharpening == 0.25 && options.liftShadows == 0 { return "Detalle" }
        return options.noiseReduction == 0 && options.sharpening == 0 && options.liftShadows == 0 ? "Natural" : "Personalizado"
    }
    @State private var timerSeconds = 0
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var countdownID = UUID()
    @State private var manualFocus = false
    @State private var focusPosition: Double = 0.5
    private var zoom: Double { camera.zoomFactor }
    private var lens: CameraLens { camera.selectedLens }
    private var controlsEnabled: Bool { !camera.busy && !loadingPhoto && !nativeNight.opening && !openingVideo && countdown == 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            viewfinder.ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.vertical, 10)
                if showQuickControls { quickControls.padding(.horizontal, 16).padding(.bottom, 12) }
            }
            .background {
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if camera.isFocusLocked || manualFocus { focusInfo.padding(.horizontal, 20).padding(.bottom, 8) }
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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; if auxiliaryMode == nil && !openingVideo { camera.start() }; loadProfile(profiles.options(for: lens.rawValue) ?? ProcessingOptions()) }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; cancelCountdown(); profiles.flush() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true; if !nativeNight.opening && auxiliaryMode == nil && !openingVideo { nativeNight.returnedToApp(); camera.start() } }
            else if phase == .background {
                UIApplication.shared.isIdleTimerDisabled = false
                cancelCountdown()
                profiles.flush()
                camera.stop()
            }
        }
        .onChange(of: camera.selectedLens) { _, next in
            resetUIControls()
            if !loadProfile(profiles.options(for: next.rawValue) ?? ProcessingOptions()) { options = ProcessingOptions() }
            if next != .front { lastBackLens = next }
        }
        .onChange(of: options) { _, value in profiles.remember(value, lens: lens.rawValue) }
        .onChange(of: options) { _, value in camera.setPreviewTools(previewTools,processing:value) }
        .onChange(of: previewTools) { _, value in camera.setPreviewTools(value,processing:options) }
        .onChange(of: camera.busy) { _, value in if !value { camera.setPreviewTools(previewTools,processing:options) } }
        .onChange(of: bias) { _, value in camera.setBias(Float(value)) }
        .onChange(of: stack) { _, value in if value { rawEnabled = false; flash = .off } }
        .onChange(of: rawEnabled) { _, value in if value { flash = .off } }
        .sheet(isPresented: $showControls, onDismiss: {
            if pendingPhotoImport { pendingPhotoImport = false; showPhotoPicker = true }
            else if pendingNativeNight { pendingNativeNight = false; nativeNight.open(camera:camera) }
        }) { settings }
        .sheet(isPresented: $showResult) { review }
        .fullScreenCover(item:$auxiliaryMode,onDismiss:{ resetUIControls();camera.resumeAfterAuxiliary() }) { mode in
            switch mode { case .video: MovieCameraView();case .panorama: GuidedPanoramaView() }
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
            get: { camera.importFailure != nil || nativeNight.showMessage },
            set: { if !$0 { camera.clearImportError();nativeNight.showMessage=false } })) {
            Button("Aceptar",role:.cancel) { camera.clearImportError();nativeNight.showMessage=false }
        } message: { Text(camera.importFailure ?? nativeNight.message) }
    }

    private var header: some View {
        HStack(spacing:16) {
            Button { showQuickControls.toggle() } label: {
                Image(systemName:showQuickControls ? "chevron.up" : "chevron.down")
                    .font(.system(size:16,weight:.semibold)).frame(width:44,height:44)
                    .background(.black.opacity(0.55),in:Circle())
            }.accessibilityLabel("Ajustes rápidos").accessibilityIdentifier("camera.quickSettings")
            Spacer(minLength:0)
            Text(options.hdrBracketing ? "HDR · 3 exposiciones" : (options.nightStatic ? "Noche estática · \((options.nightRAW && camera.supportsRAW) ? "RAW experimental" : "JPEG")" :
                (stack ? "Pila de \(stackCount)" : (options.portraitAmount>0 ? "Retrato · personas" : (rawEnabled ? "RAW + JPEG" : "Cámara")))))
                .font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength:0)
            Menu {
                Toggle("Cuadrícula",isOn:$grid)
                Picker("Composición",selection:$guide) { ForEach(CompositionGuide.allCases) { Text($0.rawValue).tag($0) } }
                Divider()
                Toggle("Histograma del visor",isOn:$previewTools.histogram)
                Toggle("Resaltar enfoque",isOn:$previewTools.peaking)
                Toggle("Cebras de luces",isOn:$previewTools.zebras)
                Toggle("Vista de color y LUT · 5 FPS",isOn:$previewTools.colorLook)
            } label: { Image(systemName:"viewfinder").font(.system(size:19)).frame(width:44,height:44).background(.black.opacity(0.55),in:Circle()) }
                .accessibilityLabel("Guías y herramientas del visor").accessibilityIdentifier("camera.previewTools").disabled(!controlsEnabled)
        }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: camera.session, zoom: zoom, focus: { point, locked in
                manualFocus = false
                camera.focus(at: point, lock: locked)
            }, changeZoom: { value in camera.setZoom(value) })
                .allowsHitTesting(controlsEnabled)
            GeometryReader { geometry in
                if let frame=camera.previewAnalysisFrame {
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
            if previewTools.histogram,let frame=camera.previewAnalysisFrame {
                VStack { HStack { Spacer();PreviewMeterView(metrics:frame.metrics) };Spacer() }.padding(.top,110).padding(.trailing,18)
            }
            if let notice=camera.previewAnalysisFrame?.notice {
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
        HStack(spacing: 8) {
            quickButton(options.nightStatic ? ((options.nightRAW && camera.supportsRAW) ? "RAW*" : "JPEG") : (rawEnabled ? "RAW+" : "JPEG"),
                        symbol: "square.stack.3d.up", selected: rawEnabled || (options.nightStatic && options.nightRAW && camera.supportsRAW)) { rawEnabled.toggle() }
                .disabled(stack || !camera.supportsRAW)
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
                .disabled(!controlsEnabled || !camera.supportsFlash || stack || rawEnabled)
            quickButton(timerSeconds == 0 ? "OFF" : "\(timerSeconds)s", symbol: "timer", selected: timerSeconds > 0) {
                timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
            }
            quickButton("", symbol: "grid", selected: grid) { grid.toggle() }
        }
    }

    private var focusInfo: some View {
        HStack {
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
            Spacer(minLength: 0)
            if zoom > 1.01 {
                Text("\(zoom, specifier: "%.1f")×").font(.caption.monospacedDigit().bold())
                    .padding(8).background(.black.opacity(0.7), in: Capsule()).allowsHitTesting(false)
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
            HStack(spacing:12) {
                Button { panel = .profiles; showControls = true } label: { Image(systemName:"person.crop.square").frame(width:44,height:44) }
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
                Button { panel = .color; showControls = true } label: { Image(systemName:"cube.transparent").frame(width:44,height:44) }
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
                        Circle().stroke(camera.busy ? CameraPalette.accent : .white, lineWidth: 3)
                        Circle().fill(countdown > 0 ? CameraPalette.accent : .white).padding(7)
                        if camera.busy { ProgressView().tint(.black).scaleEffect(1.2) }
                        else if countdown > 0 { Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.black) }
                    }.frame(width: 72, height: 72)
                }.accessibilityLabel(countdown > 0 ? "Cancelar temporizador" : (options.nightStatic ? "Capturar noche estática" : (stack ? "Capturar pila de \(stackCount) fotos" : "Tomar foto")))
                    .accessibilityIdentifier("camera.shutter").disabled(camera.busy || loadingPhoto || nativeNight.opening || (!camera.ready && countdown == 0))
                Spacer()
                Button { camera.switchLens(lens == .front ? lastBackLens : .front) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 23))
                        .frame(width: 50, height: 50).background(Color(white: 0.15), in: Circle())
                }.accessibilityLabel("Cambiar entre cámara frontal y trasera")
                    .disabled(!controlsEnabled || !camera.ready || !camera.lenses.contains(.front))
            }
            HStack(spacing:4) {
                Button { showControls = true } label: { Image(systemName:"gearshape").font(.system(size:19)).frame(width:40,height:44) }
                    .accessibilityLabel("Ajustes de cámara").accessibilityIdentifier("camera.settings")
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:4) {
                        modeButton("Noche",selected:options.nightStatic) { applyPreset("Noche estática") }
                        modeButton("Cámara",selected:!stack && !options.hdrBracketing && options.portraitAmount==0) { options.nightStatic=false;options.hdrBracketing=false;options.portraitAmount=0;stack=false }
                        modeButton("Retrato",selected:!stack && !options.hdrBracketing && options.portraitAmount>0) {
                            options.nightStatic=false;options.hdrBracketing=false;options.portraitAmount=0.5;stack=false
                        }.accessibilityIdentifier("camera.mode.portrait")
                        modeButton("HDR",selected:options.hdrBracketing) { activateHDR() }.accessibilityIdentifier("camera.mode.hdr")
                        modeButton("Pila",selected:stack && !options.nightStatic && !options.hdrBracketing) { options.nightStatic=false;options.hdrBracketing=false;stack=true }
                        modeButton("Vídeo",selected:false) {
                            openAuxiliary(.video)
                        }.accessibilityIdentifier("camera.mode.video")
                        modeButton("Panorama",selected:false) { openAuxiliary(.panorama) }.accessibilityIdentifier("camera.mode.panorama")
                        modeButton("iOS",selected:false) { nativeNight.open(camera:camera) }.accessibilityIdentifier("camera.mode.nativeNight")
                    }
                }.accessibilityIdentifier("camera.modes")
                Button { panel = .color; showControls = true } label: { Image(systemName:"slider.horizontal.3").font(.system(size:19)).frame(width:40,height:44) }
                    .accessibilityLabel("Ajustes de imagen")
            }.disabled(!controlsEnabled)
            if camera.busy || !camera.ready {
            Text(camera.status).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30)
                .accessibilityIdentifier("camera.status")
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 5).tint(CameraPalette.accent)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold)).tracking(1)
                .foregroundStyle(selected ? CameraPalette.accent : .white.opacity(0.65))
                .padding(.horizontal, 12).frame(height: 38)
                .background(selected ? Color(white: 0.16) : .clear, in: Capsule())
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openAuxiliary(_ mode:AuxiliaryCameraMode) {
        openingVideo=true
        camera.prepareNativeHandoff { accepted in
            openingVideo=false
            if accepted && scenePhase == .active { auxiliaryMode=mode }
            else if scenePhase == .active { camera.start() }
        }
    }

    private var settings: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ControlPanel.allCases) { item in
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
                    case .color: colorSettings
                    case .profiles: profileSettings
                    }
                }.disabled(camera.busy || countdown > 0 || importingDocument)
                    .scrollContentBackground(.hidden).background(CameraPalette.surface)
            }
            .navigationTitle("Ajustes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showControls = false }.disabled(importingDocument) } }
            .tint(CameraPalette.accent)
        }.presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(importingDocument)
            .fileImporter(isPresented: $importFile, allowedContentTypes: importingLUT ? [.data] : [.json], onCompletion: importDocument)
            .fileExporter(isPresented: $exportFile, document: exportData, contentType: .json, defaultFilename: "UltimateCAM-profile") { result in
                switch result { case .success: fileMessage = "Perfil exportado."; case .failure(let error): fileMessage = error.localizedDescription }
            }
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
            Section("Captura") {
                Picker("Procesado de foto individual", selection: $options.singlePhotoQuality) {
                    ForEach(SinglePhotoQuality.allCases) { Text($0.label).tag($0) }
                }.disabled(stack || rawEnabled || manualExposure || camera.isFocusLocked)
                Text("Calidad iOS pide el mejor procesado disponible al sistema. No activa el modo Noche de Cámara. Con RAW, bloqueo AE, exposición manual o pilas se usa rapidez para respetar cada exposición.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("RAW + JPEG", isOn: $rawEnabled).disabled(!camera.supportsRAW || stack)
                if !camera.supportsRAW { Text("RAW no disponible en la cámara actual.").font(.footnote).foregroundStyle(.secondary) }
                if options.nightStatic {
                    Text(camera.supportsRAW ? "Noche usa JPEG de cámara por defecto. La fusión DNG experimental se activa en Procesado y conserva el DNG de referencia." : "Esta lente usa la alternativa JPEG nocturna; no dispone de RAW.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if stack { Text("La pila usa JPEG. RAW se captura en modo Foto.").font(.footnote).foregroundStyle(.secondary) }
                Picker("Flash", selection: $flash) {
                    ForEach(CameraFlash.allCases) { item in Text(item.label).tag(item) }
                }.disabled(!camera.supportsFlash || stack || rawEnabled)
                Text("El flash se usa en Foto JPEG. RAW y las pilas conservan luz continua sin destellos.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Temporizador", selection: $timerSeconds) { Text("Desactivado").tag(0); Text("3 segundos").tag(3); Text("10 segundos").tag(10) }
                Toggle("Cuadrícula", isOn: $grid)
                if grid { Picker("Guía", selection: $guide) { ForEach(CompositionGuide.allCases) { Text($0.rawValue).tag($0) } } }
            }
            if options.nightStatic {
                Section("Captura nocturna") {
                    Picker("Presupuesto de integración", selection: $options.nightBudget) {
                        ForEach([2.0,4,8,16], id: \.self) { Text("\(Int($0)) segundos").tag($0) }
                    }.accessibilityIdentifier("night.budget")
                    Picker("Exposición máxima por foto", selection: $options.nightShutterLimit) {
                        Text("1/30 s").tag(1.0/30); Text("1/8 s").tag(0.125); Text("1/4 s").tag(0.25)
                        Text("1/2 s").tag(0.5); Text("1 s").tag(1.0)
                    }.accessibilityIdentifier("night.shutterLimit")
                    Toggle("Fusión con pesos por píxel", isOn: $options.nightWeightedFusion)
                    Text("Hasta 16 fotogramas, limitado por la medición y la lente. El tiempo total incluye entrega y procesado y será mayor. El límite de obturación es manual: aún no detecta movimiento de sujetos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if options.hdrBracketing {
                Section("HDR por horquillado") {
                    Picker("Separación respecto a la referencia",selection:$options.hdrSpan) { Text("±1 EV").tag(1.0);Text("±2 EV").tag(2.0);Text("±3 EV").tag(3.0) }
                    Text("Tres exposiciones JPEG distintas con fusión de radiancia aproximada. Puedes conservar el rango ampliado activando el mapa HDR en Color · Salida JPEG. Es experimental; no es el motor HDR+ de Google.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Pila de imágenes") {
                Picker("Fotogramas", selection: $stackCount) { ForEach([3,5,7,9], id: \.self) { Text("\($0) fotos").tag($0) } }
                Picker("Lado largo máximo", selection: $options.maximumDimension) {
                    Text("2048 px · ligera").tag(2048.0); Text("2560 px · equilibrada").tag(2560.0); Text("4096 px · más memoria").tag(4096.0)
                }
                Toggle("Referencia más nítida", isOn: $options.chooseSharpestReference)
                Toggle("Rechazo de movimiento", isOn: $options.rejectMotion)
                Toggle("Alineación local experimental", isOn: $options.localAlignment)
                Toggle("Rechazo adaptativo experimental", isOn: $options.adaptiveMotionRejection).disabled(!options.rejectMotion)
                if options.adaptiveMotionRejection && options.rejectMotion {
                    optionSlider("Tolerancia al movimiento", value: $options.motionSigma, range: 1.5...6)
                }
                Text("La alineación local consume más tiempo. El rechazo adaptativo estima diferencias RGB; necesita una escena mayoritariamente inmóvil.").font(.footnote).foregroundStyle(.secondary)
                Text("Mantén el teléfono estable. La app descarta imágenes que no consigue alinear.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var manualSettings: some View {
        Group {
            Section("Exposición") {
                if options.nightStatic || options.hdrBracketing {
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
                Text("Toca el visor para enfocar y medir luz. Mantén pulsado para bloquear AF/AE. Un toque vuelve al ajuste automático. Algunas lentes tienen enfoque fijo.")
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
            Section("Noche nativa · complemento jailbreak") {
                Button("Abrir Cámara con Noche máximo") { pendingNativeNight=true;showControls=false }
                    .accessibilityIdentifier("processing.nativeNight")
                Text("Abre Cámara de Apple y solicita Noche máximo mediante el complemento Ultimate CAM Native Night. Dispara allí y después importa el resultado. La solicitud caduca y respeta el soporte nativo del modo y de la lente. Esta ruta usa la interfaz de Apple.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Puntos de partida") {
                Button("Foto con procesado de iOS") {
                    applyPreset("Natural"); options.singlePhotoQuality = .quality
                    resetUIControls(); camera.switchLens(lens)
                }.accessibilityIdentifier("processing.systemQuality")
                HStack {
                    ForEach(["Natural", "Detalle", "Noche estática"], id: \.self) { name in
                        Button(name) { applyPreset(name) }.buttonStyle(.bordered)
                            .tint(preset == name ? CameraPalette.accent : .white)
                    }
                }
                DisclosureGroup("Usar una foto del modo Noche de Apple") {
                    Text("Toma la foto con el modo Noche en Cámara de Apple y después impórtala desde el botón de galería. Un JPEG sin ajustes se conserva sin recodificar. Al editar o convertir HEIF se genera JPEG SDR sin gain map HDR. No se integra ni se fuerza el motor privado de Cámara.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Elegir foto de Fotos") { pendingPhotoImport = true; showControls = false }
                }
                Button("Estático avanzado · experimental") {
                    applyPreset("Noche estática")
                    options.localAlignment = true; options.adaptiveMotionRejection = true
                    options.chromaDenoise = 0.35; options.localContrast = 0.2; options.fineDetail = 0.12
                }.buttonStyle(.bordered).tint(preset == "Estático avanzado" ? CameraPalette.accent : .white)
                Text("Para escenas inmóviles y con el iPhone apoyado.").font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Cómo funciona Noche estática") {
                Text("Noche estática necesita el iPhone apoyado y una escena inmóvil. Ajusta la exposición y fusiona JPEG de cámara. La opción DNG experimental puede introducir dominantes de color en sombras. Conserva la referencia. Es experimental y no equivale a Night Sight ni al modo Noche de Apple.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if options.nightStatic && camera.supportsRAW {
                Section("RAW nocturno experimental") {
                    Toggle("Fusionar DNG", isOn: $options.nightRAW)
                        .accessibilityIdentifier("night-raw-toggle")
                    Text("Más lento y con color aún sin calibrar en sombras profundas. Desactivado conserva el color del JPEG de cámara. El DNG guardado es una referencia original, no un RAW fusionado.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Retrato de personas") {
                Toggle("Desenfocar fondo",isOn:Binding(get:{options.portraitAmount>0},set:{options.portraitAmount=$0 ? 0.5:0}))
                if options.portraitAmount>0 { optionSlider("Intensidad del retrato",value:$options.portraitAmount,range:0.05...1) }
                Text("Separa personas con Vision y desenfoca el fondo después de capturar. No genera un mapa de profundidad y no se previsualiza en directo. Si no identifica una persona, conserva la referencia sin simular un retrato. El DNG original no cambia.").font(.footnote).foregroundStyle(.secondary)
            }
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
                optionSlider("Exposición del JPEG (EV)", value: $options.postExposure, range: -2...2)
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
                Text(".cube de 2 a 64 puntos, PNG RGB de 8 bits en mosaico AGC, Hald estándar o tira horizontal. Las tiras se reconocen automáticamente; los cuadrados necesitan la distribución correcta. Hasta 16 MB/16 MP, remuestreo a un máximo de 64 puntos. Afectan al JPEG, no al visor ni al DNG.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Salida JPEG") {
                Toggle("Conservar HDR cuando esté disponible", isOn: $options.preserveHDR)
                    .accessibilityIdentifier("output.preserveHDR")
                Picker("Espacio de color", selection: $options.outputColor) { ForEach(OutputColor.allCases) { Text($0.label).tag($0) } }
                Picker("Proporción", selection: $options.aspect) { ForEach(PhotoAspect.allCases) { Text($0.label).tag($0) } }
                Toggle("Elegir calidad JPEG", isOn: Binding(get: { options.jpegQuality != nil }, set: { options.jpegQuality = $0 ? 0.95 : nil }))
                if options.jpegQuality != nil {
                    Slider(value: Binding(get: { options.jpegQuality ?? 0.95 }, set: { options.jpegQuality = $0 }), in: 0.5...1)
                    Text("Calidad: \(Int((options.jpegQuality ?? 0.95) * 100)) %")
                }
                Text("El mapa HDR se genera en horquillado HDR o al editar una foto con HDR incorporado. Foto sin mapa, Pila y Noche propia producen SDR. La base JPEG se puede abrir en pantallas SDR. Display P3 amplía el color; no crea HDR por sí solo. El visor y la revisión muestran SDR.").font(.footnote).foregroundStyle(.secondary)
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
    private func activateHDR() {
        options.nightStatic=false;options.nightRAW=false;options.hdrBracketing=true
        stack=true;rawEnabled=false;flash = .off;manualExposure=false
        camera.setManualExposure(iso:nil)
    }
    private func applyPreset(_ name: String) {
        options = ProcessingOptions()
        options.nightStatic = name == "Noche estática"
        options.nightRAW = false
        options.noiseReduction = options.nightStatic ? 0.012 : 0
        options.sharpening = name == "Detalle" ? 0.25 : (options.nightStatic ? 0.1 : 0)
        options.liftShadows = 0
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
        let captureStack = stack, count = stackCount, raw = rawEnabled, processing = options
        if timerSeconds == 0 { camera.capture(stack: captureStack, count: count, raw: raw, flash: selectedFlash, options: processing); return }
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
                camera.capture(stack: captureStack, count: count, raw: raw, flash: selectedFlash, options: processing)
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
                        Label("RAW original + JPEG", systemImage: "square.stack.3d.up").font(.subheadline.bold()).foregroundStyle(CameraPalette.accent)
                        Text("Fotos recibirá el DNG de referencia con su JPEG de cámara. El JPEG fusionado o editado se guarda aparte; el DNG no está fusionado.")
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
