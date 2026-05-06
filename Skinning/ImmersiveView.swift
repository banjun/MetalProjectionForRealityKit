import SwiftUI
import RealityKit
import ShaderGraphCoder
import MetalProjection

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    var metalMap: MetalMap {appModel.metalMap}

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
                defer {MetalMapSystem.registerSystem()}

                metalMap.isBloomEnabled = false
                metalMap.isMainLightsEnabled = false
                metalMap.isLineLights1Enabled = false
                metalMap.isLineLights1Enabled = false
                metalMap.isLineLights1Enabled = false

                let usdzEntity = try! await ModelEntity(named: "ありす4")
                usdzEntity.position = [-0.1, 1, -0.5]
                root.addChild(usdzEntity) // as reference
                root.addChild({
                    let llImporter = try! USDZLowLevelMeshImporter(usdz: usdzEntity)
                    let gestureOnlyEntity: Entity = try! llImporter.emptyModelEntity()
                    gestureOnlyEntity.transform.rotation = .init(angle: .pi, axis: [0, 1, 0])
                    gestureOnlyEntity.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
//                    gestureOnlyEntity.configureSimpleManipulationGestureComponent(collisionShapes: [.generateSphere(radius: 0.075).offsetBy(translation: [0, 0.075, 0])])


                    gestureOnlyEntity.position = usdzEntity.position
                    gestureOnlyEntity.position.x *= -1
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
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
