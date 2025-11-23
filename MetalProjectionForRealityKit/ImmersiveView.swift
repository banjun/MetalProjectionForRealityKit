import SwiftUI
import RealityKit
import ShaderGraphCoder

extension SGVector {
    static func screenUV(cameraTransform: SGMatrix, cameraTransformL: SGMatrix, cameraTransformR: SGMatrix, cameraProjection0: SGMatrix, cameraProjection1: SGMatrix) -> SGVector {
//    }
//    static func screenUV(cameraTransform: SGMatrix, cameraProjection0: SGMatrix, cameraProjection1: SGMatrix) -> SGVector {
        let posWorld = SGVector.position(space: .world)
        let posWorld4 = SGVector.vector4f(posWorld.x, posWorld.y, posWorld.z, .float(1))
        // proj = P * V * posWorld, V = CameraTransform^-1. use camera index to switch P for left/right eye
        let posCameraC = posWorld4.transformMatrix(mat: cameraTransform.invertMatrix())
        let posCameraL = posWorld4.transformMatrix(mat: cameraTransformL.invertMatrix())
        let posCameraR = posWorld4.transformMatrix(mat: cameraTransformR.invertMatrix())
        let posProjectionC = posCameraC.transformMatrix(mat: cameraProjection0)
        let posProjectionL = posCameraL.transformMatrix(mat: cameraProjection0)
        let posProjectionR = posCameraR.transformMatrix(mat: cameraProjection1)
        let posProjection = ShaderGraphCoder.geometrySwitchCameraIndex(mono: posProjectionC, left: posProjectionL, right: posProjectionR)
        // perspective division (/w) is needed to cancel perspective tiling. that's why the homogeneous vector posWorld4
//        let alpha = SGScalar.float(-0.09691928) // projection.columns.2.w
//        let beta = SGScalar.zero
//        let w_corrected = posProjection.w / (alpha * posCameraL.z + beta)
//
//        // 2. View-space 方向を取り出す
//        // w = 0 にして方向だけ考慮
//        let dirCamera4 = SGVector.vector4f(posCameraL.x, posCameraL.y, posCameraL.z, .float(0))
//
//        // 3. Clip-space に変換
//        let clip = dirCamera4.normalize().transformMatrix(mat: cameraProjection0)
//
//        // 4. NDC.xy を計算
//        // w = clip.w は方向ベースなので 1 でもよい（距離依存パース無視）
//        let ndc = clip.xy / clip.w

        let ndc = posProjection.xy / posProjection.w // .vector2f(1, -1)
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
    @State private var metalMap = MetalMap(width: 512, height: 512)

    var body: some View {
        RealityView { content in

            @MainActor func screenUV() -> SGVector {
                // decode CameraTransform & projection matrices from texture in 4x3 pixels. each row encodes 1 matrix.
                let uniforms = SGTexture.texture(metalMap.uniformsTextureResource)
                let cameraTransform = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 0))
                let cameraTransformL = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 1))
                let cameraTransformR = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 2))
                let cameraProjection0 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 3))
                let cameraProjection1 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 4))
                return .screenUV(cameraTransform: cameraTransform, cameraTransformL: cameraTransformL, cameraTransformR: cameraTransformR, cameraProjection0: cameraProjection0, cameraProjection1: cameraProjection1)
            }
            @MainActor func projectedMap(textureLeft left: SGTexture, textureRight right: SGTexture, uv: SGVector) -> SGVector {
                let image: (SGTexture) -> SGVector = {
//                    $0.sampleVector4f(texcoord: uv)
                    $0.image(defaultValue: .vector4fZero,
                             texcoord: uv,
                             uaddressmode: .periodic,
                             vaddressmode: .periodic,
                             filtertype: .linear)
                }
                return geometrySwitchCameraIndex(mono: image(left), left: image(left), right: image(right))
            }
            @MainActor func projectedMap() -> SGVector {
                projectedMap(
                    textureLeft: SGTexture.texture(metalMap.textureResource0),
                    textureRight: SGTexture.texture(metalMap.textureResource1),
                    uv: screenUV())
            }

            let texView = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                {
                    let tex = SGTexture.texture(metalMap.textureResource1)
                    let color: SGColor = tex.image(defaultValue: .transparentBlack,
                                                   uaddressmode: .clamp,
                                                   vaddressmode: .clamp,
                                                   filtertype: .closest)
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                }()
            ])
            texView.position = [0, 1.75, -1]
            content.add(texView)
            let texView2 = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                {
                    let tex = SGTexture.texture(metalMap.textureResource0)
                    let color: SGColor = tex.image(defaultValue: .transparentBlack,
                                                   uaddressmode: .clamp,
                                                   vaddressmode: .clamp,
                                                   filtertype: .closest)
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: SGTexture.texture(contentsOf: Bundle.main.url(forResource: "CustomUVChecker_byValle_1K", withExtension: "png")!).image(defaultValue: .black, texcoord: .vector2f(color.r, color.g))))
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                }()
            ])
            texView2.position = [0, 1.25, -1]
            content.add(texView2)

            let uniformsView = await ModelEntity(mesh: .generatePlane(width: 0.1, height: 0.1), materials: [
                {
                    let tex = SGTexture.texture(metalMap.uniformsTextureResource)
                    let uv: SGVector = .texcoordVector2()
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
                let uv = screenUV()
                return try! await ShaderGraphMaterial(surface: unlitSurface(
//                    color: .color3f(uv.x, uv.y, .float(0)),
                    color: SGTexture.texture(contentsOf: Bundle.main.url(forResource: "CustomUVChecker_byValle_1K", withExtension: "png")!).image(defaultValue: .black, texcoord: uv),
                    opacity: .float(1), applyPostProcessToneMap: false))

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

            let screenCube = await ModelEntity(mesh: .generateSphere(radius: 0.25 / 2), materials: [{
                let uv = screenUV()
                let image = SGTexture.texture(contentsOf: Bundle.main.url(forResource: "CustomUVChecker_byValle_1K", withExtension: "png")!)
                return try! await ShaderGraphMaterial(
                    surface: unlitSurface(
                        color: image.image(defaultValue: .black, texcoord: uv),
                        //                    color: .color3f(uv.x, uv.y, .float(0)),
                        applyPostProcessToneMap: false))
            }()])
            screenCube.position = [0, 1, -0.5]
            content.add(screenCube)
            screenCube.playAnimation(try! .makeActionAnimation(for: SpinAction(revolutions: 1), duration: 10, bindTarget: .transform, repeatMode: .repeat))

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
                let color: SGColor = image.image(defaultValue: .transparentBlack, texcoord: mapValue.xy, uaddressmode: .periodic, vaddressmode: .periodic, filtertype: .linear)
                let uvColor: SGColor = .color3f(mapValue.x, mapValue.y, .float(0))
                let shift = ShaderGraphCoder.geometrySwitchCameraIndex(mono: SGVector.position(space: .world), left: SGVector.position(space: .world), right: SGVector.position(space: .world)).x.subtract(.float(0.375)).range(inlow: .float(-0.00001), inhigh: .float(0.00001), gamma: .float(1), outlow: .float(0), outhigh: .float(1))

//                return try! await ShaderGraphMaterial(surface: unlitSurface(
//                    color: .color3f(shift, .float(0), .float(0)),
//                    applyPostProcessToneMap: false))

//                return try! await ShaderGraphMaterial(surface: unlitSurface(
//                    color: (color.a * mapValue.w).ifGreater(.float(0.05), trueResult: (uvColor + color.rgb) / 2, falseResult: .black),
//                    opacity: (color.a * mapValue.w).max(.float(0.15)),
//                    applyPostProcessToneMap: false,
//                ))
                return try! await ShaderGraphMaterial(surface: pbrSurface(
                    baseColor: color.rgb,
                    emissiveColor: .black,
                    normal: .vector3f(0, 0, 1),
                    roughness: .float(0.2),
                    metallic: .float(0),
                    specular: .float(0.5),
                    opacity: .float(1),//(color.a * mapValue.w).max(.float(0.1)),
                    clearcoat: .float(0)))
            }()])
            content.add(cube)

            let cube2 = cube.clone(recursive: true)
            cube2.position += [0.5, 0, 0.1]
            content.add(cube2)
            let cube3 = cube.clone(recursive: true)
            cube3.position += [1.0, 0, 0.2]
            content.add(cube3)

            content.add({
                let e = Entity()
                e.position = [0, 0.7, -0.5];
                e.components.set(ViewAttachmentComponent(rootView: VStack {
                    @Bindable var model = metalMap
                    Text("IPD = \(model.ipd, format: .number.precision(.fractionLength(3)))")
                    Slider(value: $metalMap.ipd, in: 0...0.1)
                    Text("zNear = \(model.near, format: .number.precision(.fractionLength(5)))")
                    Slider(value: $metalMap.near, in: 0...1)
                }))
                return e
            }())
        }
    }
}


