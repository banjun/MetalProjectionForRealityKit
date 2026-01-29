import Metal
import RealityKit
import MetalProjectionBridgingHeader

import UIKit
extension SIMD3<Float16> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 3 else { return nil }
        self.init(Float16(cs[0]), Float16(cs[1]), Float16(cs[2]))
    }
}
extension SIMD3<Float> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 3 else { return nil }
        self.init(Float(cs[0]), Float(cs[1]), Float(cs[2]))
    }
}
extension SIMD4<Float16> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 4 else { return nil }
        self.init(Float16(cs[0]), Float16(cs[1]), Float16(cs[2]), Float16(cs[3]))
    }
}

class ScenePassSetting {
    private let device: any MTLDevice
    private(set) var state: MTLRenderPipelineState?
    private var fragmentArgEncoder: (any MTLArgumentEncoder)?
    private var fragmentArgBuffer: (any MTLBuffer)?
    let descriptor: MTLRenderPassDescriptor
    @MainActor var llMeshes: [LowLevelMesh] = [] {
        didSet {createState()} // NOTE: might be redundant. use ECS
    }
    let outTexture: any MTLTexture
    let depthTexture: any MTLTexture
    let depthStencilState: MTLDepthStencilState
    private var materialTextureCache: [Entity.ID: MTLTexture] = [:]
    let gNormalTexture: any MTLTexture
    let gViewPosTexture: any MTLTexture
    let gEmissiveTexture: any MTLTexture

    convenience init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat = .depth16Unorm, viewCount: Int) {
#if DEBUG
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead] // .shaderRead is just for debug. not needed for production
#else
        let usage: MTLTextureUsage = [.renderTarget]
