import AVKit
import SwiftUI

/// Settings and review only. Live video belongs to CameraView's persistent visor.
struct MovieSettingsFields:View {
    @ObservedObject var camera:MovieCameraModel
    var configuring=false
    let configure:(MovieConfiguration,CameraLens)->Void
    private func update(_ change:(inout MovieConfiguration)->Void) {
        var request=camera.configuration;change(&request);configure(request,camera.lens)
    }
    var body:some View {
        Group {
            Picker(selection:Binding(get:{camera.configuration.resolution},set:{ value in update { $0.resolution=value } })) {
                ForEach(MovieResolution.allCases) { Text($0.label).tag($0) }
            } label: { Label("Resolución",systemImage:"viewfinder") }.accessibilityIdentifier("video.resolution")
            Picker(selection:Binding(get:{camera.configuration.fps},set:{ value in update { $0.fps=value } })) {
                ForEach([24,30,60],id:\.self) { Text("\($0) FPS").tag($0) }
            } label: { Label("Fotogramas",systemImage:"speedometer") }.accessibilityIdentifier("video.fps")
            Picker(selection:Binding(get:{camera.configuration.codec},set:{ value in update { $0.codec=value } })) {
                ForEach(MovieCodec.allCases) { Text($0.label).tag($0) }
            } label: { Label("Formato",systemImage:"film") }
            Toggle(isOn:Binding(get:{camera.configuration.audio},set:{ value in update { $0.audio=value } })) { Label("Audio",systemImage:"mic") }
            Toggle(isOn:Binding(get:{camera.configuration.stabilized},set:{ value in update { $0.stabilized=value } })) { Label("Estabilización",systemImage:"hand.raised") }
        }.disabled(configuring || [.recording,.finishing,.saving].contains(camera.phase))
    }
}

struct MovieReview:View {
    @ObservedObject var camera:MovieCameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard=false
    private var busy:Bool { [.recording,.finishing,.saving].contains(camera.phase) }
    var body:some View {
        NavigationStack {
            VStack(spacing:20) {
                if let url=camera.previewURL {
                    MoviePlayback(url:url).frame(minHeight:280)
                    ShareLink(item:url) { Label("Compartir",systemImage:"square.and.arrow.up") }
                }
                Text(camera.status).font(.footnote).multilineTextAlignment(.center)
                Button(camera.saved ? "Guardado en Fotos":"Guardar en Fotos") { camera.save() }
                    .buttonStyle(.borderedProminent).disabled(busy || camera.saved || camera.saveUncertain)
                Button(camera.saved ? "Nueva grabación":"Descartar vídeo",role:camera.saved ? nil:.destructive) {
                    if camera.saved { camera.clear { dismiss() } } else { confirmDiscard=true }
                }.disabled(busy)
            }.padding().navigationTitle("Vídeo grabado").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cerrar") { dismiss() }.disabled(busy) }
                .confirmationDialog("¿Descartar el vídeo?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                    Button("Descartar",role:.destructive) { camera.clear { dismiss() } }
                }
        }.preferredColorScheme(.dark).tint(CameraPalette.accent).interactiveDismissDisabled(busy)
    }
}

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
