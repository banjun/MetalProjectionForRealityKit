import Foundation
import RealityKit

private extension simd_float4 {
    var xyz: simd_float3 {.init(x, y, z)}
}

struct PuppetIKSolverComponent: Component {
    var skeletonJoints: [MeshResource.Skeleton.Joint]
    // transform from: Joint[i] -> Parent Joint. initial value should be ModelEntity.jointTransforms
    var jointTransforms: [simd_float4x4]
    var copyJointTransforms: (([simd_float4x4]) -> Void)? // Joint -> Parent Joint
    var copySkinningMatrices: (([simd_float4x4]) -> Void)? // Model -> Model
    var maxIterations: Int = 30
    var globalFkWeight: Float = 0.2
}

struct PuppetIKSystem: System {
    static let query: EntityQuery = .init(where: .has(PuppetIKComponent.self) && .has(PuppetIKSolverComponent.self))
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        context.entities(matching: Self.query, updatingSystemWhen: .rendering).forEach { e in
            let puppet = e.components[PuppetIKComponent.self]!
            var solver = e.components[PuppetIKSolverComponent.self]!
            let skeletonJoints = solver.skeletonJoints
            let skeletonJointNames = skeletonJoints.map(\.name)
            defer {e.components.set(solver)}

            let relations: [String: (Transform?, [String])] = [
                "L_wrist": (puppet.L_wrist.map {e.convert(transform: $0, from: nil)}, [ "L_shoulder", "L_elbow"]),
                "R_wrist": (puppet.R_wrist.map {e.convert(transform: $0, from: nil)}, ["R_shoulder", "R_elbow"]),
            ]

            let relationIndices = relations.flatMap { key, value -> [(target: Transform, tipIndex: Int, movableIndices: Int)] in
                guard let target = value.0 else { return [] }
                guard let tipIndex = skeletonJointNames.firstIndex(of: key) else { return [] }
                let movables = value.1.compactMap {skeletonJointNames.firstIndex(of: $0)}
                return movables.map {(target, tipIndex, $0)}
            }

            guard solver.jointTransforms.count == skeletonJoints.count else { return }
            var joints = solver.jointTransforms
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
                        if let pi = skeletonJoints[i].parentIndex {
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
                    let dot = dot(v1, v2)
                    let weight = min(1.0, (1.0 - dot) * 5.0)
                    guard dot < 0.9999 else { continue }
                    guard simd_length_squared(v1) > 1e-10 && simd_length_squared(v2) > 1e-10 else { continue }
                    var rotation = simd_quatf(from: v1, to: v2)
                    rotation = simd_slerp(simd_quatf(real: 1, imag: .zero), rotation, weight)
                    maxRotationInIteration = max(maxRotationInIteration, abs(rotation.real - 1))

                    var next = rotation * simd_quatf(joints[movableIndex])
                    // limit angle
                    let angleLimit: Float = .pi / 3
                    if next.angle > angleLimit {
                        next = simd_quatf(angle: angleLimit, axis: rotation.axis)
                        // NSLog("%@", "\(skeletonJointNames[movableIndex]) rotation.angle = \(next.angle) (limited)")
                    }
                    // update iteration result
                    joints[movableIndex] = Transform(
                        rotation: next,
                        translation: joints[movableIndex].columns.3.xyz).matrix
                }
                if maxRotationInIteration < rotationThreshold {
                    break // early exit
                }
            }
            // blend using FK weight and apply to entity
            var jointTransforms = joints.enumerated().map { i, joint in
                var t = Transform(matrix: joint)
                t.rotation = simd_slerp(simd_quatf(real: 1, imag: .zero), t.rotation, 1 - globalFkWeight)
                return t
            }
            // inter-frame slerp
            Set(relationIndices.map(\.movableIndices)).forEach { i in
                let slerpFactor: Float = 0.2
                jointTransforms[i] = Transform(
                    rotation: simd_slerp(
                        Transform(matrix: solver.jointTransforms[i]).rotation,
                        jointTransforms[i].rotation,
                        slerpFactor),
                    translation: jointTransforms[i].translation)
            }
            // save result
            solver.jointTransforms = jointTransforms.map(\.matrix)
            // notify others
            solver.copyJointTransforms?(solver.jointTransforms)
            if let copySkinningMatrices = solver.copySkinningMatrices {
                // transform from: Joint[i] -> Model
                var solved = [simd_float4x4](repeating: Transform.identity.matrix, count: solver.jointTransforms.count)
                for i in 0..<jointTransforms.count {
                    if let pi = skeletonJoints[i].parentIndex {
                        solved[i] = solved[pi] * solver.jointTransforms[i]
                } else {
                        solved[i] = solver.jointTransforms[i]
                    }
                }
                let ibms = skeletonJoints.map(\.inverseBindPoseMatrix) // Model -> Joint[i]
                // Model_From_JointI_Transform * JointI_From_Model_Transform
                let skinningMatrices = zip(solved, ibms).map { $0 * $1 }
                copySkinningMatrices(skinningMatrices)
            }
        }
    }
}

