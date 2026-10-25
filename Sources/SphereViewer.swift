import SwiftUI
import UIKit

private final class SphereViewerController:ObservableObject {
    @Published var frame:CGImage?
    @Published var message=""
    private let queue=DispatchQueue(label:"com.gokuencinar.ultimatecam.sphere-view",qos:.userInitiated)
    private let renderer=SphereViewerRenderer()
    private let lock=NSLock()
    private var pending:(CGImage,Double,Double,Double,UUID)?
    private var running=false
    private var epoch=UUID()
    func request(_ image:CGImage,yaw:Double,pitch:Double,fov:Double) {
        lock.lock();let token=UUID();epoch=token;pending=(image,yaw,pitch,fov,token)
        let start = !running;running=true;lock.unlock()
        guard start else { return }
        queue.async { [weak self] in self?.drain() }
    }
    func cancel() { lock.lock();epoch=UUID();pending=nil;lock.unlock() }
    private func drain() {
        while true {
            lock.lock();let item=pending;pending=nil;if item==nil { running=false };lock.unlock()
            guard let (image,yaw,pitch,fov,token)=item else { return }
            let outcome=Result { try renderer.render(image,yaw:yaw,pitch:pitch,fieldOfView:fov) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return };self.lock.lock();let valid=self.epoch==token;self.lock.unlock()
                guard valid else { return }
                switch outcome { case .success(let cg):self.frame=cg;self.message="";case .failure(let error):self.message=error.localizedDescription }
            }
        }
    }
}

struct SphereViewer:View {
    let image:CGImage
    @StateObject private var renderer=SphereViewerController()
    @State private var yaw=0.0
    @State private var pitch=0.0
    @State private var fov=70.0
    @State private var startYaw=0.0
    @State private var startPitch=0.0
    @State private var startFOV=70.0
    var body:some View {
        VStack(spacing:6) {
            ZStack {
                Color.black
                if let frame=renderer.frame { Image(decorative:frame,scale:1).resizable().scaledToFit() }
                else { ProgressView() }
            }.aspectRatio(1.6,contentMode:.fit).contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    yaw=(startYaw-Double(value.translation.width)*0.006).truncatingRemainder(dividingBy:2*Double.pi)
                    pitch=min(Double.pi*0.49,max(-Double.pi*0.49,startPitch+Double(value.translation.height)*0.006));render()
                }.onEnded { _ in startYaw=yaw;startPitch=pitch })
                .simultaneousGesture(MagnifyGesture().onChanged { value in fov=min(110,max(30,startFOV/Double(value.magnification)));render() }
                    .onEnded { _ in startFOV=fov })
                .accessibilityLabel("Visor esférico. Arrastra para mirar y pellizca para ampliar.")
                .accessibilityAdjustableAction { direction in
                    yaw += direction == .increment ? Double.pi/6 : -Double.pi/6;startYaw=yaw;render()
                }
            HStack { Text("Arrastra · pellizca para ampliar").font(.caption);Spacer();Button("Centrar") { yaw=0;pitch=0;fov=70;startYaw=0;startPitch=0;startFOV=70;render() } }
            if !renderer.message.isEmpty { Text(renderer.message).font(.caption) }
        }.onAppear { render() }.onDisappear { renderer.cancel() }
    }
    private func render() { renderer.request(image,yaw:yaw,pitch:pitch,fov:fov) }
}
