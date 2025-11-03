import SwiftUI
import RealityKit
import ShaderGraphCoder

struct ImmersiveView: View {
    @State private var metalMap = MetalMap()

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

            let metalMapSystemEnabler = Entity()
            metalMapSystemEnabler.components.set(MetalMapSystem.Component(map: metalMap))
            content.add(metalMapSystemEnabler)
            MetalMapSystem.registerSystem()
        }
    }
}


