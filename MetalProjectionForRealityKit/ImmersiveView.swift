import SwiftUI
import RealityKit
import ShaderGraphCoder

extension SGVector {
    static func screenUV(cameraTransform: SGMatrix, cameraProjection0: SGMatrix, cameraProjection1: SGMatrix) -> SGVector {
        let posWorld = SGVector.position(space: .world)
        let posWorld4 = SGVector.vector4f(posWorld.x, posWorld.y, posWorld.z, .float(1))
        // proj = P * V * posWorld, V = CameraTransform^-1. use camera index to switch P for left/right eye
        let posCamera = posWorld4.transformMatrix(mat: cameraTransform.invertMatrix())
        let posProjection0 = posCamera.transformMatrix(mat: cameraProjection0)
        let posProjection1 = posCamera.transformMatrix(mat: cameraProjection1)
        let posProjection = ShaderGraphCoder.geometrySwitchCameraIndex(mono: posProjection0, left: posProjection1, right: posProjection0)
        // perspective division (/w) is needed to cancel perspective tiling. that's why the homogeneous vector posWorld4
        let ndc = posProjection.xy / posProjection.w
        let uv = (ndc + 1) / 2
        return uv // .fract()
    }
}
extension SGMatrix {
    static func decodeTexturePixel(texture: SGTexture, offset: SGVector, stride: SGVector = .vector2f(1, 0)) -> SGMatrix {
        .matrix4d(
            texture.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: offset + stride * 0),
            texture.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: offset + stride * 1),
            texture.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: offset + stride * 2),
            texture.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: offset + stride * 3),
        )
    }
}

struct ImmersiveView: View {
    @State private var metalMap = MetalMap(width: 1024, height: 1024)

    var body: some View {
        RealityView { content in
            let texView = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                {
                    let tex = SGTexture.texture(metalMap.textureResource0)
                    let color: SGColor = tex.image(defaultValue: .transparentBlack,
                                                   uaddressmode: .clamp,
                                                   vaddressmode: .clamp,
                                                   filtertype: .closest)
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                }()
            ])
            texView.position = [0, 1.5, -1]
            content.add(texView)

            let uniformsView = await ModelEntity(mesh: .generatePlane(width: 0.1, height: 0.1), materials: [
                {
                    let tex = SGTexture.texture(metalMap.uniformsTextureResource)
                    let uv: SGVector = .vector2f(.texcoordVector2().y, .texcoordVector2().x) // transpose for visualize
                    let color: SGVector = tex.image(defaultValue: .vector4fZero,
                                                    texcoord: uv,
                                                    uaddressmode: .clamp,
                                                    vaddressmode: .clamp,
                                                    filtertype: .closest)
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: .init(color.xyz + 1), opacity: color.w + .float(0.5)))
                }()
            ])
            uniformsView.position = [-0.4, 1.5, -1]
            content.add(uniformsView)

            @MainActor func screenUV() -> SGVector {
                // decode CameraTransform & projection matrices from texture in 4x3 pixels. each row encodes 1 matrix.
                let uniforms = SGTexture.texture(metalMap.uniformsTextureResource)
                let cameraTransform = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 0))
                let cameraProjection0 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 1))
                let cameraProjection1 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 2))
                return .screenUV(cameraTransform: cameraTransform, cameraProjection0: cameraProjection0, cameraProjection1: cameraProjection1)
            }
            @MainActor func projectedMap(textureLeft left: SGTexture, textureRight right: SGTexture, uv: SGVector) -> SGVector {
                let image: (SGTexture) -> SGVector = {
                    $0.image(defaultValue: .vector4fZero,
                             texcoord: uv,
                             uaddressmode: .constant,
                             vaddressmode: .constant,
                             filtertype: .linear)
                }
                return geometrySwitchCameraIndex(mono: image(left), left: image(left), right: image(right))
            }
            @MainActor func projectedMap() -> SGVector {
                projectedMap(textureLeft: SGTexture.texture(metalMap.textureResource1), textureRight: SGTexture.texture(metalMap.textureResource0), uv: screenUV())
            }

            let screenMaterial: ShaderGraphMaterial = await {
                //                let uv = screenUV()
                //                let color: SGColor = .init(.vector3f(uv.x, uv.y, .float(0)))
                //                return try! await ShaderGraphMaterial(surface: unlitSurface(color: color, opacity: .float(1), applyPostProcessToneMap: false))
                let mapValue = SGColor(projectedMap())
                return try! await ShaderGraphMaterial(surface: unlitSurface(color: mapValue.rgb, opacity: mapValue.a, applyPostProcessToneMap: false))
            }()
            let screen = ModelEntity(mesh: .generatePlane(width: 20, height: 10), materials: [screenMaterial])
            screen.position = [0, 1.5, -0.75]
            //            let head = AnchorEntity(.head) // anchoring to AnchorEntity causes projection error?
            //            head.addChild(screen)
            //            content.add(head)
            content.add(screen)

            let screen2 = screen.clone(recursive: true)
            screen2.position = [0, 1.5, +0.75]
            screen2.transform.rotation = .init(angle: .pi, axis: [0,1,0])
            content.add(screen2)

            let screen3 = screen.clone(recursive: true)
            screen3.position = [5, 1.5, 0]
            screen3.transform.rotation = .init(angle: -.pi / 2, axis: [0,1,0])
            content.add(screen3)

            let screen4 = screen.clone(recursive: true)
            screen4.position = [-5, 1.5, 0]
            screen4.transform.rotation = .init(angle: .pi / 2, axis: [0,1,0])
            content.add(screen4)

            [screen, screen2, screen3, screen4].forEach {$0.isEnabled = false}

            let metalMapSystemEnabler = Entity()
            metalMapSystemEnabler.components.set(MetalMapSystem.Component(map: metalMap))
            content.add(metalMapSystemEnabler)
            MetalMapSystem.registerSystem()

            let cube = await ModelEntity(mesh: metalMap.meshResource, materials: [{
                let mapValue = projectedMap()
//                let color = SGColor(.vector3f(0.5, 0, 0) + 0.8 * mapValue.xyz)
//                let color = SGColor(mapValue.xyz)
//                let image = SGTexture.texture(contentsOf: Bundle.main.url(forResource: "CustomUVChecker_byValle_1K", withExtension: "png")!)
                let image = SGTexture.texture(contentsOf: Bundle.main.url(forResource: "arisu-checker", withExtension: "png")!)
                let color: SGColor = image.image(defaultValue: .transparentBlack, texcoord: mapValue.xy, uaddressmode: .constant, vaddressmode: .constant, filtertype: .linear)
                return try! await ShaderGraphMaterial(surface: unlitSurface(
                    color: (color.a * mapValue.w).ifGreater(.float(0.05), trueResult: color.rgb, falseResult: .black),
                    opacity: (color.a * mapValue.w).max(.float(0.05)),
                    applyPostProcessToneMap: false,
                ))
                return try! await ShaderGraphMaterial(surface: pbrSurface(
                    baseColor: color.rgb,
                    emissiveColor: .black,
                    normal: .vector3f(0, 0, 1),
                    roughness: .float(0.2),
                    metallic: .float(0),
                    specular: .float(0.5),
                    opacity: (color.a * mapValue.w).max(.float(0.1)),
                    clearcoat: .float(0)))
            }()])
            content.add(cube)
        }
    }
}