#endif
        self.init(device: device,
                  outTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: viewCount),
                  depthTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: depthPixelFormat, usage: usage, viewCount: viewCount))
        self.outTexture.label = "Albedo"
    }
    init(device: any MTLDevice, outTexture: any MTLTexture, depthTexture: any MTLTexture) {
        self.device = device
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture, depthTexture: depthTexture)

        // add g-buffers
        self.gNormalTexture = RenderPassEncoderSettings.makeTexture(device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rg16Snorm, viewCount: outTexture.arrayLength)
        self.gNormalTexture.label = "Normal"
        self.gViewPosTexture = RenderPassEncoderSettings.makeTexture(device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba16Float, viewCount: outTexture.arrayLength)
        self.gViewPosTexture.label = "ViewPos"
        self.gEmissiveTexture = RenderPassEncoderSettings.makeTexture(device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba16Float, viewCount: outTexture.arrayLength)
        self.gEmissiveTexture.label = "Emissive"
        descriptor.colorAttachments[1].texture = gNormalTexture
        descriptor.colorAttachments[1].loadAction = .clear
        descriptor.colorAttachments[1].storeAction = .store
        descriptor.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 0)
        descriptor.colorAttachments[2].texture = gViewPosTexture
        descriptor.colorAttachments[2].loadAction = .clear
        descriptor.colorAttachments[2].storeAction = .store
        descriptor.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[3].texture = gEmissiveTexture
        descriptor.colorAttachments[3].loadAction = .clear
        descriptor.colorAttachments[3].storeAction = .store
        descriptor.colorAttachments[3].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        self.outTexture = outTexture
        self.depthTexture = depthTexture
        depthStencilState = device.makeDepthStencilState(descriptor: {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = true
            d.depthCompareFunction = .greaterEqual
            return d
        }())!
    }

    @MainActor func createState() {
        let (state, fragmentFunction) = RenderPassEncoderSettings.makeRenderPipelineState(device: device, vertexFunction: "render_vertex", fragmentFunction: "render_fragment", llMeshes: llMeshes, pixelFormats: [outTexture.pixelFormat, gNormalTexture.pixelFormat, gViewPosTexture.pixelFormat, gEmissiveTexture.pixelFormat], depthPixelFormat: depthTexture.pixelFormat)
        self.state = state
        fragmentArgEncoder = fragmentFunction.makeArgumentEncoder(bufferIndex: 0)
    }

    @MainActor func encode(in commandBuffer: any MTLCommandBuffer, cameraTransformAndProjections: [(transform: simd_float4x4, projection: simd_float4x4)], entities: [Entity]) {
        guard let state, let fragmentArgEncoder, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        let viewCount = outTexture.arrayLength
        var vertexUniforms: [VertexUniforms] = cameraTransformAndProjections.map {
            VertexUniforms(viewCount: Int32(cameraTransformAndProjections.count),
                           worldFromModelTransform: .init(), // set later in loop
                           worldFromCameraTransform: $0.transform,
                           cameraFromWorldTransform: $0.transform.inverse,
                           cameraFromModelTransform: .init(), // set later in loop
                           projectionFromCameraTransform: $0.projection,
                           cameraFromProjectionTransform: $0.projection.inverse)
        }

        let entityLLMeshes = entities.compactMap {e in e.components[MetalMapSystem.Component.self].map {(e, $0.llMesh)}}
        let totalPartsCount = entityLLMeshes.reduce(into: 0) {$0 += $1.1.parts.count}
        let argBufferAlignment = 256 // Fragment Function(render_fragment): the offset into the buffer uniforms that is bound at Buffer index 0 must be a multiple of 256
        let argBufferAlignedLength = (fragmentArgEncoder.encodedLength + argBufferAlignment - 1) & ~(argBufferAlignment - 1)
        if fragmentArgBuffer?.length != argBufferAlignedLength * totalPartsCount {
            fragmentArgBuffer = device.makeBuffer(length: argBufferAlignedLength * totalPartsCount, options: .storageModeShared)
        }
        guard let fragmentArgBuffer else { return }
        var usedTextures: [any MTLTexture] = []
        var fragmentArgBufferOffset = 0
        for (entity, llMesh) in entityLLMeshes {
            let materials = (entity as? ModelEntity)?.model!.materials ?? []
            for part in llMesh.parts {
                let m = part.materialIndex < materials.count ? materials[part.materialIndex] : nil
                let offset = fragmentArgBufferOffset
                defer {fragmentArgBufferOffset += argBufferAlignedLength}
                fragmentArgEncoder.setArgumentBuffer(fragmentArgBuffer, offset: offset)

                var uniforms: FragmentUniforms
                var textureAndIndexes: [(any MTLTexture, Int)] = []
                switch m {
                case let unlit as UnlitMaterial:
                    uniforms = .init(
                        flags: [
                            unlit.color.texture != nil ? .HasBaseColorTexture : [],
                        ],
                        baseColor: .init(unlit.color.tint) ?? .zero,
                        baseColorTexture: 0,
                        emissiveColor: .zero,
                        emissiveColorTexture: 0)
                    if let tex = materialTextureCache[entity.id] { // maybe key should be (entity.id, materialIndex)?
                        textureAndIndexes.append((tex, 2))
                    } else if let baseColorTexture = unlit.color.texture {
                        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: baseColorTexture.resource.pixelFormat, width: baseColorTexture.resource.width, height: baseColorTexture.resource.height, mipmapped: baseColorTexture.resource.mipmapLevelCount > 1)
                        desc.storageMode = .private
                        desc.usage = [.shaderRead, .shaderWrite]
                        let tex = state.device.makeTexture(descriptor: desc)!
                        try! baseColorTexture.resource.copy(to: tex)
                        materialTextureCache[entity.id] = tex
                    }
                case let pbr as PhysicallyBasedMaterial:
                    uniforms = .init(
                        flags: [
                            // .EmitsLight,
                            pbr.baseColor.texture != nil ? .HasBaseColorTexture : [],
                            pbr.emissiveColor.texture != nil ? .HasEmissiveColorTexture : [],
                        ],
                        baseColor: .init(pbr.baseColor.tint) ?? .zero,
                        baseColorTexture: 0,
                        emissiveColor: .init(pbr.emissiveColor.color) ?? .zero,
                        emissiveColorTexture: 0)
                    if let tex = materialTextureCache[entity.id] { // maybe key should be (entity.id, materialIndex)?
                        textureAndIndexes.append((tex, 2))
                    } else if let baseColorTexture = pbr.baseColor.texture {
                        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: baseColorTexture.resource.pixelFormat, width: baseColorTexture.resource.width, height: baseColorTexture.resource.height, mipmapped: baseColorTexture.resource.mipmapLevelCount > 1)
                        desc.storageMode = .private
                        desc.usage = [.shaderRead, .shaderWrite]
                        let tex = state.device.makeTexture(descriptor: desc)!
                        try! baseColorTexture.resource.copy(to: tex)
                        materialTextureCache[entity.id] = tex
                    }
                    // TODO
                    //
                    //                    if let tex = materialEmissiveColorTextureCache[entity.id] { // maybe key should be (entity.id, materialIndex)?
                    //                        textureAndIndexes.append((tex, 4))
                    //                    }
                default:
                    uniforms = .init(flags: [], baseColor: .init(UIColor.magenta)!, baseColorTexture: 0, emissiveColor: .init(UIColor.magenta)!, emissiveColorTexture: 0)
                }
                fragmentArgBuffer.contents().advanced(by: offset).copyMemory(from: &uniforms, byteCount: fragmentArgEncoder.encodedLength)
                for (tex, index) in textureAndIndexes {
                    fragmentArgEncoder.setTexture(tex, index: index)
                    usedTextures.append(tex)
                }
            }
        }
        if !usedTextures.isEmpty {
            encoder.useResources(usedTextures, usage: .read, stages: .fragment)
        }

        encoder.setDepthStencilState(depthStencilState)
        encoder.setCullMode(.back) // just for performance, requires front facing = ccw (below)
        encoder.setFrontFacing(.counterClockwise)

        // draw
        fragmentArgBufferOffset = 0
        encoder.setFragmentBuffer(fragmentArgBuffer, offset: 0, index: 0)
        for (entity, llMesh) in entityLLMeshes {
            encoder.setVertexBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: 0)
            let worldFromModelTransform = entity.convert(transform: .identity, to: nil).matrix
            for i in 0..<vertexUniforms.count {
                vertexUniforms[i].worldFromModelTransform = worldFromModelTransform
                vertexUniforms[i].cameraFromModelTransform = vertexUniforms[i].cameraFromWorldTransform * worldFromModelTransform
            }
            encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: 1)

            let indexBuffer = llMesh.readIndices(using: commandBuffer)
            for part in llMesh.parts {
                if fragmentArgBufferOffset != 0 {
                    encoder.setFragmentBufferOffset(fragmentArgBufferOffset, index: 0)
                }
                fragmentArgBufferOffset += argBufferAlignedLength
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: part.indexOffset, instanceCount: viewCount)
            }
        }
    }
}
