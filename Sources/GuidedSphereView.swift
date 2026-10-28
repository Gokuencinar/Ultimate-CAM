import Photos
import AVKit
import SwiftUI
import Combine
import UIKit

struct GuidedSphereView:View {
    @AppStorage("hardwareCaptureButtons") private var hardwareButtons=true
    @ObservedObject var camera:GuidedPhotoCamera
    @Binding var modeBusy:Bool
    @Binding var unsavedSequence:Bool
    var interactionEnabled=true
    @StateObject private var motion=SphereMotionProvider()
    @AppStorage("sphereAutoCapture") private var autoCapture=false
    @State private var autoGate=SphereAutoCaptureGate()
    @State private var lastFieldOfView:Double=67
    private let clock=Timer.publish(every:0.1,on:.main,in:.common).autoconnect()
    @Environment(\.scenePhase) private var scene
    @State private var reference:SphereReference?
    @State private var captured=[Int:SphereImageFrame]()
    @State private var pendingTarget:Int?
    @State private var pendingFrameID:UUID?
    @State private var pendingReference:SphereReference?
    @State private var pendingPose:SpherePose?
    @State private var processing=false
    @State private var cancellation:ProcessingCancellation?
    @State private var result:CaptureResult?
    @State private var preview:UIImage?
    @State private var saved=false
    @State private var saving=false
    @State private var message=""
    @State private var interrupted=false
    @State private var confirmDiscard=false
    @State private var interactivePreview=true
    private var direction:SIMD3<Float>? {
        guard let snapshot=motion.snapshot else { return nil }
        guard let candidate=reference ?? (try? SphereReference(snapshot)) else { return nil };return try? candidate.pose(snapshot).forward
    }
    private var next:SphereTarget? {
        guard captured.count<SphereTarget.all.count else { return nil }
        guard let direction else { return SphereTarget.all[0] }
        return SphereNodeSelection.next(captured:Set(captured.keys),direction:direction)
    }
    private var angle:Float { if let next,let direction { return next.angle(to:direction) };return reference==nil ? 0:180 }
    private var aimReady:Bool {
        guard !interrupted,let snapshot=motion.read() else { return false }
        return (try? SphereAim.make(snapshot,reference:reference,captured:Set(captured.keys))) != nil
    }
    private func requestCapture() {
        guard !interrupted,camera.ready,!camera.busy,!processing,pendingTarget==nil else { return }
        guard let sample=motion.read() else { message="Esperando orientación. Mantén el teléfono quieto o pulsa Reintentar orientación.";motion.start();return }
        do {
            let aim=try SphereAim.make(sample,reference:reference,captured:Set(captured.keys))
            pendingReference=aim.reference;pendingPose=try aim.reference.pose(sample);pendingTarget=aim.target.id;pendingFrameID=camera.frame?.id;message="";autoGate.reset()
            camera.capture(motion:sample) { accepted in if !accepted { pendingTarget=nil;pendingReference=nil;pendingPose=nil;message=camera.status } }
        } catch { message=error.localizedDescription }
    }
    var body:some View {
        ZStack {

            VStack(spacing:12) {
                HStack {
                    Spacer();Text("ESFERA").font(.headline);Spacer();Text("\(captured.count)/62").monospacedDigit()
                }
                if result==nil { coverageMap.frame(maxWidth:.infinity).frame(height:110).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:10)) }
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
                    Text(reference==nil ? "Sujeta el móvil vertical y apunta a la escena. Pulsa para empezar." : "Mantén el teléfono en el mismo punto y gira hacia el siguiente objetivo.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    if let next { Text("Objetivo: giro \(Int(next.yaw))° · altura \(Int(next.pitch))° · distancia \(Int(angle))°").font(.caption.monospacedDigit()) }
                    Toggle("Captura automática",isOn:$autoCapture).font(.subheadline).accessibilityIdentifier("sphere.autoCapture")
                    HStack {
                        Button("Reiniciar") { confirmDiscard=true }.font(.subheadline)
                            .accessibilityLabel("Empezar la esfera de nuevo").frame(maxWidth:.infinity)
                            .disabled(camera.busy || processing || saving || captured.isEmpty).opacity(captured.isEmpty ? 0.35:1)
                        Button { requestCapture() } label: { Circle().fill(camera.ready ? (aimReady ? CameraPalette.accent:.white):.gray).frame(width:64,height:64) }
                            .accessibilityLabel("Añadir vista a la esfera").accessibilityIdentifier("sphere.capture")
                            .disabled(!camera.ready || camera.busy || interrupted || next==nil || processing)
                        Button("Unir") { merge() }.accessibilityIdentifier("sphere.merge").frame(maxWidth:.infinity).disabled(captured.count<2 || camera.busy || processing).opacity(captured.count<2 ? 0.35:1)
                    }
                    if processing { ProgressView();Button("Cancelar unión") { cancellation?.cancel() } }
                } else {
                    Button(saved ? "Guardado en Fotos":"Guardar esfera") { save() }.buttonStyle(.borderedProminent).disabled(saved || saving)
                    Button("Volver a las vistas") { result=nil;preview=nil;saved=false }.disabled(saving)
                }
                Text(message.isEmpty ? motion.message:message).font(.footnote).multilineTextAlignment(.center)
                if result==nil { Text(camera.status).font(.caption).multilineTextAlignment(.center) }
                if motion.snapshot==nil && result==nil {
                    Button("Reintentar orientación") { motion.stop();motion.start();message="" }
                        .accessibilityIdentifier("sphere.retryMotion").disabled(camera.busy || processing)
                }
            }.padding().background { LinearGradient(colors:[.black.opacity(0.8),.clear,.black.opacity(0.85)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false) }
        }.overlay {
            if result==nil { targetOverlay.allowsHitTesting(false) }
        }.disabled(!interactionEnabled).foregroundStyle(.white).preferredColorScheme(.dark).tint(CameraPalette.accent)
            .onCameraCaptureEvent(isEnabled:interactionEnabled && hardwareButtons && scene == .active && camera.ready && !camera.busy && !processing && !saving &&
                                  !confirmDiscard && result==nil && !interrupted && next != nil) { event in
                if event.phase == .ended { requestCapture() }
            }
            .onAppear { publishState();camera.motionProvider={ motion.read() };motion.start() }
            .onReceive(clock) { _ in autoTick() }
            .onChange(of:autoCapture) { _,_ in autoGate.reset() }
            .onDisappear { motion.stop();camera.motionProvider=nil;cancellation?.cancel() }
            .onChange(of:camera.frame?.id) { _,id in if id != nil,let frame=camera.frame { accept(frame) } }
            .onChange(of:camera.busy) { _,busy in
                if !busy,pendingTarget != nil,camera.frame?.id==pendingFrameID {
                    pendingTarget=nil;pendingReference=nil;pendingPose=nil;autoGate.reset();message=camera.status;autoCapture=false
                }
            }
            .onChange(of:scene) { _,phase in
                if phase == .background {
                    interrupted = !captured.isEmpty;pendingTarget=nil;pendingReference=nil;pendingPose=nil;motion.stop();cancellation?.cancel()
                    if interrupted { message="La referencia de orientación se interrumpió. Empieza otra esfera para no mezclar ejes de sesiones distintas." }
                } else if phase == .active {
                    if !interrupted { motion.start() }
                }
            }
            .confirmationDialog("¿Descartar las vistas de esta esfera?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button("Descartar vistas",role:.destructive) {
                    captured=[:];reference=nil;pendingReference=nil;pendingPose=nil;pendingTarget=nil;result=nil;preview=nil;saved=false;interrupted=false;message="";camera.unlock();motion.stop();motion.start()
                };Button("Continuar",role:.cancel) { }
            }
            .onChange(of:captured.count) { _,_ in publishState() }
            .onChange(of:saved) { _,_ in publishState() }
            .onChange(of:processing) { _,_ in publishState() }
            .onChange(of:saving) { _,_ in publishState() }
    }
    private func publishState() { modeBusy=processing || saving;unsavedSequence = !captured.isEmpty && !saved }
    private var coverageMap:some View {
        Canvas { context,size in
            for target in SphereTarget.all {
                let point=SphereNodeSelection.point(yaw:Double(target.yaw),pitch:Double(target.pitch),size:size)
                let x=point.x,y=point.y
                let rect=CGRect(x:x-3,y:y-3,width:6,height:6)
                context.fill(Path(ellipseIn:rect),with:.color(captured[target.id] != nil ? CameraPalette.accent:(pendingTarget==target.id ? .orange:.white.opacity(0.4))))
            }
            if let direction {
                let yaw=atan2(Double(direction.x),Double(direction.z)),pitch=asin(min(1,max(-1,Double(direction.y))))
                let p=SphereNodeSelection.point(yaw:yaw*180/Double.pi,pitch:pitch*180/Double.pi,size:size)
                context.stroke(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(.white),lineWidth:2)
            }
        }.accessibilityLabel("Vistas esféricas completadas: \(captured.count) de 62")
    }
    private func accept(_ frame:GuidedPhotoFrame) {
        guard scene == .active else { pendingTarget=nil;pendingReference=nil;pendingPose=nil;return }
        guard let target=pendingTarget,SphereTarget.all.indices.contains(target) else { return }
        let initialReference=pendingReference,atShutter=pendingPose
        pendingTarget=nil;pendingReference=nil;pendingPose=nil
        do {
            let candidate=reference ?? initialReference
            let capturedPose=frame.motion.flatMap { sample in candidate.flatMap { try? $0.pose(sample) } }
            let pose=SphereCaptureOrientation.resolve(captured:capturedPose,atShutter:atShutter,target:SphereTarget.all[target])
            guard SphereNodeSelection.completedTarget(planned:target,pose:pose,first:reference==nil) != nil else { throw CameraFailure.message("La foto se hizo fuera del objetivo. No se añade; vuelve a alinear y pulsa.") }
            reference=candidate;captured[target]=SphereImageFrame(data:frame.data,pose:pose,fieldOfView:frame.fieldOfView)
            lastFieldOfView=frame.fieldOfView;autoGate.reset();UINotificationFeedbackGenerator().notificationOccurred(.success)
            message="Vista añadida. Gira sin desplazar la cámara."
        } catch { message=error.localizedDescription;if captured.isEmpty { camera.unlock() } }
    }
    private func autoTick() {
        guard autoCapture,interactionEnabled,scene == .active,!confirmDiscard,!interrupted,result==nil,!processing,!saving,camera.ready,!camera.busy,pendingTarget==nil,
              let sample=motion.read(),let aim=try? SphereAim.make(sample,reference:reference,captured:Set(captured.keys)) else { autoGate.reset();return }
        if autoGate.update(target:aim.target.id,stable:sample.rotationSpeed<0.12,time:ProcessInfo.processInfo.systemUptime) { requestCapture() }
    }
    private var targetOverlay:some View {
        GeometryReader { g in
            let viewport=UIScreen.main.bounds.size
            let origin=g.frame(in:.global).origin
            ZStack {
                Image(systemName:"plus").font(.system(size:22,weight:.light)).foregroundStyle(.white)
                    .position(x:viewport.width/2-origin.x,y:viewport.height/2-origin.y)
                if let sample=motion.snapshot,let ref=reference ?? (try? SphereReference(sample)),let pose=try? ref.pose(sample) {
                    ForEach(SphereTarget.all.filter{captured[$0.id]==nil}) { target in
                        if let point=SphereNodeSelection.projected(target,pose:pose,size:viewport,fieldOfView:lastFieldOfView) {
                            Circle().stroke(target.id==next?.id ? CameraPalette.accent:.white.opacity(0.6),lineWidth:target.id==next?.id ? 3:2)
                                .frame(width:40,height:40).position(x:point.x-origin.x,y:point.y-origin.y)
                        }
                    }
                    if let next,SphereNodeSelection.projected(next,pose:pose,size:viewport,fieldOfView:lastFieldOfView)==nil {
                        let ray=pose.sphereToDevice*next.direction
                        let arrow=abs(ray.y)>abs(ray.x) ? (ray.y>0 ? "arrow.up":"arrow.down"):(ray.x<0 ? "arrow.left":"arrow.right")
                        Label("Gira hacia el siguiente objetivo",systemImage:arrow).font(.subheadline.bold())
                            .padding(10).background(.black.opacity(0.65),in:Capsule())
                            .position(x:viewport.width/2-origin.x,y:viewport.height/2+70-origin.y)
                    }
                }
            }
        }
    }
    private func merge() {
        guard captured.count>=2,!processing,pendingTarget==nil else { return }
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
