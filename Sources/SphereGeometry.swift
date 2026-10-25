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
    private let transposed:Bool
    private let basis:simd_float3x3
    init(_ first:SphereMotionSnapshot) throws {
        _=try first.validated()
        guard first.gravity.y < -0.6,abs(first.gravity.z)<0.5 else { throw CameraFailure.message("Empieza con el teléfono vertical apuntando al horizonte.") }
        let g=simd_normalize(first.gravity),down=SIMD3<Float>(0,0,-1)
        let direct=simd_dot(first.rotation*g,down),inverse=simd_dot(first.rotation.transpose*g,down)
        guard max(direct,inverse)>0.95,abs(direct-inverse)>0.2 else { throw CameraFailure.message("No se pudo fijar la referencia vertical.") }
        transposed=inverse>direct
        let r=transposed ? first.rotation.transpose:first.rotation
        let raw=r*SIMD3<Float>(0,0,-1),up=SIMD3<Float>(0,0,1)
        let forward=simd_normalize(SIMD3<Float>(raw.x,raw.y,0)),right=simd_normalize(simd_cross(forward,up))
        basis=simd_float3x3(columns:(right,up,forward))
    }
    func pose(_ snapshot:SphereMotionSnapshot) throws -> SpherePose {
        _=try snapshot.validated()
        let r=transposed ? snapshot.rotation.transpose:snapshot.rotation
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
