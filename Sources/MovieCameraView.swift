import AVKit
import SwiftUI

struct MovieCameraView: View {
    @AppStorage("hardwareCaptureButtons") private var hardwareButtons=true
    @AppStorage("mirrorSelfies") private var mirrorSelfies=false
    @StateObject private var camera=MovieCameraModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var settings=false
    @State private var confirmDiscard=false
    @State private var leaving=false
    @State private var showingReview=false
    private var busy:Bool { [.recording,.finishing,.saving].contains(camera.phase) }
    private var recording:Bool { camera.phase == .recording }
    private func update(_ mutate:(inout MovieConfiguration)->Void) {
        var options=camera.configuration;mutate(&options);camera.configure(options,lens:camera.lens)
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session:camera.session,zoom:camera.zoom,
                focus:{ camera.focus($0,locked:$1) },changeZoom:camera.setZoom).ignoresSafeArea()
            VStack(spacing:12) {
                HStack {
                    Button { close() } label: { Image(systemName:"chevron.left").frame(width:44,height:44) }
                        .accessibilityIdentifier("video.close").accessibilityLabel("Volver a fotos").disabled(busy || leaving)
                    Spacer()
                    Text("VÍDEO").font(.headline).tracking(2)
                    Spacer()
                    Button { settings=true } label: { Image(systemName:"slider.horizontal.3").frame(width:44,height:44) }
                        .accessibilityIdentifier("video.settings").accessibilityLabel("Ajustes de vídeo").disabled(busy || leaving)
                }
                Text(recording ? String(format:"%02d:%02d",Int(camera.elapsed)/60,Int(camera.elapsed)%60) :
                    "\(camera.configuration.resolution.label) · \(camera.configuration.fps) · \(camera.configuration.codec.label)")
                    .font(.subheadline.monospacedDigit().bold()).padding(8).background(recording ? .red : Color.black.opacity(0.6),in:Capsule())
                Spacer()
                if !busy {
                    HStack {
                        ForEach(camera.lenses) { lens in
                            Button(lens.label) { camera.configure(camera.configuration,lens:lens) }
                                .buttonStyle(.bordered).tint(camera.lens==lens ? CameraPalette.accent : .white)
                        }
                    }
                }
                HStack {
                    Button { camera.toggleTorch() } label: { Image(systemName:camera.torch ? "bolt.fill":"bolt.slash").frame(width:50,height:50) }
                        .accessibilityLabel("Antorcha de vídeo").disabled(!camera.torchAvailable || camera.phase == .finishing)
                    Spacer()
                    Button { recording ? camera.stopRecording() : camera.record(mirrorSelfie:mirrorSelfies) } label: {
                        ZStack {
                            Circle().stroke(.white,lineWidth:3).frame(width:76,height:76)
                            RoundedRectangle(cornerRadius:recording ? 6:32).fill(.red).frame(width:recording ? 30:60,height:recording ? 30:60)
                        }
                    }.accessibilityIdentifier("video.record").accessibilityLabel(recording ? "Detener vídeo":"Grabar vídeo")
                        .disabled(leaving || (!recording && (!camera.ready || camera.phase != .idle)))
                    Spacer()
                    Button { showingReview=true } label: { Image(systemName:"play.rectangle").frame(width:50,height:50) }
                        .accessibilityLabel("Revisar vídeo").disabled(camera.previewURL == nil || busy)
                }
                Text(camera.status).font(.footnote).multilineTextAlignment(.center).frame(maxWidth:.infinity,minHeight:35)
                Text("SDR · hasta 10 min o 2 GB").font(.caption2).foregroundStyle(.secondary)
            }.padding().background(alignment:.top) {
                LinearGradient(colors:[.black.opacity(0.75),.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false)
            }
        }.foregroundStyle(.white).preferredColorScheme(.dark)
            .onCameraCaptureEvent(isEnabled:hardwareButtons && scene == .active && !settings && !showingReview && !confirmDiscard && !leaving &&
                                  (recording || (camera.ready && camera.phase == .idle))) { event in
                guard event.phase == .ended else { return };recording ? camera.stopRecording():camera.record(mirrorSelfie:mirrorSelfies)
            }
            .interactiveDismissDisabled(busy || (camera.previewURL != nil && !camera.saved))
            .onAppear { UIApplication.shared.isIdleTimerDisabled=true;camera.start() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled=false;camera.shutdown() }
            .onChange(of:scene) { _,phase in
                if phase == .background { UIApplication.shared.isIdleTimerDisabled=false;camera.shutdown() }
                else if phase == .active && !leaving { UIApplication.shared.isIdleTimerDisabled=true;camera.start(camera.configuration,lens:camera.lens) }
            }
            .sheet(isPresented:$settings) { configuration }
            .sheet(isPresented:$showingReview) { review }
            .confirmationDialog("¿Descartar el vídeo sin guardar?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button("Descartar vídeo",role:.destructive) { camera.clear { if leaving { camera.shutdown { dismiss() } } } }
                Button("Seguir revisando",role:.cancel) { leaving=false }
            }
    }
    private func close() {
        if camera.previewURL != nil && !camera.saved { leaving=true;confirmDiscard=true }
        else if camera.previewURL != nil { leaving=true;camera.clear { camera.shutdown { dismiss() } } }
        else { leaving=true;camera.shutdown { dismiss() } }
    }
    private var configuration:some View {
        NavigationStack {
            Form {
                Picker("Resolución",selection:Binding(get:{camera.configuration.resolution},set:{v in update {$0.resolution=v} })) {
                    ForEach(MovieResolution.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("video.resolution")
                Picker("FPS",selection:Binding(get:{camera.configuration.fps},set:{v in update {$0.fps=v} })) {
                    ForEach([24,30,60],id:\.self) { Text("\($0)").tag($0) }
                }.accessibilityIdentifier("video.fps")
                Picker("Códec",selection:Binding(get:{camera.configuration.codec},set:{v in update {$0.codec=v} })) {
                    ForEach(MovieCodec.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Grabar audio",isOn:Binding(get:{camera.configuration.audio},set:{v in update {$0.audio=v} }))
                Toggle("Solicitar estabilización",isOn:Binding(get:{camera.configuration.stabilized},set:{v in update {$0.stabilized=v} }))
                Toggle("Guardar selfies reflejadas",isOn:$mirrorSelfies)
                Toggle("Disparar con botones de volumen",isOn:$hardwareButtons)
                Text("Las combinaciones disponibles dependen de cada lente. El sistema elige la estabilización compatible. HEVC ocupa menos espacio; H.264 tiene mayor compatibilidad. Los ajustes de color de Fotos no se aplican al vídeo.").font(.footnote)
                Text(camera.status).font(.footnote)
            }.navigationTitle("Vídeo").toolbar { Button("Listo") { settings=false } }
        }.tint(CameraPalette.accent).preferredColorScheme(.dark)
    }
    private var review:some View {
        NavigationStack {
            VStack {
                if let url=camera.previewURL {
                    MoviePlayback(url:url).frame(minHeight:280)
                    ShareLink(item:url) { Label("Compartir archivo",systemImage:"square.and.arrow.up") }
                }
                Text(camera.status).font(.footnote).padding()
                Button(camera.saved ? "Guardado en Fotos":"Guardar vídeo en Fotos") { camera.save() }
                    .buttonStyle(.borderedProminent).disabled(busy || camera.saved || camera.saveUncertain)
                Button(camera.saved ? "Nueva grabación":"Descartar y grabar otro",role:camera.saved ? nil:.destructive) {
                    if camera.saved { camera.clear { showingReview=false } }
                    else { leaving=false;confirmDiscard=true;showingReview=false }
                }.disabled(busy)
            }.padding().navigationTitle("Vídeo grabado").toolbar { Button("Cerrar") { showingReview=false } }
        }.tint(CameraPalette.accent).preferredColorScheme(.dark)
    }
}

/// Keep playback stable when PhotoKit status or review buttons change.
private struct MoviePlayback:View {
    let url:URL
    @State private var player:AVPlayer?
    var body:some View {
        VideoPlayer(player:player)
            .onAppear { if player==nil { player=AVPlayer(url:url) } }
            .onChange(of:url) { _,value in player?.pause();player=AVPlayer(url:value) }
            .onDisappear { player?.pause() }
    }
}
