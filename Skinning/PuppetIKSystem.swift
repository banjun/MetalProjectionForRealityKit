import RealityKit

struct PuppetIKComponent: Component {
    var L_wrist: Transform?
    var R_wrist: Transform?
}

struct CyclicCoordinateDescentComponent {
    var skeleton: SkeletalPose?
}

private extension simd_float4 {
    var xyz: simd_float3 {.init(x, y, z)}
}

struct PuppetIKSystem: System {
    static let query: EntityQuery = .init(where: .has(PuppetIKComponent.self) && .has(IKComponent.self))
    init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        context.entities(matching: Self.query, updatingSystemWhen: .rendering).forEach { e in
            guard case let e as ModelEntity = e, let model = e.model else { return }
            let ik = e.components[IKComponent.self]!
            let puppet = e.components[PuppetIKComponent.self]!
            guard let solver = ik.solvers.first else { return }

            // Custom IK joints definition, redefine just like IKRig
            let relations: [String: (Transform?, [String])] = [
                "L_wrist": (puppet.L_wrist.map {e.convert(transform: $0, from: nil)}, ["L_elbow", "L_shoulder"]),
                "R_wrist": (puppet.R_wrist.map {e.convert(transform: $0, from: nil)}, ["R_elbow", "R_shoulder"]),
            ]
            let relationIndices = relations.flatMap { key, value -> [(target: Transform, tipIndex: Int, movableIndices: Int)] in
                guard let target = value.0 else { return [] }
                guard let tipIndex = e.jointNames.firstIndex(of: key) else { return [] }
                let movables = value.1.compactMap {e.jointNames.firstIndex(of: $0)}
                return movables.map {(target, tipIndex, $0)}
            }
            // transform from: Joint[i] -> Parent Joint
            var joints = e.jointTransforms.map(\.matrix)
            let skeleton = model.mesh.contents.skeletons[0]
            let maxIterations = solver.maxIterations
            let globalFkWeight: Float = solver.globalFkWeight
            let rotationThreshold: Float = 0.0001
            // Custom IK by Cyclic Coordinate Descent
            for _ in 0..<maxIterations {
                var maxRotationInIteration: Float = 0
                for (target, tipIndex, movableIndex) in relationIndices {
                    // transform from: Joint[i] -> Model
                    // convert in 1 loop assuming joints are topologically sorted, that is, for all index, parent index < child index
                    var jointTransformsInModel = [simd_float4x4](repeating: Transform.identity.matrix, count: joints.count)
                    for i in 0..<joints.count {
                        if let pi = skeleton.joints[i].parentIndex {
                            jointTransformsInModel[i] = jointTransformsInModel[pi] * joints[i]
                        } else {
                            jointTransformsInModel[i] = joints[i]
                        }
                    }

                    // (joint at index) --> ... --> (tip)
                    // (origin) ------------------------------> (target)
                    let joint = jointTransformsInModel[movableIndex]
                    let jointPos = joint.columns.3.xyz
                    let tipPos = jointTransformsInModel[tipIndex].columns.3.xyz
                    let targetPos = target.matrix.columns.3.xyz

                    // rotate (tip) -> (target)
                    let v1 = normalize(tipPos - jointPos)
                    let v2 = normalize(targetPos - jointPos)
                    guard simd_length_squared(v1) > 1e-10 && simd_length_squared(v2) > 1e-10 else { continue }
                    let rotation = simd_quatf(from: v1, to: v2)
                    maxRotationInIteration = max(maxRotationInIteration, abs(rotation.real - 1))

                    // update iteration result
                    joints[movableIndex] = Transform(
                        rotation: rotation * simd_quatf(joints[movableIndex]),
                        translation: joints[movableIndex].columns.3.xyz).matrix
                }
                if maxRotationInIteration < rotationThreshold {
                    break // early exit
                }
            }
            // blend using FK weight and apply to entity
            for i in 0..<joints.count {
                var t = Transform(matrix: joints[i])
                t.rotation = simd_slerp(simd_quatf(real: 1, imag: .zero), t.rotation, 1 - globalFkWeight)
                e.jointTransforms[i] = t
            }

            // RealityKit IK
            if let c = solver.constraints["L_wrist"], let t = puppet.L_wrist {
                c.target = e.convert(transform: t, from: nil)
                c.animationOverrideWeight = (1, 1)
            }
            if let c = solver.constraints["R_wrist"], let t = puppet.R_wrist {
                c.target = e.convert(transform: t, from: nil)
                c.animationOverrideWeight = (1, 1)
            }
            e.components.set(ik)
        }
    }
}
