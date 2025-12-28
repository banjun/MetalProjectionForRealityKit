import SwiftUI
import RealityKit
import ShaderGraphCoder
import MetalProjection

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    var metalMap: MetalMap {appModel.metalMap}
    @GestureState private var dragStartTransform: Transform?
    private let modelSortGroup = ModelSortGroup(depthPass: .postPass)

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
                    let usdzEntity = try! await ModelEntity(named: "ありす4")
                    let llImporter = try! USDZLowLevelMeshImporter(usdz: usdzEntity)
//                    let usdzLLEntity = try! llImporter.modelEntity()
                    let usdzLLEntity = usdzEntity // NOTE: LowLevelMesh entity cannot be compatible with ModelSortGroup ???
                    usdzLLEntity.position = [0, 1, -0.5]
                    usdzLLEntity.transform.rotation = .init(angle: .pi, axis: [0, 1, 0])
                    usdzLLEntity.components.set(MetalMapSystem.Component(map: metalMap))
                    // NOTE: adding ManipulationComponent will crash soon. why?
                    usdzLLEntity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.1)], isStatic: true))
                    usdzLLEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
                    usdzLLEntity.components.set(GestureComponent(DragGesture(coordinateSpace: .immersiveSpace).targetedToEntity(usdzLLEntity).updating($dragStartTransform) { value, state, transaction in
                        state = state ?? value.entity.transform
                        var t = state!
                        let location = value.convert(value.location3D, from: .global, to: .scene)
                        let startLocation = value.convert(value.startLocation3D, from: .global, to: .scene)
                        let translation = location - startLocation
                        if let pose = value.inputDevicePose3D, let startPose = value.startInputDevicePose3D {
                            t.rotation = simd_quatf(pose.rotation.rotated(by: startPose.rotation.inverse)) * t.rotation
                        }
                        t.translation += .init(translation)
                        value.entity.transform = t
                    }))
                    metalMap.llMesh = llImporter.mesh
                    usdzLLEntity.components.set(ModelSortGroupComponent(group: modelSortGroup, order: 1))
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
                            var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                            m.faceCulling = .none
                            return m
                        }()
                    ])
                    texView.position = [0, 0.5 + height / 2, -1]
                    texView.isEnabled = false
                    return texView
                }())

                await root.addChild({
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
                    @MainActor func projectedMap() -> SGColor {
                        projectedMap(textureArray: .texture(metalMap.textureResource), uv: screenUV())
                    }

                    let screenMaterial: ShaderGraphMaterial = await {
                        let mapValue = projectedMap()
                        var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: .zero, applyPostProcessToneMap: false, hasPremultipliedAlpha: true))
                        m.faceCulling = .front
                        return m
                    }()
                    let sphere = ModelEntity(mesh: .generateSphere(radius: 10000), materials: [screenMaterial])
                    // model sort group could be used to invert depth order?
                    sphere.components.set(ModelSortGroupComponent(group: modelSortGroup, order: 999))
                    return sphere
                }())
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
