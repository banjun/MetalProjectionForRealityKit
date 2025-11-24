import SwiftUI
import RealityKit
import ShaderGraphCoder

extension SGVector {
    static func screenUV(cameraTransformL: SGMatrix, cameraTransformR: SGMatrix, cameraProjection0: SGMatrix, cameraProjection1: SGMatrix) -> SGVector {
        let viewDirection = SGVector.viewDirection(space: .world)
        let viewDirection4 = SGVector.vector4f(viewDirection.x, viewDirection.y, viewDirection.z, .float(0))

        let viewDirectionInViewBackL = viewDirection4.transformMatrix(mat: cameraTransformL.invertMatrix()).xyz
        let viewDirectionInViewBackR = viewDirection4.transformMatrix(mat: cameraTransformR.invertMatrix()).xyz

        let z_proj = SGScalar.float(-1.0)
        let pViewL = viewDirectionInViewBackL * (z_proj / viewDirectionInViewBackL.z)
        let pViewR = viewDirectionInViewBackR * (z_proj / viewDirectionInViewBackR.z)
        let pView4L = SGVector.vector4f(pViewL.x, pViewL.y, pViewL.z, .float(1))
        let pView4R = SGVector.vector4f(pViewR.x, pViewR.y, pViewR.z, .float(1))
        let ndc4 = ShaderGraphCoder.geometrySwitchCameraIndex(
            mono: pView4L.transformMatrix(mat: cameraProjection0),
            left: pView4L.transformMatrix(mat: cameraProjection0),
            right: pView4R.transformMatrix(mat: cameraProjection1),
        )
        let ndc = ndc4.xy / ndc4.w
        let uv = (ndc + 1) / 2
        return uv
    }
}
extension SGMatrix {
    static func decodeTexturePixel(texture: SGTexture, offset: SGVector, stride: SGVector = .vector2f(1, 0)) -> SGMatrix {
        .matrix4d(
            SGVector.decodeTexturePixel(texture: texture, texcoord: offset + stride * 0),
            SGVector.decodeTexturePixel(texture: texture, texcoord: offset + stride * 1),
            SGVector.decodeTexturePixel(texture: texture, texcoord: offset + stride * 2),
            SGVector.decodeTexturePixel(texture: texture, texcoord: offset + stride * 3),
        )
    }
}
extension SGVector {
    static func decodeTexturePixel(texture: SGTexture, defaultValue: SGVector = .vector4fZero, texcoord: SGVector) -> SGVector {
        texture.pixel(filter: .nearest, defaultValue: defaultValue, texcoord: texcoord)
    }
}

struct ImmersiveView: View {
    @State private var metalMap = MetalMap(width: 1024, height: 1024)

    var body: some View {
        RealityView { content in

            @MainActor func screenUV() -> SGVector {
                // decode CameraTransform & projection matrices from texture in 4x3 pixels. each row encodes 1 matrix.
                let uniforms = SGTexture.texture(metalMap.uniformsTextureResource)
                // let cameraTransform = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 0))
                let cameraTransformL = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 1))
                let cameraTransformR = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 2))
                let cameraProjection0 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 3))
                let cameraProjection1 = SGMatrix.decodeTexturePixel(texture: uniforms, offset: .vector2f(0, 4))
                return .screenUV(cameraTransformL: cameraTransformL, cameraTransformR: cameraTransformR, cameraProjection0: cameraProjection0, cameraProjection1: cameraProjection1)
            }
            @MainActor func projectedMap(textureLeft left: SGTexture, textureRight right: SGTexture, uv: SGVector) -> SGVector {
                let image: (SGTexture) -> SGVector = {
//                    $0.sampleVector4f(texcoord: uv)
                    $0.image(defaultValue: .vector4fZero,
                             texcoord: uv,
                             uaddressmode: .constant,
                             vaddressmode: .constant,
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
                let color: SGColor = image.image(defaultValue: .transparentBlack, texcoord: mapValue.xy, uaddressmode: .clamp, vaddressmode: .clamp, filtertype: .linear)
//                let uvColor: SGColor = .color3f(mapValue.x, mapValue.y, .float(0))
//                let shift = ShaderGraphCoder.geometrySwitchCameraIndex(mono: SGVector.position(space: .world), left: SGVector.position(space: .world), right: SGVector.position(space: .world)).x.subtract(.float(0.375)).range(inlow: .float(-0.00001), inhigh: .float(0.00001), gamma: .float(1), outlow: .float(0), outhigh: .float(1))

//                return try! await ShaderGraphMaterial(surface: unlitSurface(
//                    color: .color3f(shift, .float(0), .float(0)),
//                    applyPostProcessToneMap: false))

//                return try! await ShaderGraphMaterial(surface: unlitSurface(
//                    color: (color.a * mapValue.w).ifGreater(.float(0.05), trueResult: (uvColor + color.rgb) / 2, falseResult: .black),
//                    opacity: (color.a * mapValue.w).max(.float(0.15)),
//                    applyPostProcessToneMap: false,
//                ))
                return try! await ShaderGraphMaterial(surface: unlitSurface(
                    color: color.rgb,
                    opacity: color.a * mapValue.w,
                    applyPostProcessToneMap: true,
                ))
                return try! await ShaderGraphMaterial(surface: pbrSurface(
                    baseColor: color.rgb,
//                    emissiveColor: .black,
//                    normal: .vector3f(0, 0, 1),
                    roughness: .float(0.0),
//                    metallic: .float(0.05),
                    specular: .float(1 / 1.49),
                    opacity: (color.a * mapValue.w),//.max(.float(0.1)),
//                    clearcoat: .float(0),
                ))
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
//                e.components.set(ViewAttachmentComponent(rootView: VStack {
//                    @Bindable var model = metalMap
//                    Text("IPD = \(model.ipd, format: .number.precision(.fractionLength(3)))")
//                    Slider(value: $metalMap.ipd, in: 0...0.1)
//                    Text("zNear = \(model.near, format: .number.precision(.fractionLength(5)))")
//                    Slider(value: $metalMap.near, in: 0...1)
//                }))
                return e
            }())
        }
    }
}


