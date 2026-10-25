import Photos
import SwiftUI
import UIKit

struct GuidedSphereView:View {
    @StateObject private var camera=GuidedPhotoCamera()
    @StateObject private var motion=SphereMotionProvider()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var reference:SphereReference?
    @State private var captured=[Int:SphereImageFrame]()
    @State private var pendingTarget:Int?
    @State private var processing=false
    @State private var cancellation:ProcessingCancellation?
    @State private var result:CaptureResult?
    @State private var preview:UIImage?
    @State private var saved=false
    @State private var saving=false
    @State private var message=""
    @State private var interrupted=false
    @State private var closing=false
    @State private var confirmDiscard=false
    @State private var restarting=false
    @State private var interactivePreview=true
    private var direction:SIMD3<Float>? {
        guard let reference,let snapshot=motion.snapshot else { return nil };return try? reference.pose(snapshot).forward
    }
    private var next:SphereTarget? {
        guard captured.count<62 else { return nil }
        guard let direction else { return SphereTarget.all[0] }
        return SphereTarget.all.filter { captured[$0.id]==nil }.min { $0.angle(to:direction)<$1.angle(to:direction) }
    }
    private var angle:Float { if let next,let direction { return next.angle(to:direction) };return reference==nil ? 0:180 }
    private var aimReady:Bool {
        guard !interrupted,let snapshot=motion.snapshot,snapshot.rotationSpeed<0.12 else { return false }
        if reference==nil { return snapshot.gravity.y < -0.6 && abs(snapshot.gravity.z)<0.15 }
        return angle<7
    }
    var body:some View {
        ZStack {
            CameraPreview(session:camera.session,zoom:1,focus:{ point,_ in camera.focus(point) },changeZoom:{_ in}).ignoresSafeArea()
            VStack(spacing:12) {
                HStack {
                    Button { if captured.isEmpty || saved { close() } else { restarting=false;confirmDiscard=true } } label: { Image(systemName:"chevron.left").frame(width:44,height:44) }
                        .accessibilityIdentifier("sphere.close").disabled(camera.busy || processing || saving)
                    Spacer();Text("ESFERA").font(.headline);Spacer();Text("\(captured.count)/62").monospacedDigit()
                }
                if result==nil { coverageMap.frame(height:110).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:10)) }
                if let preview {
                    ScrollView {
                        Picker("Revisión",selection:$interactivePreview) { Text("360°").tag(true);Text("Plana").tag(false) }.pickerStyle(.segmented)
                        if interactivePreview,let cg=preview.cgImage { SphereViewer(image:cg) }
                        else { Image(uiImage:preview).resizable().scaledToFit().padding() }
                        if let result { Text(result.details).font(.footnote).padding(.vertical) }
                    }.scrollBounceBehavior(.basedOnSize)
                }
                if result==nil { Spacer() }
                if result==nil {
                    Text(reference==nil ? "Empieza con el móvil vertical y apunta al horizonte." : "Mantén el teléfono en el mismo punto y gira hacia el siguiente objetivo.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    if let next { Text("Objetivo: giro \(Int(next.yaw))° · altura \(Int(next.pitch))° · distancia \(Int(angle))°").font(.caption.monospacedDigit()) }
                    Image(systemName:aimReady ? "scope":"viewfinder").font(.system(size:40)).foregroundStyle(aimReady ? CameraPalette.accent:.white)
                    HStack {
                        Button("Empezar de nuevo") { restarting=true;confirmDiscard=true }.disabled(camera.busy || processing || saving || captured.isEmpty)
                        Spacer()
                        Button {
                            guard let next else { return };pendingTarget=next.id;camera.capture()
                        } label: { Circle().fill(aimReady ? CameraPalette.accent:.gray).frame(width:64,height:64) }
                            .accessibilityLabel("Añadir vista a la esfera").accessibilityIdentifier("sphere.capture")
                            .disabled(!camera.ready || camera.busy || !aimReady || next==nil || processing)
                        Spacer()
                        Button("Unir") { merge() }.disabled(captured.count<6 || camera.busy || processing)
                    }
                    if processing { ProgressView();Button("Cancelar unión") { cancellation?.cancel() } }
                } else {
                    Button(saved ? "Guardado en Fotos":"Guardar esfera") { save() }.buttonStyle(.borderedProminent).disabled(saved || saving)
                    Button("Volver a las vistas") { result=nil;preview=nil;saved=false }.disabled(saving)
                }
                Text(message.isEmpty ? motion.message:message).font(.footnote).multilineTextAlignment(.center)
                if result==nil { Text(camera.status).font(.caption).multilineTextAlignment(.center) }
                if result==nil { Text("Experimental · JPEG SDR · la calibración del campo de visión necesita comprobación en el iPhone.").font(.caption2).foregroundStyle(.secondary) }
            }.padding().background { LinearGradient(colors:[.black.opacity(0.8),.clear,.black.opacity(0.85)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false) }
        }.foregroundStyle(.white).preferredColorScheme(.dark).tint(CameraPalette.accent)
            .interactiveDismissDisabled(!captured.isEmpty || camera.busy || processing || saving)
            .onAppear { UIApplication.shared.isIdleTimerDisabled=true;camera.motionProvider={ motion.read() };motion.start();camera.start() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled=false;motion.stop();camera.stop();cancellation?.cancel() }
            .onChange(of:camera.frame?.id) { _,id in if id != nil,let frame=camera.frame { accept(frame) } }
            .onChange(of:scene) { _,phase in
                if phase == .background {
                    interrupted = !captured.isEmpty;pendingTarget=nil;motion.stop();camera.stop();cancellation?.cancel();UIApplication.shared.isIdleTimerDisabled=false
                    if interrupted { message="La referencia de orientación se interrumpió. Empieza otra esfera para no mezclar ejes de sesiones distintas." }
                } else if phase == .active && !closing {
                    UIApplication.shared.isIdleTimerDisabled=true;camera.start();if !interrupted { motion.start() }
                }
            }
            .confirmationDialog("¿Descartar las vistas de esta esfera?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button("Descartar vistas",role:.destructive) {
                    if restarting { captured=[:];reference=nil;result=nil;preview=nil;saved=false;interrupted=false;message="";camera.unlock();motion.stop();motion.start() }
                    else { close() }
                };Button("Continuar",role:.cancel) { }
            }
    }
    private var coverageMap:some View {
        Canvas { context,size in
            for target in SphereTarget.all {
                let x=(Double(target.yaw)/360+0.5).truncatingRemainder(dividingBy:1)*size.width
                let y=(0.5-Double(target.pitch)/180)*max(1,size.height-12)+6
                let rect=CGRect(x:x-3,y:y-3,width:6,height:6)
                context.fill(Path(ellipseIn:rect),with:.color(captured[target.id] != nil ? CameraPalette.accent:.white.opacity(0.4)))
            }
            if let direction {
                let yaw=atan2(Double(direction.x),Double(direction.z)),pitch=asin(min(1,max(-1,Double(direction.y))))
                let p=CGPoint(x:(yaw/(2*Double.pi)+0.5)*size.width,y:(0.5-pitch/Double.pi)*max(1,size.height-12)+6)
                context.stroke(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(.white),lineWidth:2)
            }
        }.accessibilityLabel("Vistas esféricas completadas: \(captured.count) de 62")
    }
    private func accept(_ frame:GuidedPhotoFrame) {
        guard scene == .active,!closing else { pendingTarget=nil;return }
        guard let target=pendingTarget,let sample=frame.motion else { message="No se recibió orientación para esa foto; no se añade a la esfera.";pendingTarget=nil;return }
        pendingTarget=nil
        do {
            guard sample.rotationSpeed<0.12 else { throw CameraFailure.message("El teléfono se movió durante la foto. Mantén el objetivo quieto y vuelve a pulsar.") }
            let candidate=try reference ?? SphereReference(sample)
            let pose=try candidate.pose(sample)
            guard SphereTarget.all[target].angle(to:pose.forward)<9 else { throw CameraFailure.message("La foto se hizo fuera del objetivo. No se añade; vuelve a alinear y pulsa.") }
            reference=candidate;captured[target]=SphereImageFrame(data:frame.data,pose:pose,fieldOfView:frame.fieldOfView)
            message="Vista añadida. Gira sin desplazar la cámara."
        } catch { message=error.localizedDescription }
    }
    private func merge() {
        processing=true;let token=ProcessingCancellation();cancellation=token
        let frames=captured.keys.sorted().compactMap { captured[$0] };message="Proyectando las vistas…"
        Task { @MainActor in
            do {
                let merged=try await Task.detached(priority:.userInitiated) { try SphereProcessor().process(frames,cancellation:token) }.value
                try token.check();result=merged;preview=PreviewDecoder.image(merged.jpeg).map { UIImage(cgImage:$0) };message="Revisa las uniones. La proyección incluye metadatos GPano."
            } catch { message=error.localizedDescription }
            processing=false;cancellation=nil
        }
    }
    private func close() { closing=true;motion.stop();camera.stop { dismiss() } }
    private func save() {
        guard let result,!saved,!saving else { return };saving=true
        PHPhotoLibrary.requestAuthorization(for:.addOnly) { permission in
            guard permission == .authorized || permission == .limited else { DispatchQueue.main.async { saving=false;message="Permite añadir fotos en Ajustes. La esfera se conserva." };return }
            PhotoLibraryWriter.save(result,jpegOnly:true,includeReference:false) { outcome in DispatchQueue.main.async {
                saving=false
                switch outcome { case .success:saved=true;message="Esfera guardada.";case .failure(let error):message=error.localizedDescription }
            } }
        }
    }
}
