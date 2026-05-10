import SwiftUI
import RealityKit
import ShaderGraphCoder
import MetalProjection
import RealityKitContent

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    var metalMap: MetalMap {appModel.metalMap}
    @State private var spatialTrackingSession: SpatialTrackingSession?
    let root: Entity = .init()
    let puppetRoot: Entity = .init()
    let palm: AnchorEntity = .init(.hand(.left, location: .palm), trackingMode: .predicted)

    var body: some View {
        RealityView { content in
            let progress = Entity()
            progress.components.set(ViewAttachmentComponent(rootView: VStack {
                ProgressView().padding().glassBackgroundEffect(in: .circle)
                Text("Loading USDZ into LowLevelMesh...").font(.extraLargeTitle)
            }))
            progress.position = [0, 1, -1]
            content.add(progress)

            content.add(root)

            Task {
                try? await Task.sleep(for: .milliseconds(200))
                defer {progress.removeFromParent()}
                defer {MetalMapSystem.registerSystem()}

                metalMap.debugBlit = .none
                metalMap.isBloomEnabled = false
                metalMap.isMainLightsEnabled = false
                metalMap.isLineLights1Enabled = false
                metalMap.isLineLights1Enabled = false
                metalMap.isLineLights1Enabled = false

                // MARK: - Load Entity, added naive joints to USDZ in RCP
                let skeletonEntity = try! await
                Entity(named: "ありす4-skeleton", in: realityKitContentBundle)
                skeletonEntity.configureSimpleManipulationGestureComponent(collisionShapes: [.generateSphere(radius: 0.075).offsetBy(translation: [0, 0.075, 0])])
                appModel.realityKitIKEntity.addChild(skeletonEntity)
                puppetRoot.addChild(appModel.realityKitIKEntity) // as reference

                // MARK: - Add Skeleton on the fly, calculating naive influences by distance
                let modelEntity = (skeletonEntity.findEntity(named: "Mesh") as! ModelEntity)
                let model = modelEntity.model!
                let jointsRoot = skeletonEntity.findEntity(named: "joints")!
                let hip = jointsRoot.findEntity(named: "hip")!
                let chest = jointsRoot.findEntity(named: "chest")!
                let neck = jointsRoot.findEntity(named: "neck")!
                let head = jointsRoot.findEntity(named: "head")!
                let L_cheek = jointsRoot.findEntity(named: "L_cheek")!
                let R_cheek = jointsRoot.findEntity(named: "R_cheek")!
                let L_clavicle = jointsRoot.findEntity(named: "L_clavicle")!
                let L_shoulder = jointsRoot.findEntity(named: "L_shoulder")!
                let L_elbow = jointsRoot.findEntity(named: "L_elbow")!
                let L_wrist = jointsRoot.findEntity(named: "L_wrist")!
                let R_clavicle = jointsRoot.findEntity(named: "R_clavicle")!
                let R_shoulder = jointsRoot.findEntity(named: "R_shoulder")!
                let R_elbow = jointsRoot.findEntity(named: "R_elbow")!
                let R_wrist = jointsRoot.findEntity(named: "R_wrist")!
                let L_hipbone = jointsRoot.findEntity(named: "L_hipbone")!
                let R_hipbone = jointsRoot.findEntity(named: "R_hipbone")!

                let skeletonID = "skeleton1"
                // order should match meshResourceContents.skeletons order
                let joints: [Entity] = [jointsRoot, hip, chest, neck, head, L_cheek, R_cheek, L_clavicle, L_shoulder, L_elbow, L_wrist, R_clavicle, R_shoulder, R_elbow, R_wrist, L_hipbone, R_hipbone]

                nonisolated(unsafe) var meshResourceContents = model.mesh.contents
                meshResourceContents.models = [{
                    var model = meshResourceContents.models[0]
                    var part = model.parts[0]
                    part.skeletonID = skeletonID
                    let jointPosisions = joints.map {$0.convert(position: .zero, to: jointsRoot)}.enumerated()
                    let influences: [Int] = part.positions.elements.map { p in
                        jointPosisions.min {distance_squared(p, $0.element) < distance_squared(p, $1.element)}!.offset
                    }
                    part.jointInfluences = .init(influences: MeshBuffers.JointInfluences(influences.map {.init(jointIndex: $0, weight: 1)}), influencesPerVertex: 1)
                    model.parts = [part]
                    return model
                }()]
                meshResourceContents.skeletons = [MeshResource.Skeleton(id: skeletonID, joints: [
                    .init(name: jointsRoot.name,
                          parentIndex: nil,
                          inverseBindPoseMatrix: jointsRoot.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: .identity),
                    .init(name: hip.name,
                          parentIndex: joints.firstIndex(of: jointsRoot)!,
                          inverseBindPoseMatrix: hip.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: hip.convert(transform: .identity, to: jointsRoot)),
                    .init(name: chest.name,
                          parentIndex: joints.firstIndex(of: hip)!,
                          inverseBindPoseMatrix: chest.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: chest.convert(transform: .identity, to: hip)),
                    .init(name: neck.name,
                          parentIndex: joints.firstIndex(of: chest)!,
                          inverseBindPoseMatrix: neck.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: neck.convert(transform: .identity, to: chest)),
                    .init(name: head.name,
                          parentIndex: joints.firstIndex(of: neck)!,
                          inverseBindPoseMatrix: head.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: head.convert(transform: .identity, to: neck)),
                    .init(name: L_cheek.name,
                          parentIndex: joints.firstIndex(of: head)!,
                          inverseBindPoseMatrix: L_cheek.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_cheek.convert(transform: .identity, to: head)),
                    .init(name: R_cheek.name,
                          parentIndex: joints.firstIndex(of: head)!,
                          inverseBindPoseMatrix: R_cheek.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_cheek.convert(transform: .identity, to: head)),
                    .init(name: L_clavicle.name,
                          parentIndex: joints.firstIndex(of: chest)!,
                          inverseBindPoseMatrix: L_clavicle.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_clavicle.convert(transform: .identity, to: chest)),
                    .init(name: L_shoulder.name,
                          parentIndex: joints.firstIndex(of: L_clavicle)!,
                          inverseBindPoseMatrix: L_shoulder.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_shoulder.convert(transform: .identity, to: L_clavicle)),
                    .init(name: L_elbow.name,
                          parentIndex: joints.firstIndex(of: L_shoulder)!,
                          inverseBindPoseMatrix: L_elbow.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_elbow.convert(transform: .identity, to: L_shoulder)),
                    .init(name: L_wrist.name,
                          parentIndex: joints.firstIndex(of: L_elbow)!,
                          inverseBindPoseMatrix: L_wrist.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_wrist.convert(transform: .identity, to: L_elbow)),
                    .init(name: R_clavicle.name,
                          parentIndex: joints.firstIndex(of: chest)!,
                          inverseBindPoseMatrix: R_clavicle.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_clavicle.convert(transform: .identity, to: chest)),
                    .init(name: R_shoulder.name,
                          parentIndex: joints.firstIndex(of: R_clavicle)!,
                          inverseBindPoseMatrix: R_shoulder.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_shoulder.convert(transform: .identity, to: R_clavicle)),
                    .init(name: R_elbow.name,
                          parentIndex: joints.firstIndex(of: R_shoulder)!,
                          inverseBindPoseMatrix: R_elbow.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_elbow.convert(transform: .identity, to: R_shoulder)),
                    .init(name: R_wrist.name,
                          parentIndex: joints.firstIndex(of: R_elbow)!,
                          inverseBindPoseMatrix: R_wrist.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_wrist.convert(transform: .identity, to: R_elbow)),
                    .init(name: L_hipbone.name,
                          parentIndex: joints.firstIndex(of: hip)!,
                          inverseBindPoseMatrix: L_hipbone.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: L_hipbone.convert(transform: .identity, to: hip)),
                    .init(name: R_hipbone.name,
                          parentIndex: joints.firstIndex(of: hip)!,
                          inverseBindPoseMatrix: R_hipbone.convert(transform: .identity, to: modelEntity).matrix.inverse,
                          restPoseTransform: R_hipbone.convert(transform: .identity, to: hip)),
                ])]

                let r = try await MeshResource(from: meshResourceContents)
                modelEntity.model!.mesh = r
                 NSLog("%@", "SkeletalPosesComponent = \(String(describing: modelEntity.components[SkeletalPosesComponent.self]))")

                // MARK: - Setup IK for the skeleton

                let skeleton = modelEntity.model!.mesh.contents.skeletons[0]
                var rig = try IKRig(for: skeleton)
                rig.maxIterations = 30
                rig.globalFkWeight = 0.1
                rig.constraints = [
                    .point(named: "L_wrist", on: "L_wrist",
                           positionWeight: .init(repeating: 1)),
                    .point(named: "R_wrist", on: "R_wrist",
                           positionWeight: .init(repeating: 1)),
                ]

                // fixed joint influences
                rig.joints["hip"]!.limits = .init(weight: 2)
                rig.joints["chest"]!.limits = .init(weight: 2)
                rig.joints["neck"]!.limits = .init(weight: 2)
                rig.joints["head"]!.limits = .init(weight: 2)
                rig.joints["L_clavicle"]!.limits = .init(weight: 100)
                rig.joints["R_clavicle"]!.limits = .init(weight: 100)
                rig.joints["L_cheek"]!.limits = .init(weight: 100)
                rig.joints["R_cheek"]!.limits = .init(weight: 100)
                rig.joints["L_hipbone"]!.limits = .init(weight: 5)
                rig.joints["R_hipbone"]!.limits = .init(weight: 5)

                let resource = try IKResource(rig: rig)
                modelEntity.components.set(IKComponent(resource: resource))
                modelEntity.components.set(PuppetIKComponent())

                // MARK: -

                puppetRoot.addChild(appModel.metalIKEntity)
                appModel.metalIKEntity.addChild({
                    let llImporter = try! USDZLowLevelMeshImporter(rootEntity: skeletonEntity)
                    let gestureOnlyEntity: ModelEntity = try! llImporter.emptyModelEntity()
                    gestureOnlyEntity.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    gestureOnlyEntity.configureSimpleManipulationGestureComponent(collisionShapes: [.generateSphere(radius: 0.075).offsetBy(translation: [0, 0.075, 0])])

                    gestureOnlyEntity.position = .zero //skeletonEntity.position
//                    gestureOnlyEntity.position.x *= -1

                    gestureOnlyEntity.components.set(PuppetIKComponent())
                    gestureOnlyEntity.components.set(PuppetIKSolverComponent(
                        skeletonJoints: skeleton.joints,
                        jointTransforms: modelEntity.jointTransforms.map(\.matrix),
//                        copyJointTransforms: { [weak modelEntity] in
//                            modelEntity?.jointTransforms = $0.map {Transform(matrix: $0)}
//                        },
                        copySkinningMatrices: { [weak gestureOnlyEntity] in
                            gestureOnlyEntity?.components[MetalMapSystem.Component.self]?.skinningMatrices = $0
                        },
                        maxIterations: 30,
                        globalFkWeight: 0.2,
                    ))

                    return gestureOnlyEntity
                }())

                @MainActor func screenUV() -> SGVector {
                    // decode CameraTransform & projection matrices from texture in 4x3 pixels. each row encodes 1 matrix.
                    let uniforms = SGTexture.texture(metalMap.uniformsTextureResource)
                    let cameraTransformL = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 0))
                    let cameraTransformR = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 1))
                    let cameraProjection0 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 2))
                    let cameraProjection1 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 3))
                    return .screenUV(cameraTransformL: cameraTransformL, cameraTransformR: cameraTransformR, cameraProjection0: cameraProjection0, cameraProjection1: cameraProjection1)
                }
                @MainActor func projectedMap(textureArray: SGTexture, uv: SGVector) -> SGColor {
                    let image: (Int) -> SGColor = {
                        textureArray.image2DArrayColor4(index: .int($0), defaultValue: .transparentBlack, texcoord: uv, magFilter: .linear, minFilter: .linear, uWrapMode: .clampToEdge, vWrapMode: .clampToEdge, noFlipV: .int(1))
                    }
                    return geometrySwitchCameraIndex(mono: image(0), left: image(0), right: image(1))
                }
                @MainActor func projectedMap(screenToPhysicalLUT lut: SGTexture?) -> SGColor {
                    projectedMap(textureArray: .texture(metalMap.textureResource),
                                 uv: lut.map {.physicalUV(screenUV: screenUV(), lut: $0)} ?? screenUV())
                }

                @MainActor func screenMaterial(screenToPhysicalLUT lut: SGTexture? = nil) async -> ShaderGraphMaterial {
                    let mapValue = projectedMap(screenToPhysicalLUT: lut)
                    //                    var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: .zero, applyPostProcessToneMap: false, hasPremultipliedAlpha: true))
                    var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: mapValue.a, applyPostProcessToneMap: false, hasPremultipliedAlpha: false))
                    m.faceCulling = .front
                    return m
                }
                @MainActor func screenSphere(radius: Float) async -> Entity {
                    let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [await screenMaterial(screenToPhysicalLUT: metalMap.rateMapDecodeTextureResource.map {.texture($0)})])
                    return sphere
                }
                await root.addChild(screenSphere(radius: 10000))
            }
        }
        .task {
            spatialTrackingSession = SpatialTrackingSession()
            let unavailabilities = await spatialTrackingSession?.run(.init(tracking: [.hand]))
            if unavailabilities?.anchor.contains(.hand) != true {
                puppetRoot.transform = .init(rotation: .init(angle: .pi / 2, axis: [0, 1, 0]) * .init(angle: .pi / 2, axis: [1, 0, 0]), translation: [-0.03, 0.05, 0.01])
                root.addChild(palm)
                palm.addChild(puppetRoot)

                root.addChild(AnchorEntity(.hand(.left, location: .joint(for: .littleFingerTip)), trackingMode: .predicted))
                root.addChild(AnchorEntity(.hand(.left, location: .joint(for: .thumbTip)), trackingMode: .predicted))
                PuppetHandTrackingSystem.registerSystem()
            } else {
                // Simulator
                puppetRoot.position = [0, 1, -0.5]
                root.addChild(puppetRoot)

                // MARK: - Add Fixed IK targets for test
                try? await Task.sleep(for: .seconds(1))
                let metalEntity = appModel.metalIKEntity.children.first!
                metalEntity.transform.rotation = .init(angle: .pi, axis: [0, 1, 0])
                metalEntity.components.set(PuppetIKComponent(
                    L_wrist: .init(translation: [
                        puppetRoot.position.x + metalEntity.position.x + 0.05,
                        puppetRoot.position.y + metalEntity.position.y + 0.02,
                        puppetRoot.position.z + metalEntity.position.z + 0.01]),
                    R_wrist: .init(translation: [
                        puppetRoot.position.x + metalEntity.position.x - 0.05,
                        puppetRoot.position.y + metalEntity.position.y + 0.09,
                        puppetRoot.position.z + metalEntity.position.z + 0.01]),
                ))

                appModel.realityKitIKEntity.position.x = -0.3
                let modelEntity = (appModel.realityKitIKEntity.findEntity(named: "Mesh") as! ModelEntity)
                modelEntity.components.set(PuppetIKComponent(
                    L_wrist: .init(translation: [
                        appModel.realityKitIKEntity.position.x + 0.05,
                        puppetRoot.position.y + 0.02,
                        puppetRoot.position.z + 0.01]),
                    R_wrist: .init(translation: [
                        appModel.realityKitIKEntity.position.x - 0.05,
                        puppetRoot.position.y + 0.09,
                        puppetRoot.position.z + 0.01]),
                ))
            }
            PuppetIKSystem.registerSystem()
            PuppetRealityKitIKSystem.registerSystem()
        }
        .persistentSystemOverlays(.hidden)
        .upperLimbVisibility(appModel.upperLimbVisibility ? .visible : .hidden)
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}

