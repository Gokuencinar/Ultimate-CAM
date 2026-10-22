import SwiftUI
import AVFoundation
import UIKit

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {}
}

struct CameraView: View {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var lens = CameraLens.wide
    @State private var stack = false
    @State private var bias: Double = 0
    @State private var manualWB = false
    @State private var temperature: Double = 5000
    @State private var showResult = false

    var body: some View {
        ScrollView {
          VStack(spacing: 10) {
            Text("Ultimate CAM · prototipo").font(.headline)
            CameraPreview(session: camera.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .background(.black)
            Text(camera.status).font(.footnote).frame(minHeight: 36)
            Picker("Cámara", selection: $lens) {
                ForEach(camera.lenses) { item in Text(item.label).tag(item) }
            }
            .pickerStyle(.segmented)
            .onChange(of: lens) { _, value in
                bias = 0
                manualWB = false
                camera.switchLens(value)
            }
            VStack(alignment: .leading) {
                Toggle("Pila de 3 fotos · escena inmóvil / trípode", isOn: $stack)
                Text("Exposición: \(bias, specifier: "%.1f") EV")
                Slider(value: $bias, in: -2...2, step: 0.1)
                    .onChange(of: bias) { _, value in camera.setBias(Float(value)) }
                Toggle("Balance de blancos manual", isOn: $manualWB)
                    .onChange(of: manualWB) { _, value in
                        camera.setWhiteBalance(value ? Float(temperature) : nil)
                    }
                if manualWB {
                    Text("Temperatura: \(Int(temperature)) K")
                    Slider(value: $temperature, in: 2500...8000, step: 100)
                        .onChange(of: temperature) { _, value in camera.setWhiteBalance(Float(value)) }
                }
            }
            .disabled(camera.busy || !camera.ready)
            HStack {
                Button("Capturar", systemImage: "camera.shutter.button.fill") {
                    camera.capture(stack: stack)
                }
                .buttonStyle(.borderedProminent)
                .disabled(camera.busy || !camera.ready)
                Button("Revisar", systemImage: "photo") { showResult = true }
                    .disabled(camera.preview == nil || camera.busy)
            }
        }
          .padding()
        }
        .disabled(camera.busy)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else if phase == .background { camera.stop() }
        }
        .sheet(isPresented: $showResult) {
            ScrollView {
              VStack(spacing: 16) {
                if let image = camera.preview {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Text(camera.resultDetails).font(.footnote)
                Text("La referencia es el primer fotograma de esta captura. Para comparar con Cámara de Apple, toma otra foto allí.")
                    .font(.caption)
                Button("Guardar resultado y referencia") { camera.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.busy)
                Text(camera.status).font(.footnote)
                Button("Cerrar") { showResult = false }.disabled(camera.busy)
              }.padding()
            }
        }
    }
}
