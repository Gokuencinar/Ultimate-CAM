import SwiftUI
import AVFoundation
import UIKit

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let focus: (CGPoint) -> Void
    final class Coordinator: NSObject {
        var focus: (CGPoint) -> Void
        init(focus: @escaping (CGPoint) -> Void) { self.focus = focus }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewSurface else { return }
            focus(view.previewLayer.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view)))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(focus: focus) }
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) { context.coordinator.focus = focus }
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
            }.stroke(.white.opacity(0.25), lineWidth: 0.5)
        }.allowsHitTesting(false)
    }
}

struct CameraView: View {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var lens = CameraLens.wide
    @State private var lastBackLens = CameraLens.wide
    @State private var stack = ProcessInfo.processInfo.arguments.contains("-stack-mode")
    @State private var bias: Double = 0
    @State private var manualWB = false
    @State private var temperature: Double = 5000
    @State private var grid = true
    @State private var showControls = ProcessInfo.processInfo.arguments.contains("-show-controls")
    @State private var showResult = false
    @State private var showReference = false
    @State private var stackCount = 3
    @State private var rawEnabled = false
    @State private var manualExposure = false
    @State private var iso: Double = 100
    @State private var shutterStops = log2(1.0 / 60)
    @State private var processingOptions = ProcessingOptions()
    @State private var timerSeconds = 0
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var manualFocus = false
    @State private var focusPosition: Double = 0.5
    @State private var zoom: Double = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                CameraPreview(session: camera.session) { point in
                    guard !manualFocus, countdown == 0 else { return }
                    camera.focus(at: point)
                }
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                if grid { ViewfinderGrid() }
            }.ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 14) {
                topBar
                if showControls { controls.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer(minLength: 12)
                Text(camera.status)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                lensSelector
                captureRow
                modeSelector
            }
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
            if countdown > 0 {
                Text("\(countdown)").font(.system(size: 80, weight: .light, design: .rounded))
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else if phase == .background {
                countdownTask?.cancel()
                countdown = 0
                camera.stop()
            }
        }
        .sheet(isPresented: $showResult) { review }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ultimate CAM").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(stack ? "PILA \(stackCount) · EXPERIMENTAL" : (rawEnabled ? "FOTO · RAW + JPEG" : "FOTO · JPEG"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            } label: {
                Image(systemName: showControls ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }.accessibilityLabel(showControls ? "Ocultar controles" : "Mostrar controles")
        }
    }

    private var controls: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if stack {
                Picker("Fotos de la pila", selection: $stackCount) {
                    ForEach([3, 5, 7, 9], id: \.self) { Text("\($0) fotos").tag($0) }
                }.pickerStyle(.segmented)
            }
            Picker("Temporizador", selection: $timerSeconds) {
                Text("Sin temporizador").tag(0)
                Text("3 s").tag(3)
                Text("10 s").tag(10)
            }.font(.caption)
            if camera.supportsRAW && !stack { Toggle("RAW/DNG + JPEG", isOn: $rawEnabled) }
            if camera.supportsManualExposure {
                Toggle("ISO y obturación manuales", isOn: $manualExposure)
                    .onChange(of: manualExposure) { _, enabled in
                        iso = min(camera.isoRange.upperBound, max(camera.isoRange.lowerBound, iso))
                        shutterStops = min(log2(camera.shutterRange.upperBound), max(log2(camera.shutterRange.lowerBound), shutterStops))
                        applyExposure(enabled: enabled)
                    }
                if manualExposure {
                    Text("ISO \(Int(iso))").font(.caption.monospacedDigit())
                    Slider(value: $iso, in: camera.isoRange, step: 1)
                        .onChange(of: iso) { _, _ in applyExposure(enabled: true) }
                    Text("Obturación: \(shutterLabel)").font(.caption.monospacedDigit())
                    Slider(value: $shutterStops, in: log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound))
                        .onChange(of: shutterStops) { _, _ in applyExposure(enabled: true) }
                }
            }
            if camera.supportsManualFocus {
                Toggle("Enfoque manual", isOn: $manualFocus)
                    .onChange(of: manualFocus) { _, enabled in camera.setFocus(enabled ? focusPosition : nil) }
                if manualFocus {
                    Slider(value: $focusPosition, in: 0...1)
                        .onChange(of: focusPosition) { _, value in camera.setFocus(value) }
                    Text("Cerca ← enfoque → lejos").font(.caption)
                }
            }
            if camera.maximumZoom > 1 {
                Text("Zoom digital: \(zoom, specifier: "%.1f")×").font(.caption)
                Slider(value: $zoom, in: 1...camera.maximumZoom)
                    .onChange(of: zoom) { _, value in camera.setZoom(value) }
            }
            HStack {
                Label("EXPOSICIÓN", systemImage: "plusminus.circle")
                Spacer()
                Text("\(bias, specifier: "%+.1f") EV").foregroundStyle(.yellow)
            }.font(.system(size: 12, weight: .semibold, design: .rounded))
            Slider(value: $bias, in: -2...2, step: 0.1)
                .disabled(manualExposure)
                .tint(.yellow).accessibilityLabel("Compensación de exposición")
                .onChange(of: bias) { _, value in camera.setBias(Float(value)) }
            Toggle("Balance de blancos manual", isOn: $manualWB)
                .font(.system(size: 13, weight: .medium, design: .rounded)).tint(.yellow)
                .onChange(of: manualWB) { _, value in
                    camera.setWhiteBalance(value ? Float(temperature) : nil)
                }
            if manualWB {
                Text("\(Int(temperature)) K").font(.caption.monospacedDigit()).foregroundStyle(.yellow)
                Slider(value: $temperature, in: 2500...8000, step: 100)
                    .tint(.yellow).accessibilityLabel("Temperatura del balance de blancos")
                    .onChange(of: temperature) { _, value in camera.setWhiteBalance(Float(value)) }
            }
            Toggle("Cuadrícula", isOn: $grid).font(.system(size: 13, weight: .medium, design: .rounded)).tint(.yellow)
            if stack {
                Toggle("Elegir referencia más nítida", isOn: $processingOptions.chooseSharpestReference)
                Toggle("Rechazar zonas en movimiento", isOn: $processingOptions.rejectMotion)
                Picker("Resolución de la pila", selection: $processingOptions.maximumDimension) {
                    Text("Ligera · 2048 px").tag(2048.0)
                    Text("Equilibrada · 2560 px").tag(2560.0)
                    Text("Hasta 4096 px").tag(4096.0)
                }
                Text("El rechazo conserva la referencia en zonas que cambian. No sustituye una alineación local avanzada.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Text("Ajustes del resultado").font(.caption.bold())
            Text("Reducción de ruido").font(.caption)
            Slider(value: $processingOptions.noiseReduction, in: 0...0.08).tint(.yellow)
            Text("Nitidez").font(.caption)
            Slider(value: $processingOptions.sharpening, in: 0...0.8).tint(.yellow)
            Text("Levantar sombras").font(.caption)
            Slider(value: $processingOptions.liftShadows, in: 0...1).tint(.yellow)
          }
          .font(.system(size: 13, weight: .medium, design: .rounded)).tint(.yellow)
          .padding(18)
        }
        .frame(maxHeight: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.2), lineWidth: 1))
        .disabled(camera.busy || !camera.ready || countdown > 0)
    }

    private var lensSelector: some View {
        HStack(spacing: 8) {
            if lens == .front {
                Text("FRONTAL").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow).padding(.horizontal, 14).frame(height: 40)
            } else {
                ForEach(camera.lenses.filter { $0 != .front }) { item in
                    Button { selectLens(item) } label: {
                        Text(item.label).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(lens == item ? .yellow : .white)
                            .frame(width: 44, height: 40)
                            .background(lens == item ? .white.opacity(0.15) : .clear, in: Circle())
                    }.accessibilityLabel("Cámara \(item.label)")
                }
            }
        }
        .padding(5).background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        .disabled(camera.busy || !camera.ready || countdown > 0)
    }

    private var captureRow: some View {
        HStack {
            Button { showResult = true } label: {
                Group {
                    if let preview = camera.preview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else { Image(systemName: "photo").font(.title3) }
                }
                .frame(width: 48, height: 48).clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            }
            .accessibilityLabel("Revisar última captura")
            .disabled(camera.preview == nil || camera.busy)
            Spacer()
            Button { takePhoto() } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().stroke(.white.opacity(0.65), lineWidth: 2)
                    Circle().fill(.white).padding(7)
                    if camera.busy { ProgressView().tint(.black) }
                }.frame(width: 82, height: 82)
            }
            .accessibilityLabel(stack ? "Capturar pila de \(stackCount) fotos" : "Tomar foto")
            .disabled(camera.busy || !camera.ready || countdown > 0)
            Spacer()
            Button { selectLens(lens == .front ? lastBackLens : .front) } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 22, weight: .medium)).frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cambiar entre cámara frontal y trasera")
            .disabled(camera.busy || !camera.ready || countdown > 0 || !camera.lenses.contains(.front))
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 4) {
            modeButton("FOTO", selected: !stack) { stack = false }
            modeButton("PILA \(stackCount)", selected: stack) { stack = true }
        }
        .padding(4).background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1)).disabled(camera.busy || countdown > 0)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(selected ? .yellow : .white).frame(width: 88, height: 40)
                .background(selected ? .white.opacity(0.1) : .clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? .white.opacity(0.5) : .clear, lineWidth: 1))
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectLens(_ next: CameraLens) {
        guard next != lens else { return }
        if next != .front { lastBackLens = next }
        lens = next
        bias = 0
        manualWB = false
        manualExposure = false
        rawEnabled = false
        manualFocus = false
        zoom = 1
        camera.switchLens(next)
    }

    private var shutterLabel: String {
        let seconds = pow(2, shutterStops)
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.2f s", seconds)
    }

    private func applyExposure(enabled: Bool) {
        camera.setManualExposure(iso: enabled ? iso : nil, seconds: pow(2, shutterStops))
    }

    private func takePhoto() {
        let captureStack = stack, count = stackCount, raw = rawEnabled, options = processingOptions
        if timerSeconds == 0 { camera.capture(stack: captureStack, count: count, raw: raw, options: options); return }
        let delay = timerSeconds
        countdownTask = Task { @MainActor in
            do {
                for value in stride(from: delay, through: 1, by: -1) {
                    countdown = value
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = 0
                camera.capture(stack: captureStack, count: count, raw: raw, options: options)
            } catch { countdown = 0 }
        }
    }

    private var review: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Última captura").font(.headline)
                Picker("Imagen", selection: $showReference) {
                    Text("Resultado").tag(false)
                    Text("Referencia").tag(true)
                }.pickerStyle(.segmented)
                if let image = showReference ? camera.referencePreview : camera.preview {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Text(camera.resultDetails).font(.footnote)
                Text("La referencia es el fotograma seleccionado para la fusión. La vista previa de cámara llena la pantalla y puede mostrar un recorte distinto al de la foto.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Guardar resultado y referencia") { camera.save() }
                    .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                    .disabled(camera.busy)
                Text(camera.status).font(.footnote)
                Button("Cerrar") { showResult = false }.disabled(camera.busy)
            }.padding()
        }.preferredColorScheme(.dark)
    }
}
