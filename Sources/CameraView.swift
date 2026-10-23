import AVFoundation
import SwiftUI
import UIKit

private enum ControlPanel: String, CaseIterable, Identifiable {
    case capture = "Captura", manual = "Manual", processing = "Procesado"
    var id: String { rawValue }
}

private struct ViewfinderGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackLens = CameraLens.wide
    @State private var stack = ProcessInfo.processInfo.arguments.contains("-stack-mode")
    @State private var showControls = ProcessInfo.processInfo.arguments.contains("-show-controls")
    @State private var panel: ControlPanel = ProcessInfo.processInfo.arguments.contains("-processing-controls") ? .processing : .capture
    @State private var bias: Double = 0
    @State private var manualWB = false
    @State private var temperature: Double = 5000
    @State private var grid = true
    @State private var showResult = false
    @State private var showReference = false
    @State private var includeReference = false
    @State private var stackCount = 3
    @State private var rawEnabled = false
    @State private var manualExposure = false
    @State private var iso: Double = 100
    @State private var shutterStops = log2(1.0 / 60)
    @State private var options = ProcessingOptions()
    private var preset: String {
        if options.noiseReduction == 0.025 && options.sharpening == 0.15 && options.liftShadows == 0.18 { return "Luz baja" }
        if options.noiseReduction == 0 && options.sharpening == 0.25 && options.liftShadows == 0 { return "Detalle" }
        return options.noiseReduction == 0 && options.sharpening == 0 && options.liftShadows == 0 ? "Natural" : "Personalizado"
    }
    @State private var timerSeconds = 0
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var manualFocus = false
    @State private var focusPosition: Double = 0.5
    @State private var zoom: Double = 1
    private var lens: CameraLens { camera.selectedLens }
    private var controlsEnabled: Bool { !camera.busy && countdown == 0 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.vertical, 10)
            viewfinder
            bottomDock
        }
        .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; camera.start() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; cancelCountdown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true; camera.start() }
            else if phase == .background {
                UIApplication.shared.isIdleTimerDisabled = false
                cancelCountdown()
                camera.stop()
            }
        }
        .onChange(of: camera.selectedLens) { _, next in
            resetUIControls()
            if next != .front { lastBackLens = next }
        }
        .onChange(of: zoom) { _, value in camera.setZoom(value) }
        .onChange(of: bias) { _, value in camera.setBias(Float(value)) }
        .onChange(of: stack) { _, value in if value { rawEnabled = false } }
        .sheet(isPresented: $showControls) { settings }
        .sheet(isPresented: $showResult) { review }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("ULTIMATE CAM").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(1.2)
                Text(stack ? "Pila de \(stackCount) · \(preset)" : "\(rawEnabled ? "RAW + JPEG" : "JPEG") · \(preset)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button { showControls = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .semibold))
                    .frame(width: 46, height: 46).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 16))
            }.accessibilityLabel("Ajustes de cámara").accessibilityIdentifier("camera.settings")
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            let height = min(geometry.size.height, geometry.size.width * 4 / 3)
            let width = height * 3 / 4
            ZStack {
                CameraPreview(session: camera.session, zoom: zoom, focus: { point, locked in
                    manualFocus = false
                    camera.focus(at: point, lock: locked)
                }, changeZoom: { value in zoom = min(camera.maximumZoom, max(1, value)) })
                    .allowsHitTesting(controlsEnabled)
                if grid { ViewfinderGrid() }
                if countdown > 0 {
                    Text("\(countdown)").font(.system(size: 80, weight: .light, design: .rounded))
                        .shadow(color: .black, radius: 10).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                    HStack(spacing: 8) {
                        quickButton(rawEnabled ? "RAW+" : "JPEG", symbol: "square.stack.3d.up", selected: rawEnabled) { rawEnabled.toggle() }
                            .disabled(stack || !camera.supportsRAW)
                        Spacer()
                        quickButton(timerSeconds == 0 ? "OFF" : "\(timerSeconds)s", symbol: "timer", selected: timerSeconds > 0) {
                            timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
                        }
                        quickButton("", symbol: "grid", selected: grid) { grid.toggle() }
                    }.padding(12)
            }.overlay(alignment: .bottom) {
                    HStack {
                        Text(manualFocus ? "Enfoque manual · toca para volver a AF" : camera.focusStatus).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.7), in: Capsule())
                            .allowsHitTesting(false)
                        Spacer(minLength: 0)
                        if zoom > 1.01 {
                            Text("\(zoom, specifier: "%.1f")×").font(.caption.monospacedDigit().bold())
                                .padding(8).background(.black.opacity(0.7), in: Capsule()).allowsHitTesting(false)
                        }
                    }
                .padding(12).allowsHitTesting(false)
            }
            .frame(width: width, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private func quickButton(_ text: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if !text.isEmpty { Text(text).font(.system(size: 11, weight: .bold)) }
            }
            .foregroundStyle(selected ? Color.yellow : .white)
            .padding(.horizontal, 12).frame(height: 40)
            .background(.black.opacity(0.75), in: Capsule())
        }.disabled(!controlsEnabled)
        .accessibilityLabel(symbol == "grid" ? "Cuadrícula" : (symbol == "timer" ? "Temporizador \(text)" : "Formato \(text)"))
    }

    private var bottomDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(camera.lenses.filter { $0 != .front }) { item in
                    Button { camera.switchLens(item) } label: {
                        Text(item.label).font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(lens == item ? .black : .white)
                            .frame(width: 48, height: 38)
                            .background(lens == item ? Color.yellow : Color(white: 0.16), in: Capsule())
                    }.accessibilityLabel("Cámara \(item.label)")
                }
                if lens == .front { Text("Frontal").font(.caption.bold()).foregroundStyle(.yellow) }
                Spacer()
                Text("EV").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                Slider(value: $bias, in: -2...2, step: 0.1).frame(maxWidth: 95)
                    .disabled(manualExposure).accessibilityLabel("Compensación de exposición")
                Text("\(bias, specifier: "%+.1f")").font(.caption.monospacedDigit()).frame(width: 30)
            }.disabled(!controlsEnabled || !camera.ready)
            HStack {
                Button { showResult = true } label: {
                    Group {
                        if let preview = camera.preview { Image(uiImage: preview).resizable().scaledToFill() }
                        else { Image(systemName: "photo.on.rectangle").font(.title3).foregroundStyle(.white.opacity(0.7)) }
                    }.frame(width: 50, height: 50).background(Color(white: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.25)))
                }.accessibilityLabel("Revisar última captura").disabled(camera.preview == nil || !controlsEnabled)
                Spacer()
                Button { countdown > 0 ? cancelCountdown() : takePhoto() } label: {
                    ZStack {
                        Circle().stroke(camera.busy ? Color.yellow : .white, lineWidth: 3)
                        Circle().fill(countdown > 0 ? Color.yellow : .white).padding(7)
                        if camera.busy { ProgressView().tint(.black).scaleEffect(1.2) }
                        else if countdown > 0 { Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.black) }
                    }.frame(width: 76, height: 76)
                }.accessibilityLabel(countdown > 0 ? "Cancelar temporizador" : (stack ? "Capturar pila de \(stackCount) fotos" : "Tomar foto"))
                    .accessibilityIdentifier("camera.shutter").disabled(camera.busy || !camera.ready)
                Spacer()
                Button { camera.switchLens(lens == .front ? lastBackLens : .front) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 23))
                        .frame(width: 50, height: 50).background(Color(white: 0.15), in: Circle())
                }.accessibilityLabel("Cambiar entre cámara frontal y trasera")
                    .disabled(!controlsEnabled || !camera.ready || !camera.lenses.contains(.front))
            }
            HStack(spacing: 5) {
                modeButton("FOTO", selected: !stack) { stack = false }
                modeButton("PILA", selected: stack) { stack = true }
                if stack {
                    Menu { ForEach([3,5,7,9], id: \.self) { count in Button("\(count) fotos") { stackCount = count } } } label: {
                        Text("\(stackCount) ▾").font(.system(size: 13, weight: .bold)).frame(width: 48, height: 34)
                    }.accessibilityLabel("Número de fotos de la pila")
                }
            }.disabled(!controlsEnabled)
            Text(camera.status).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30)
                .accessibilityIdentifier("camera.status")
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 5).tint(.yellow)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold)).tracking(1)
                .foregroundStyle(selected ? .yellow : .white.opacity(0.65))
                .padding(.horizontal, 20).frame(height: 34)
                .background(selected ? Color(white: 0.16) : .clear, in: Capsule())
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var settings: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Panel", selection: $panel) { ForEach(ControlPanel.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding()
                Form {
                    switch panel {
                    case .capture: captureSettings
                    case .manual: manualSettings
                    case .processing: processingSettings
                    }
                }.disabled(camera.busy || countdown > 0)
            }
            .navigationTitle("Ajustes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showControls = false } } }
            .tint(.yellow)
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var captureSettings: some View {
        Group {
            Section("Captura") {
                Toggle("RAW + JPEG", isOn: $rawEnabled).disabled(!camera.supportsRAW || stack)
                if !camera.supportsRAW { Text("RAW no disponible en la cámara actual.").font(.footnote).foregroundStyle(.secondary) }
                if stack { Text("La pila usa JPEG. RAW se captura en modo Foto.").font(.footnote).foregroundStyle(.secondary) }
                Picker("Temporizador", selection: $timerSeconds) { Text("Desactivado").tag(0); Text("3 segundos").tag(3); Text("10 segundos").tag(10) }
                Toggle("Cuadrícula", isOn: $grid)
            }
            Section("Pila de imágenes") {
                Picker("Fotogramas", selection: $stackCount) { ForEach([3,5,7,9], id: \.self) { Text("\($0) fotos").tag($0) } }
                Picker("Lado largo máximo", selection: $options.maximumDimension) {
                    Text("2048 px · ligera").tag(2048.0); Text("2560 px · equilibrada").tag(2560.0); Text("4096 px · más memoria").tag(4096.0)
                }
                Toggle("Referencia más nítida", isOn: $options.chooseSharpestReference)
                Toggle("Rechazo de movimiento", isOn: $options.rejectMotion)
                Text("Mantén el teléfono estable. La app descarta imágenes que no consigue alinear.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var manualSettings: some View {
        Group {
            Section("Exposición") {
                Toggle("ISO y obturación manuales", isOn: Binding(get: { manualExposure }, set: { enabled in
                    manualExposure = enabled
                    iso = min(camera.isoRange.upperBound, max(camera.isoRange.lowerBound, iso))
                    shutterStops = min(log2(camera.shutterRange.upperBound), max(log2(camera.shutterRange.lowerBound), shutterStops))
                    applyExposure()
                })).disabled(!camera.supportsManualExposure)
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
                    manualWB = enabled; camera.setWhiteBalance(enabled ? Float(temperature) : nil)
                })).disabled(!camera.supportsManualWB)
                if manualWB {
                    valueLabel("Temperatura", "\(Int(temperature)) K")
                    Slider(value: $temperature, in: 2500...8000, step: 100).onChange(of: temperature) { _, value in camera.setWhiteBalance(Float(value)) }
                }
                valueLabel("Zoom digital", String(format: "%.1f×", zoom))
                Slider(value: $zoom, in: 1...max(1.001, camera.maximumZoom)).disabled(camera.maximumZoom <= 1)
            }
            Section { Button("Restablecer controles automáticos") { resetUIControls(); camera.switchLens(lens) } }
        }
    }

    private var processingSettings: some View {
        Group {
            Section("Puntos de partida") {
                HStack {
                    ForEach(["Natural", "Detalle", "Luz baja"], id: \.self) { name in
                        Button(name) { applyPreset(name) }.buttonStyle(.bordered)
                            .tint(preset == name ? .yellow : .gray)
                    }
                }
                Text("Luz baja selecciona una pila de 7 con ajustes moderados. Es un perfil experimental; no reproduce Night Sight.")
                    .font(.footnote).foregroundStyle(.secondary)
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

    private func valueLabel(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.yellow) }
    }
    private func resetUIControls() {
        bias = 0; manualWB = false; manualExposure = false; manualFocus = false
        rawEnabled = false; zoom = 1
    }
    private func applyPreset(_ name: String) {
        options.noiseReduction = name == "Luz baja" ? 0.025 : 0
        options.sharpening = name == "Detalle" ? 0.25 : (name == "Luz baja" ? 0.15 : 0)
        options.liftShadows = name == "Luz baja" ? 0.18 : 0
        if name == "Luz baja" { stack = true; rawEnabled = false; stackCount = 7 }
    }
    private var shutterLabel: String {
        let seconds = pow(2, shutterStops)
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.2f s", seconds)
    }
    private func applyExposure() { camera.setManualExposure(iso: manualExposure ? iso : nil, seconds: pow(2, shutterStops)) }
    private func cancelCountdown() { countdownTask?.cancel(); countdownTask = nil; countdown = 0 }
    private func takePhoto() {
        let captureStack = stack, count = stackCount, raw = rawEnabled, processing = options
        if timerSeconds == 0 { camera.capture(stack: captureStack, count: count, raw: raw, options: processing); return }
        let delay = timerSeconds
        countdownTask = Task { @MainActor in
            do {
                for value in stride(from: delay, through: 1, by: -1) {
                    countdown = value
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = 0
                camera.capture(stack: captureStack, count: count, raw: raw, options: processing)
            } catch { countdown = 0 }
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
                    if camera.hasRAWResult {
                        Label("RAW original + JPEG", systemImage: "square.stack.3d.up").font(.subheadline.bold()).foregroundStyle(.yellow)
                        Text("Fotos recibirá el DNG con su JPEG de cámara. Si has aplicado ajustes, el JPEG editado se guarda aparte.")
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
                    }.buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                        .disabled(camera.busy || camera.savedResult).accessibilityIdentifier("review.save")
                    if camera.hasRAWResult {
                        Button(camera.savedJPEGOnly ? "JPEG guardado" : "Guardar solo JPEG") { camera.save(jpegOnly: true) }
                            .disabled(camera.busy || camera.savedJPEGOnly).accessibilityIdentifier("review.saveJPEG")
                    }
                    if camera.busy { ProgressView().tint(.yellow) }
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("Última captura").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { showResult = false } } }
        }.tint(.yellow).preferredColorScheme(.dark)
    }
}
