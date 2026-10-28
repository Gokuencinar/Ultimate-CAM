import Photos
import AVKit
import SwiftUI
import UIKit

struct GuidedPanoramaView:View {
    @AppStorage("hardwareCaptureButtons") private var hardwareButtons=true
    @ObservedObject var camera:GuidedPhotoCamera
    @Binding var modeBusy:Bool
    @Binding var unsavedSequence:Bool
    var interactionEnabled=true
    @Environment(\.scenePhase) private var scene
    @State private var frames=[Data]()
    @State private var processing=false
    @State private var cancellation:ProcessingCancellation?
    @State private var result:CaptureResult?
    @State private var preview:UIImage?
    @State private var message=""
    @State private var saved=false
    @State private var saving=false
    var body:some View {
        ZStack {

            if let last=frames.last,let cg=PreviewDecoder.image(last,maximumDimension:600),result==nil {
                GeometryReader { g in
                    Image(decorative:cg,scale:1).resizable().scaledToFill().frame(width:g.size.width,height:g.size.height).clipped().opacity(0.18)
                }.allowsHitTesting(false)
            }
            VStack {
                HStack {
                    Spacer();Text("PANORAMA").font(.headline);Spacer()
                    Text("\(frames.count)/10").monospacedDigit()
                }
                if let preview { Image(uiImage:preview).resizable().scaledToFit().frame(maxHeight:450).padding(.vertical) }
                Spacer()
                Text(result==nil ? "Gira desde el mismo punto. Mantén el horizonte y un 40–60 % de solapamiento entre fotos." : result!.details)
                    .font(.subheadline).padding().background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
                if processing {
                    ProgressView();Button("Cancelar unión") { cancellation?.cancel() }
                } else if result==nil {
                    HStack {
                        Button("Deshacer") { if !frames.isEmpty { frames.removeLast() };if frames.isEmpty { camera.unlock() } }
                            .frame(maxWidth:.infinity).disabled(frames.isEmpty || camera.busy).opacity(frames.isEmpty ? 0.35:1)
                        Button { camera.capture() } label: { Circle().fill(.white).frame(width:64,height:64).overlay(Circle().stroke(.black,lineWidth:3).padding(5)) }
                            .accessibilityIdentifier("panorama.capture").accessibilityLabel("Añadir foto al panorama").disabled(!camera.ready || camera.busy || frames.count>=10)
                        Button("Unir") { merge() }.frame(maxWidth:.infinity).disabled(frames.count<2 || camera.busy).opacity(frames.count<2 ? 0.35:1)
                    }
                } else {
                    Button(saved ? "Guardado en Fotos":"Guardar panorama") { save() }.buttonStyle(.borderedProminent).disabled(saved || saving)
                    Button("Volver a los fotogramas") { result=nil;preview=nil;saved=false }.disabled(saving)
                }
                Text(message.isEmpty ? camera.status:message).font(.footnote).multilineTextAlignment(.center).padding(.vertical,6)
            }.padding().background { LinearGradient(colors:[.black.opacity(0.75),.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false) }
        }.disabled(!interactionEnabled).foregroundStyle(.white).tint(CameraPalette.accent).preferredColorScheme(.dark)
            .onCameraCaptureEvent(isEnabled:interactionEnabled && hardwareButtons && scene == .active && camera.ready && !camera.busy && !processing && !saving &&
                                  result==nil && frames.count<10) { event in
                if event.phase == .ended { camera.capture() }
            }
            .onAppear { publishState() }
            .onDisappear { cancellation?.cancel() }
            .onChange(of:camera.frame?.id) { _,id in if scene == .active,id != nil,let data=camera.frame?.data,frames.count<10 { frames.append(data);message="" } }
            .onChange(of:scene) { _,phase in
                if phase == .background { cancellation?.cancel() }
            }
            .onChange(of:frames.count) { _,_ in publishState() }
            .onChange(of:saved) { _,_ in publishState() }
            .onChange(of:processing) { _,_ in publishState() }
            .onChange(of:saving) { _,_ in publishState() }
    }
    private func publishState() { modeBusy=processing || saving;unsavedSequence = !frames.isEmpty && !saved }
    private func merge() {
        processing=true;message="Registrando perspectivas…";let captured=frames,token=ProcessingCancellation();cancellation=token
        Task { @MainActor in
            do {
                let merged=try await Task.detached(priority:.userInitiated) {
                    try PanoramaProcessor().process(captured,options:ProcessingOptions(),cancellation:token)
                }.value
                try token.check();result=merged;preview=PreviewDecoder.image(merged.jpeg).map { UIImage(cgImage:$0) };message="Revisa las uniones antes de guardar."
            } catch { message=error.localizedDescription }
            processing=false;cancellation=nil
        }
    }
    private func save() {
        guard let result,!saving,!saved else { return };saving=true
        PHPhotoLibrary.requestAuthorization(for:.addOnly) { permission in
            guard permission == .authorized || permission == .limited else { DispatchQueue.main.async { saving=false;message="Permite añadir fotos en Ajustes. El panorama sigue disponible." };return }
            PhotoLibraryWriter.save(result,jpegOnly:true,includeReference:false) { outcome in DispatchQueue.main.async {
                saving=false
                switch outcome { case .success:saved=true;message="Panorama guardado.";case .failure(let error):message=error.localizedDescription }
            } }
        }
    }
}
