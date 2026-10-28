import Combine
import CoreMotion
import Foundation
import simd

final class SphereMotionProvider:ObservableObject {
    @Published private(set) var snapshot:SphereMotionSnapshot?
    @Published private(set) var message="Preparando orientación…"
    private let manager=CMMotionManager()
    private let queue:OperationQueue={ let q=OperationQueue();q.name="com.gokuencinar.ultimatecam.sphere-motion";q.maxConcurrentOperationCount=1;q.qualityOfService = .userInitiated;return q }()
    private let lock=NSLock()
    private var latest:SphereMotionSnapshot?
    private var token=UUID()
    private var active=false
    func start() {
        guard manager.isDeviceMotionAvailable else { message="Este entorno no dispone de orientación de cámara.";return }
        lock.lock();if active { lock.unlock();return };active=true;token=UUID();let epoch=token;lock.unlock()
        manager.deviceMotionUpdateInterval=1.0/30
        let supported=CMMotionManager.availableAttitudeReferenceFrames()
        let reference:CMAttitudeReferenceFrame=supported.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical:.xArbitraryZVertical
        var lastUI:Double=0
        manager.startDeviceMotionUpdates(using:reference,to:queue) { [weak self] motion,error in
            guard let self else { return }
            guard let motion else {
                if let error { DispatchQueue.main.async {
                    self.lock.lock();let valid=self.active && self.token==epoch
                    self.lock.unlock()
                    if valid { self.message=error.localizedDescription }
                } };return
            }
            let m=motion.attitude.rotationMatrix,g=motion.gravity,r=motion.rotationRate
            let value=SphereMotionSnapshot(rotation:simd_float3x3(columns:(SIMD3(Float(m.m11),Float(m.m21),Float(m.m31)),SIMD3(Float(m.m12),Float(m.m22),Float(m.m32)),SIMD3(Float(m.m13),Float(m.m23),Float(m.m33)))),
                gravity:SIMD3(Float(g.x),Float(g.y),Float(g.z)),rotationSpeed:Float(sqrt(r.x*r.x+r.y*r.y+r.z*r.z)),timestamp:motion.timestamp)
            guard (try? value.validated()) != nil else { return }
            self.lock.lock();let valid=self.active && self.token==epoch;if valid { self.latest=value };self.lock.unlock()
            let arrived=ProcessInfo.processInfo.systemUptime
            guard valid,arrived-lastUI>=0.1 else { return };lastUI=arrived
            DispatchQueue.main.async {
                self.lock.lock();let valid=self.active && self.token==epoch;self.lock.unlock()
                if valid { self.snapshot=value;self.message="Orientación relativa disponible." }
            }
        }
    }
    func read() -> SphereMotionSnapshot? {
        lock.lock();defer { lock.unlock() }
        guard active else { return nil };return latest
    }
    func stop() {
        lock.lock();active=false;token=UUID();latest=nil;lock.unlock()
        manager.stopDeviceMotionUpdates();snapshot=nil
    }
}
