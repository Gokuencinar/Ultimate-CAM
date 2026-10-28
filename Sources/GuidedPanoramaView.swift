import Photos
import AVKit
import SwiftUI
import Combine
import UIKit

struct GuidedPanoramaView:View {
    @AppStorage("hardwareCaptureButtons") private var hardwareButtons=true
    @ObservedObject var camera:GuidedPhotoCamera
    @Binding var modeBusy:Bool
    @Binding var unsavedSequence:Bool
    var interactionEnabled=true
    @Environment(\.scenePhase) private var scene
    @StateObject private var motion=SphereMotionProvider()
    @State private var frames=[Data]()
    @State private var thumbnails=[UIImage]()
    @State private var sweep:PanoramaSweepPlan?
    @State private var sweeping=false
    @State private var pending=false
    @State private var pendingFrameID:UUID?
    @State private var finishRequested=false
    @State private var fieldOfView:Double=65
    @State private var processing=false
    @State private var cancellation:ProcessingCancellation?
    @State private var result:CaptureResult?
    @State private var preview:UIImage?
    @State private var message="Pulsa para empezar y gira despacio. Vuelve a pulsar para terminar."
    @State private var saved=false
    @State private var saving=false
    private let clock=Timer.publish(every:0.1,on:.main,in:.common).autoconnect()
    var body:some View {
        ZStack {
            VStack {
                HStack { Spacer();Text("PANORAMA").font(.headline);Spacer();Text("\(frames.count)/10").monospacedDigit() }
                if let preview { Image(uiImage:preview).resizable().scaledToFit().frame(maxHeight:450).padding(.vertical) }
                Spacer()
                if result==nil { sweepGuide }
                Spacer()
                if processing { ProgressView();Button("Cancelar unión") { cancellation?.cancel() } }
                else if result==nil {
                    HStack {
                        Button("Reiniciar") { reset() }.frame(maxWidth:.infinity).disabled(sweeping || camera.busy || frames.isEmpty)
                        Button { toggleSweep() } label: {
                            ZStack { Circle().stroke(.white,lineWidth:3).frame(width:70,height:70)
                                RoundedRectangle(cornerRadius:sweeping ? 5:30).fill(sweeping ? .red:.white).frame(width:sweeping ? 28:58,height:sweeping ? 28:58)
                            }
                        }.accessibilityIdentifier("panorama.capture").accessibilityLabel(sweeping ? "Terminar barrido":"Iniciar barrido panorámico")
                            .disabled(!camera.ready || finishRequested || (!sweeping && camera.busy))
                        Button("Unir") { merge() }.accessibilityIdentifier("panorama.merge").frame(maxWidth:.infinity).disabled(sweeping || frames.count<2 || camera.busy)
                    }
                } else {
                    Button(saved ? "Guardado en Fotos":"Guardar panorama") { save() }.buttonStyle(.borderedProminent).disabled(saved || saving)
                    Button("Nuevo panorama") { reset() }.disabled(saving)
                }
                Text(message).font(.subheadline).multilineTextAlignment(.center).padding(.vertical,8)
                if !camera.ready { Text(camera.status).font(.caption) }
            }.padding().background { LinearGradient(colors:[.black.opacity(0.75),.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false) }
        }.disabled(!interactionEnabled).foregroundStyle(.white).tint(CameraPalette.accent).preferredColorScheme(.dark)
            .onCameraCaptureEvent(isEnabled:interactionEnabled && hardwareButtons && scene == .active && camera.ready && !processing && !saving && result==nil) { event in
                if event.phase == .ended { toggleSweep() }
            }
            .onAppear { camera.motionProvider={motion.read()};motion.start();publishState() }
            .onDisappear { motion.stop();camera.motionProvider=nil;cancellation?.cancel() }
            .onReceive(clock) { _ in tick() }
            .onChange(of:camera.frame?.id) { _,id in if id != nil,let frame=camera.frame { accept(frame) } }
            .onChange(of:camera.busy) { _,busy in
                if !busy && pending && camera.frame?.id==pendingFrameID {
                    pending=false;sweeping=false;finishRequested=false;message=camera.status
                }
                if !busy && finishRequested && !pending { finish() }
            }
            .onChange(of:scene) { _,phase in
                if phase == .background { sweeping=false;pending=false;finishRequested=false;motion.stop();cancellation?.cancel() }
                else if phase == .active { motion.start() }
            }
            .onChange(of:frames.count) { _,_ in publishState() }
            .onChange(of:saved) { _,_ in publishState() }
            .onChange(of:processing) { _,_ in publishState() }
            .onChange(of:saving) { _,_ in publishState() }
            .onChange(of:sweeping) { _,_ in publishState() }
    }
    private var sweepGuide:some View {
        VStack(spacing:10) {
            GeometryReader { g in
                ZStack(alignment:.leading) {
                    RoundedRectangle(cornerRadius:12).fill(.black.opacity(0.75))
                    Rectangle().fill(.white.opacity(0.6)).frame(height:1)
                    HStack(spacing:1) { ForEach(thumbnails.indices,id:\.self) { i in Image(uiImage:thumbnails[i]).resizable().scaledToFill().frame(width:max(12,(g.size.width-40)/10),height:42).clipped() } }.padding(.horizontal,12).opacity(0.65)
                    Image(systemName:(sweep?.direction ?? 1)>=0 ? "arrow.right":"arrow.left").font(.title2.bold())
                        .foregroundStyle(sweep?.warning==nil ? CameraPalette.accent:.orange)
                        .offset(x:12+max(0,g.size.width-52)*CGFloat(sweep?.progress ?? 0))
                }
            }.frame(height:62)
            ProgressView(value:sweep?.progress ?? 0).accessibilityIdentifier("panorama.progress")
            Text(sweep?.warning ?? (sweeping ? "Sigue la línea y gira desde el mismo punto":"Barrido continuo"))
                .font(.caption).accessibilityIdentifier("panorama.guidance")
        }.accessibilityIdentifier("panorama.sweepGuide")
    }
    private func publishState() { modeBusy=sweeping || processing || saving;unsavedSequence = !frames.isEmpty && !saved }
    private func toggleSweep() {
        guard !processing,!saving else { return }
        if sweeping { finishRequested=true;if !camera.busy && !pending {finish()};return }
        guard frames.isEmpty else { message="Une las vistas guardadas o reinicia antes de otro barrido.";return }
        guard let sample=motion.read() else { message="Esperando orientación. Mantén el teléfono vertical.";motion.start();return }
        do { sweep=try PanoramaSweepPlan(sample);sweeping=true;finishRequested=false;saved=false;message="Gira despacio siguiendo la flecha.";takeFrame() }
        catch { message=error.localizedDescription }
    }
    private func tick() {
        guard scene == .active,interactionEnabled,sweeping,!finishRequested,let sample=motion.read() else { return }
        do {
            try sweep?.update(sample)
            if (sweep?.progress ?? 0)>=1 || frames.count>=10 { finishRequested=true;if !camera.busy && !pending {finish()};return }
            if camera.ready && !camera.busy && !pending && (frames.isEmpty || sweep?.needsFrame(fieldOfView:fieldOfView)==true) { takeFrame() }
        } catch { message=error.localizedDescription }
    }
    private func takeFrame() {
        guard !pending else { return };pending=true;pendingFrameID=camera.frame?.id
        camera.capture { accepted in if !accepted { pending=false } }
    }
    private func accept(_ frame:GuidedPhotoFrame) {
        guard scene == .active,sweeping,pending,frames.count<10 else { return };pending=false
        guard let sample=frame.motion,SphereAim.acceptsMotion(sample,seconds:frame.exposureSeconds,fieldOfView:frame.fieldOfView) else {
            message="Gira más despacio para evitar fotos movidas.";if finishRequested {finish()};return
        }
        do { try sweep?.update(sample);sweep?.captured() } catch { message=error.localizedDescription;return }
        frames.append(frame.data);fieldOfView=frame.fieldOfView
        if let cg=PreviewDecoder.image(frame.data,maximumDimension:180) { thumbnails.append(UIImage(cgImage:cg)) }
        message="";if finishRequested || frames.count>=10 { finish() }
    }
    private func finish() {
        sweeping=false;finishRequested=false;pending=false
        if frames.count>=2 { merge() } else { message="Barrido demasiado corto. Pulsa Reiniciar y gira un poco más." }
    }
    private func reset() {
        frames=[];thumbnails=[];sweep=nil;result=nil;preview=nil;saved=false;pending=false;finishRequested=false;camera.unlock()
        message="Pulsa para empezar y vuelve a pulsar para terminar."
    }
    private func merge() {
        guard frames.count>=2,!processing else { return }
        processing=true;message="Uniendo panorama…";let captured=frames,token=ProcessingCancellation();cancellation=token
        Task { @MainActor in
            do {
                let merged=try await Task.detached(priority:.userInitiated) { try PanoramaProcessor().process(captured,options:ProcessingOptions(),cancellation:token) }.value
                try token.check();result=merged;preview=PreviewDecoder.image(merged.jpeg).map { UIImage(cgImage:$0) };message="Panorama listo para revisar."
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
