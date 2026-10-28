import Foundation
import simd

struct SphereMotionSnapshot {
    let rotation:simd_float3x3
    let gravity:SIMD3<Float>
    let rotationSpeed:Float
    let timestamp:Double
    func validated() throws -> Self {
        let numbers=[rotation.columns.0,rotation.columns.1,rotation.columns.2,gravity]
        guard numbers.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),timestamp.isFinite,
              rotationSpeed.isFinite,rotationSpeed>=0,(0.8...1.2).contains(simd_length(gravity)),
              abs(simd_determinant(rotation)-1)<0.05 else { throw CameraFailure.message("Datos de orientación no válidos.") }
        let identity=rotation.transpose*rotation
        guard simd_length(identity.columns.0-SIMD3(1,0,0))<0.05,
              simd_length(identity.columns.1-SIMD3(0,1,0))<0.05,
              simd_length(identity.columns.2-SIMD3(0,0,1))<0.05 else { throw CameraFailure.message("La orientación no es una rotación rígida.") }
        return self
    }
}
struct SpherePose {
    let sphereToDevice:simd_float3x3
    let forward:SIMD3<Float>
}
struct SphereReference {
    private final class Convention {
        let lock=NSLock()
        var transposed:Bool?
    }
    private let convention=Convention()
    private let basis:simd_float3x3
    init(_ first:SphereMotionSnapshot) throws {
        _=try first.validated()
        guard first.gravity.y < -0.25,abs(first.gravity.z)<0.92 else { throw CameraFailure.message("Sujeta el teléfono en vertical, sin apuntar completamente al suelo o al techo al empezar.") }
        let r=try Self.deviceToWorld(first,convention:convention)
        let raw=r*SIMD3<Float>(0,0,-1),up=SIMD3<Float>(0,0,1)
        let forward=simd_normalize(SIMD3<Float>(raw.x,raw.y,0)),right=simd_normalize(simd_cross(forward,up))
        basis=simd_float3x3(columns:(right,up,forward))
    }
    private static func deviceToWorld(_ sample:SphereMotionSnapshot,convention:Convention) throws -> simd_float3x3 {
        let gravity=simd_normalize(sample.gravity),down=SIMD3<Float>(0,0,-1)
        let direct=simd_dot(sample.rotation*gravity,down),inverse=simd_dot(sample.rotation.transpose*gravity,down)
        guard max(direct,inverse)>0.95 else { throw CameraFailure.message("La orientación aún no está calibrada. Mantén el teléfono quieto.") }
        // At 180° the two matrices can be identical. Rejecting an ambiguous
        // transpose at that instant used to reject a perfectly valid reference.
        convention.lock.lock();defer { convention.lock.unlock() }
        if convention.transposed==nil && abs(direct-inverse)>0.001 { convention.transposed=inverse>direct }
        let transposed=convention.transposed ?? (inverse>direct)
        guard (transposed ? inverse:direct)>0.9 else { throw CameraFailure.message("La referencia de orientación se interrumpió. Reinicia la esfera.") }
        return transposed ? sample.rotation.transpose:sample.rotation
    }
    func pose(_ snapshot:SphereMotionSnapshot) throws -> SpherePose {
        _=try snapshot.validated()
        let r=try Self.deviceToWorld(snapshot,convention:convention)
        let worldForward=simd_mul(r,SIMD3<Float>(0,0,-1))
        let sphereForward=simd_mul(basis.transpose,worldForward)
        return SpherePose(sphereToDevice:simd_mul(r.transpose,basis),forward:simd_normalize(sphereForward))
    }
}
struct SphereTarget:Identifiable {
    let id:Int
    let yaw:Float
    let pitch:Float
    var direction:SIMD3<Float> {
        let y=yaw*Float.pi/180,p=pitch*Float.pi/180
        return SIMD3(sin(y)*cos(p),sin(p),cos(y)*cos(p))
    }
    static let all:[SphereTarget] = {
        var values=[SphereTarget]()
        for pitch in [Float]([0,30,-30,60,-60]) { for yaw in stride(from:0,to:360,by:30) { values.append(Self(id:values.count,yaw:Float(yaw),pitch:pitch)) } }
        values.append(Self(id:values.count,yaw:0,pitch:90));values.append(Self(id:values.count,yaw:0,pitch:-90))
        return values
    }()
    func angle(to direction:SIMD3<Float>) -> Float { acos(min(1,max(-1,simd_dot(self.direction,simd_normalize(direction)))))*180/Float.pi }
}

struct SphereAim {
    let reference:SphereReference,target:SphereTarget
    static func make(_ sample:SphereMotionSnapshot,reference:SphereReference?,captured:Set<Int>,now:Double?=nil) throws -> Self {
        _=try sample.validated()
        if let now { guard now>=sample.timestamp,now-sample.timestamp<0.5 else { throw CameraFailure.message("La orientación no está actualizada. Reintenta los sensores.") } }
        guard sample.rotationSpeed<0.5 else { throw CameraFailure.message("Mantén el teléfono quieto un instante y vuelve a pulsar.") }
        let candidate=try reference ?? SphereReference(sample),direction=try candidate.pose(sample).forward
        guard let target=SphereTarget.all.filter({!captured.contains($0.id)}).min(by:{$0.angle(to:direction)<$1.angle(to:direction)}) else { throw CameraFailure.message("Ya están completas las vistas de la esfera.") }
        let tolerance:Float=reference == nil ? 15.5:12
        guard target.angle(to:direction)<=tolerance else { throw CameraFailure.message("Gira hacia el siguiente objetivo antes de añadir otra vista.") }
        return Self(reference:candidate,target:target)
    }
    static func acceptsMotion(_ sample:SphereMotionSnapshot,seconds:Double,fieldOfView:Double)->Bool {
        guard seconds.isFinite,seconds>0,fieldOfView.isFinite,(30...130).contains(fieldOfView) else { return false }
        let blur=Double(sample.rotationSpeed)*180/Double.pi*seconds*1600/fieldOfView
        return sample.rotationSpeed<0.6 && blur<=3
    }
}
