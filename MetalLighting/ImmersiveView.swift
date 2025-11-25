import SwiftUI
import RealityKit
import ShaderGraphCoder

struct ImmersiveView: View {
    @State private var metalMap = MetalMap(width: 1024, height: 1024)
    @GestureState private var dragStartTransform: Transform?

    var body: some View {
        RealityView { content in
            let progress = Entity()
            progress.components.set(ViewAttachmentComponent(rootView: VStack {
                ProgressView().padding().glassBackgroundEffect(in: .circle)
                Text("Loading USDZ into LowLevelMesh...").font(.extraLargeTitle)
            }))
            progress.position = [0, 1, -1]
            content.add(progress)

            let root = Entity()
            content.add(root)
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                defer {progress.removeFromParent()}

                await root.addChild({
                    let llImporter = try! await USDZLowLevelMeshImporter(usdz: ModelEntity(named: "ありす4"))
                    let usdzLLEntity = try! llImporter.modelEntity()
                    usdzLLEntity.position = [0, 1, -0.5]
                    usdzLLEntity.transform.rotation = .init(angle: .pi, axis: [0, 1, 0])
                    usdzLLEntity.components.set(MetalMapSystem.Component(map: metalMap))
                    // NOTE: adding ManipulationComponent will crash soon. why?
                    usdzLLEntity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.1)], isStatic: true))
                    usdzLLEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
                    usdzLLEntity.components.set(GestureComponent(DragGesture(coordinateSpace3D: .worldReference).targetedToEntity(usdzLLEntity).updating($dragStartTransform) { value, state, transaction in
                        state = state ?? value.entity.transform
                        var t = state!
                        t.translation += .init(value.translation3D)
                        if let pose = value.inputDevicePose3D, let startPose = value.startInputDevicePose3D {
                            t.rotation = simd_quatf(pose.rotation.rotated(by: startPose.rotation.inverse).inverse) * t.rotation
                        }
                        value.entity.transform = t
                    }))
                    metalMap.llMesh = llImporter.mesh
                    return usdzLLEntity
                }())
                defer {MetalMapSystem.registerSystem()}

                let viewCount = DeviceDependants.viewCount
                await root.addChild({
                    let width: Float = 1
                    let height = Float(viewCount) * (width / DeviceDependants.aspectRatio)
                    let texView = await ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [
                        {
                            let tex = SGTexture.texture(metalMap.textureResource)
                            let colors: [SGColor] = (0..<viewCount).map { vid in
                                tex.image2DArrayColor4(
                                    index: .int(vid),
                                    defaultValue: .transparentBlack,
                                    texcoord: (SGVector.texcoordVector2() - .vector2f(0, Float(vid) / Float(viewCount))) * .vector2f(1, Float(viewCount)),
                                    magFilter: .nearest,
                                    minFilter: .nearest,
                                    uWrapMode: .clampToZero,
                                    vWrapMode: .clampToZero,
                                    noFlipV: .int(1),
                                )
                            }
                            let color = colors.reduce(SGColor.transparentBlack, +)
                            return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                        }()
                    ])
                    texView.position = [0, 0.5 + height / 2, -1]
                    return texView
                }())
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
