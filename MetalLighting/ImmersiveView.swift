import SwiftUI
import RealityKit
import ShaderGraphCoder
import MetalProjection
import RealityKitContent
import UIKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    var metalMap: MetalMap {appModel.metalMap}
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
                    let gestureOnlyEntity: Entity = try! llImporter.emptyModelEntity()
                    gestureOnlyEntity.transform.rotation = .init(angle: .pi, axis: [0, 1, 0])
                    gestureOnlyEntity.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    gestureOnlyEntity.configureSimpleManipulationGestureComponent(collisionShapes: [.generateSphere(radius: 0.075).offsetBy(translation: [0, 0.075, 0])])
                    gestureOnlyEntity.position = [0, 1, -0.5]
                    return gestureOnlyEntity
                }())
                await root.addChild({
                    let usdzEntity = try! await ModelEntity(named: "花海咲季2-blender-ツノ消し-rcp-restore-ao")
                    let llImporter = try! USDZLowLevelMeshImporter(usdz: usdzEntity)
                    let gestureOnlyEntity: Entity = try! llImporter.emptyModelEntity()
                    gestureOnlyEntity.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    gestureOnlyEntity.configureSimpleManipulationGestureComponent(collisionShapes: [.generateSphere(radius: 0.075).offsetBy(translation: [0, 0.075, 0])])
                    gestureOnlyEntity.position = [-0.5, 1, -0.5]
                    return gestureOnlyEntity
                }())
                await root.addChild({
                    let llImporter = try! await USDZLowLevelMeshImporter(entityNamed: "GridSphere", in: realityKitContentBundle)
                    let empty = try! llImporter.emptyModelEntity()
                    empty.position = [0, 1, -0.5]
                    empty.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    return empty // metal only
                }())
                await root.addChild({
                    let llImporter = try! await USDZLowLevelMeshImporter(entityNamed: "Floor", in: realityKitContentBundle)
                    let empty = try! llImporter.emptyModelEntity()
                    empty.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    return empty // metal only
                }())
                await root.addChild({
                    let llImporter = try! await USDZLowLevelMeshImporter(entityNamed: "CenterStage", in: realityKitContentBundle)
                    let empty = try! llImporter.emptyModelEntity()
                    empty.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    return empty // metal only
                }())
                await root.addChild({
                    let llImporter = try! await USDZLowLevelMeshImporter(entityNamed: "Pillars", in: realityKitContentBundle)
                    let empty = try! llImporter.emptyModelEntity()
                    empty.components.set(MetalMapSystem.Component(map: metalMap, llMesh: llImporter.mesh))
                    return empty // metal only
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

                @MainActor func screenMaterial() async -> ShaderGraphMaterial {
                    let mapValue = projectedMap()
                    //                    var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: .zero, applyPostProcessToneMap: false, hasPremultipliedAlpha: true))
                    var m = try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: mapValue.a, applyPostProcessToneMap: false, hasPremultipliedAlpha: false))
                    m.faceCulling = .front
                    return m
                }
                @MainActor func screenSphere(radius: Float) async -> Entity {
                    let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [await screenMaterial()])
                    // model sort group could be used to invert depth order?
                    sphere.components.set(ModelSortGroupComponent(group: modelSortGroup, order: 999))
                    return sphere
                }
                await root.addChild(screenSphere(radius: 10000))

                let ibl = try! await TextureResource(cubeFromEquirectangular: UIImage(named: "studio_kominka_02_4k-polyhaven-cc0-scaled512.exr")!.cgImage!, options: .init(semantic: .hdrColor))
                try! metalMap.setImageBasedLightTexture(ibl)
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
