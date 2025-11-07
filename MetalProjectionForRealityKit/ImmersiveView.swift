import SwiftUI
import RealityKit
import ShaderGraphCoder

struct ImmersiveView: View {
    @State private var metalMap = MetalMap(width: 256, height: 256)

    var body: some View {
        RealityView { content in
            let texView = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                {
                    let tex = SGTexture.texture(metalMap.textureResource)
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

            let screenMaterial: ShaderGraphMaterial = await {
                // decode CameraTransform & projection matrices from texture in 4x3 pixels. each row encodes 1 matrix.
                let uniforms = SGTexture.texture(metalMap.uniformsTextureResource)
                let cameraTransform = SGMatrix.matrix4d(
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(0, 0)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(1, 0)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(2, 0)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(3, 0)))
                let cameraProjection0 = SGMatrix.matrix4d(
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(0, 1)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(1, 1)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(2, 1)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(3, 1)))
                let cameraProjection1 = SGMatrix.matrix4d(
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(0, 2)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(1, 2)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(2, 2)),
                    uniforms.pixel(filter: .nearest, defaultValue: .vector4fZero, texcoord: .vector2f(3, 2)))
                let posWorld = SGVector.position(space: .world)
                let posWorld4 = SGVector.vector4f(posWorld.x, posWorld.y, posWorld.z, .float(1))
                // proj = P * V * posWorld, V = CameraTransform^-1. use camera index to switch P for left/right eye
                let posCamera = posWorld4.transformMatrix(mat: cameraTransform.invertMatrix())
                let posProjection0 = posCamera.transformMatrix(mat: cameraProjection0)
                let posProjection1 = posCamera.transformMatrix(mat: cameraProjection1)
                let posProjection = geometrySwitchCameraIndex(mono: posProjection0, left: posProjection1, right: posProjection0)
                // perspective division (/w) is needed to cancel perspective tiling. that's why the homogeneous vector posWorld4
                let ndc = ((posProjection.xy / posProjection.w) + 0.5)//.fract()
                let color: SGColor = .init(.vector3f(ndc.x, ndc.y, .float(0)))

                let tex = SGTexture.texture(metalMap.textureResource)
                let mapValue: SGColor = tex.image(defaultValue: .transparentBlack, texcoord: (ndc + 0.5) * 0.5)

//                return try! await ShaderGraphMaterial(surface: unlitSurface(color: color, opacity: .float(1), applyPostProcessToneMap: false))
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

            let metalMapSystemEnabler = Entity()
            metalMapSystemEnabler.components.set(MetalMapSystem.Component(map: metalMap))
            content.add(metalMapSystemEnabler)
            MetalMapSystem.registerSystem()

            let cube = ModelEntity(mesh: metalMap.meshResource, materials: [UnlitMaterial(color: .blue)])
            content.add(cube)
        }
    }
}


