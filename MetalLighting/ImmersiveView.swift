import SwiftUI
import RealityKit
import ShaderGraphCoder

extension SGTexture {
    func image2DArrayColor4(index: SGValue = .int(0), defaultValue: SGColor, texcoord: SGVector? = nil, magFilter: SGSamplerMinMagFilter = SGSamplerMinMagFilter.linear, minFilter: SGSamplerMinMagFilter = SGSamplerMinMagFilter.linear, uWrapMode: SGSamplerAddressMode = SGSamplerAddressMode.clampToEdge, vWrapMode: SGSamplerAddressMode = SGSamplerAddressMode.clampToEdge, noFlipV: SGValue = .int(0)) -> SGColor {
        SGColor(source: .nodeOutput(SGNode(
            nodeType: "ND_RealityKitTexture2DArray_color4",
            inputs: [
                .init(name: "file", dataType: SGDataType.asset, connection: self),
                .init(name: "u_wrap_mode", dataType: SGDataType.string, connection: SGString(source: .constant(.string(uWrapMode.rawValue)))),
                .init(name: "v_wrap_mode", dataType: SGDataType.string, connection: SGString(source: .constant(.string(vWrapMode.rawValue)))),
                .init(name: "mag_filter", dataType: SGDataType.string, connection: SGString(source: .constant(.string(magFilter.rawValue)))),
                .init(name: "min_filter", dataType: SGDataType.string, connection: SGString(source: .constant(.string(minFilter.rawValue)))),
                .init(name: "default", dataType: SGDataType.color4f, connection: defaultValue),
                .init(name: "texcoord", dataType: SGDataType.vector2f, connection: texcoord),
                .init(name: "index", dataType: SGDataType.int, connection: index),
                .init(name: "no_flip_v", dataType: SGDataType.bool, connection: noFlipV),
            ],
            outputs: [.init(dataType: SGDataType.color4f)])))
    }
}

struct ImmersiveView: View {
    @State private var metalMap = MetalMap(width: 1024, height: 1024)

    var body: some View {
        RealityView { content in
            let llImporter = try! await USDZLowLevelMeshImporter(usdz: ModelEntity(named: "ありす4"))
            content.add({
                let usdzLLEntity = try! llImporter.modelEntity()
//                usdzLLEntity.position = [0, 1, -1]
                return usdzLLEntity
            }())

            await content.add({
                let texView = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                    {
                        let tex = SGTexture.texture(metalMap.textureResource)
                        let color: SGColor = tex.image2DArrayColor4(
                            index: .int(0),
                            defaultValue: .transparentBlack,
                            magFilter: .nearest,
                            minFilter: .nearest,
                            uWrapMode: .clampToEdge,
                            vWrapMode: .clampToEdge,
                            noFlipV: .int(1),
                        )
                        return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                    }()
                ])
                texView.position = [0, 0.5, -1]
                return texView
            }())

            await content.add({
                let texView = await ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [
                    {
                        let tex = SGTexture.texture(metalMap.textureResource)
                        let color: SGColor = tex.image2DArrayColor4(
                            index: .int(1),
                            defaultValue: .transparentBlack,
                            magFilter: .nearest,
                            minFilter: .nearest,
                            uWrapMode: .clampToEdge,
                            vWrapMode: .clampToEdge,
                            noFlipV: .int(1),
                        )
                        return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a))
                    }()
                ])
                texView.position = [0, 1.0, -1]
                return texView
            }())

            metalMap.llMesh = llImporter.mesh
            content.add({
                let e = Entity()
                e.components.set(MetalMapSystem.Component(map: metalMap))
                return e
            }())
            MetalMapSystem.registerSystem()
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
