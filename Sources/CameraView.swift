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
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {}
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
    @State private var stack = false
    @State private var bias: Double = 0
    @State private var manualWB = false
    @State private var temperature: Double = 5000
    @State private var grid = true
    @State private var showControls = false
    @State private var showResult = false
    @State private var showReference = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                CameraPreview(session: camera.session)
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
                    .accessibilityLiveRegion(.polite)
                lensSelector
                captureRow
                modeSelector
            }
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else if phase == .background { camera.stop() }
        }
        .sheet(isPresented: $showResult) { review }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ultimate CAM").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(stack ? "PILA 3 · JPEG · EXPERIMENTAL" : "FOTO · JPEG")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("EXPOSICIÓN", systemImage: "plusminus.circle")
                Spacer()
                Text("\(bias, specifier: "%+.1f") EV").foregroundStyle(.yellow)
            }.font(.system(size: 12, weight: .semibold, design: .rounded))
            Slider(value: $bias, in: -2...2, step: 0.1)
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
                Text("Escena inmóvil y trípode. La pila alinea y promedia tres JPEG; no corrige sujetos en movimiento.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.2), lineWidth: 1))
        .disabled(camera.busy || !camera.ready)
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
        .disabled(camera.busy || !camera.ready)
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
            Button { camera.capture(stack: stack) } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().stroke(.white.opacity(0.65), lineWidth: 2)
                    Circle().fill(.white).padding(7)
                    if camera.busy { ProgressView().tint(.black) }
                }.frame(width: 82, height: 82)
            }
            .accessibilityLabel(stack ? "Capturar pila de tres fotos" : "Tomar foto")
            .disabled(camera.busy || !camera.ready)
            Spacer()
            Button { selectLens(lens == .front ? lastBackLens : .front) } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 22, weight: .medium)).frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cambiar entre cámara frontal y trasera")
            .disabled(camera.busy || !camera.ready || !camera.lenses.contains(.front))
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 4) {
            modeButton("FOTO", selected: !stack) { stack = false }
            modeButton("PILA 3", selected: stack) { stack = true }
        }
        .padding(4).background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1)).disabled(camera.busy)
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
        camera.switchLens(next)
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
                Text("La referencia es el primer fotograma. La vista previa de cámara llena la pantalla y puede mostrar un recorte distinto al de la foto.")
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
