import Foundation
import Combine
import UIKit

/// Expiring intent for the optional, separately scoped Camera companion. It
/// never requests a photo: the user operates Apple's Camera after handoff.
final class NativeNightCoordinator: ObservableObject {
    @Published private(set) var opening = false
    @Published var showMessage = false
    @Published private(set) var message = ""
    private var tokens: [String:Int32] = [:]
    private var pendingRequest: UInt64?
    private let intent = "com.gokuencinar.ultimatecam.native-night.intent"
    private let status = "com.gokuencinar.ultimatecam.native-night.status"
    private let ack = "com.gokuencinar.ultimatecam.native-night.ack"
    private let resolved = "com.gokuencinar.ultimatecam.native-night.resolved"
    private let changed = "com.gokuencinar.ultimatecam.native-night.changed"

    deinit { for token in tokens.values { notify_cancel(token) } }
    private func token(_ name: String) -> Int32? {
        if let value=tokens[name] { return value }
        var value:Int32=0
        guard notify_register_check(name,&value)==0 else { return nil }
        tokens[name]=value;return value
    }
    private func read(_ name: String) -> UInt64 {
        guard let token=token(name) else { return 0 }
        var value:UInt64=0
        guard notify_get_state(token,&value)==0 else { return 0 }
        return value
    }
    private func report(_ text: String) { message=text;showMessage=true }

    func open(camera: CameraModel) {
        guard !opening else { return }
        opening=true
        camera.prepareNativeHandoff { [weak self] accepted in
            guard let self else { return }
            guard accepted, let token=self.token(self.intent) else {
                self.opening=false;self.report("No se pudo liberar la sesión para Cámara de Apple.");return
            }
            let now=UInt64(Date().timeIntervalSince1970)
            let request=UCNMakeIntent(now,120,UInt8.random(in:0...255))
            guard request != 0, notify_set_state(token,request)==0, notify_post(self.changed)==0,
                  let url=URL(string:"camera://") else {
                self.opening=false;camera.start();self.report("No se pudo solicitar Noche nativa.");return
            }
            self.pendingRequest=request
            UIApplication.shared.open(url,options:[:]) { opened in
                DispatchQueue.main.async {
                    self.opening=false
                    if !opened {
                        _ = notify_set_state(token,0);_ = notify_post(self.changed)
                        self.pendingRequest=nil;camera.start()
                        self.report("iOS no permitió abrir Cámara. La solicitud se ha cancelado.")
                    }
                }
            }
        }
    }

    func returnedToApp() {
        guard let expected=pendingRequest else { return }
        pendingRequest=nil
        let reply=read(ack),code=read(status),nativeMode=read(resolved)
        if let token=token(intent) { _ = notify_set_state(token,0);_ = notify_post(changed) }
        CaptureTrace.record("nativeNight.return",["ackMatches":reply==expected,"status":code,"nativeMode":nativeMode])
        if reply==expected && nativeMode==2 && (code==4 || code==6) {
            report("El complemento confirmó el ajuste Noche máximo en Cámara de Apple. La foto y su calidad no se comprueban por esta señal. Puedes importar el resultado desde la galería.")
        } else if code==2 || code==3 {
            report("El complemento de Noche nativa no admite este dispositivo, sistema o firma de métodos.")
        } else {
            report("No se recibió confirmación de Noche nativa. Comprueba que el complemento esté instalado y permitido en Cámara y que uses un modo y una lente compatibles.")
        }
    }
}
