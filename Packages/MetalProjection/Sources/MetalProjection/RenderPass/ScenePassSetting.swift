import Metal
import RealityKit
import MetalProjectionBridgingHeader

class ScenePassSetting {
    private let device: any MTLDevice
    private let state: MTLRenderPipelineState
    private let pipelineDescriptor: MTLRenderPipelineDescriptor
    private let ormState: MTLComputePipelineState
    private let fragmentArgEncoder: (any MTLArgumentEncoder)
    private var fragmentArgBuffers: [any MTLBuffer] = []
    private var fragmentArgBufferIndex: Int = 0
    private var fragmentArgBufferSemaphore = DispatchSemaphore(value: 3)
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture
    let depthTexture: any MTLTexture
    let depthStencilState: MTLDepthStencilState
    private var baseColorTextureCache: [Entity.ID: MTLTexture] = [:]
    private var ormTextureCache: [Entity.ID: MTLTexture] = [:]
    private var normalTextureCache: [Entity.ID: MTLTexture] = [:]
    private var emissiveTextureCache: [Entity.ID: MTLTexture] = [:]
    let gNormalTexture: any MTLTexture
    let gViewPosTexture: any MTLTexture
    let gEmissiveTexture: any MTLTexture
    let gORMTexture: any MTLTexture // Occlusion, Roughness, Metalic

    private var missingFunctions: [String] = []
    private var shaderGraphMaterialPipelineStates: [String: MTLRenderPipelineState] = [:]

    convenience init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat = .depth16Unorm, viewCount: Int, llDescriptor: LowLevelMesh.Descriptor = USDZLowLevelMeshImporter.Vertex.descriptor, rasterizationRateMap: (any MTLRasterizationRateMap)?) {
#if DEBUG
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead] // .shaderRead is just for debug. not needed for production
#else
        let usage: MTLTextureUsage = [.renderTarget]
#endif
        self.init(device: device,
                  outTexture: RenderPassEncoderSettings.makeTexture("Albedo", device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: viewCount),
                  depthTexture: RenderPassEncoderSettings.makeTexture("Depth", device: device, width: width, height: height, pixelFormat: depthPixelFormat, usage: usage, viewCount: viewCount),
                  llDescriptor: llDescriptor, rasterizationRateMap: rasterizationRateMap)
    }
    init(device: any MTLDevice, outTexture: any MTLTexture, depthTexture: any MTLTexture, llDescriptor: LowLevelMesh.Descriptor, rasterizationRateMap: (any MTLRasterizationRateMap)?) {
        self.device = device
        self.outTexture = outTexture
        self.depthTexture = depthTexture
        depthStencilState = device.makeDepthStencilState(descriptor: {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = true
            d.depthCompareFunction = .greaterEqual
            return d
        }())!

        // add g-buffer textures
        self.gNormalTexture = RenderPassEncoderSettings.makeTexture("Normal", device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rg16Snorm, viewCount: outTexture.arrayLength)
        self.gViewPosTexture = RenderPassEncoderSettings.makeTexture("ViewPos", device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba16Float, viewCount: outTexture.arrayLength)
        self.gEmissiveTexture = RenderPassEncoderSettings.makeTexture("Emissive", device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba16Float, viewCount: outTexture.arrayLength)
        self.gORMTexture = RenderPassEncoderSettings.makeTexture("AO/Roughness/Metalic", device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba8Unorm, viewCount: outTexture.arrayLength)
        // add g-buffer settings
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture, depthTexture: depthTexture)
        descriptor.rasterizationRateMap = rasterizationRateMap
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
        descriptor.colorAttachments[4].texture = gORMTexture
        descriptor.colorAttachments[4].loadAction = .clear
        descriptor.colorAttachments[4].storeAction = .store
        descriptor.colorAttachments[4].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let pipelineDescriptor = RenderPassEncoderSettings.makeRenderPipelineDescriptor(device: device, vertexFunction: "gbuffer_vertex", fragmentFunction: "gbuffer_fragment", llDescriptor: llDescriptor, pixelFormats: [outTexture, gNormalTexture, gViewPosTexture, gEmissiveTexture, gORMTexture].map(\.pixelFormat), depthPixelFormat: depthTexture.pixelFormat)
        self.pipelineDescriptor = pipelineDescriptor
        let fragmentFunction = pipelineDescriptor.fragmentFunction!
        self.state = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        fragmentArgEncoder = fragmentFunction.makeArgumentEncoder(bufferIndex: 0)

        ormState = RenderPassEncoderSettings.makeComputePipelineState(device: device, kernelFunction: "packORM")
    }

    @MainActor func encode(in commandBuffer: any MTLCommandBuffer, cameraTransformAndProjections: [(transform: simd_float4x4, projection: simd_float4x4)], entities: [Entity]) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setCullMode(.back) // just for performance, requires front facing = ccw (below)
        encoder.setFrontFacing(.counterClockwise)

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
        // triple buffered (CPU writing, ready to pass to GPU, GPU reading)
        fragmentArgBufferSemaphore.wait()
        commandBuffer.addCompletedHandler {[weak s = fragmentArgBufferSemaphore] _ in s?.signal()}
        defer {fragmentArgBufferIndex = (fragmentArgBufferIndex + 1) % 3}
        var fragmentArgBuffer = fragmentArgBufferIndex < fragmentArgBuffers.count ? fragmentArgBuffers[fragmentArgBufferIndex] : nil
        if fragmentArgBuffer?.length != argBufferAlignedLength * totalPartsCount {
            fragmentArgBuffers = (0..<3).compactMap {_ in device.makeBuffer(length: argBufferAlignedLength * totalPartsCount, options: .storageModeShared)}
            fragmentArgBuffer = fragmentArgBufferIndex < fragmentArgBuffers.count ? fragmentArgBuffers[fragmentArgBufferIndex] : nil
        }
        guard let fragmentArgBuffer else { return }
        var usedTextures: [any MTLTexture] = []
        var fragmentArgBufferOffset = 0
        for (entity, llMesh) in entityLLMeshes {
            let materials = (entity as? ModelEntity)?.model!.materials ?? []
            for part in llMesh.parts {
                let m = part.materialIndex < materials.count ? materials[part.materialIndex] : nil
                if case let shaderGraph as ShaderGraphMaterial = m {
                    continue // TODO: should be separated in loop level
                }

                let offset = fragmentArgBufferOffset
                defer {fragmentArgBufferOffset += argBufferAlignedLength}
                fragmentArgEncoder.setArgumentBuffer(fragmentArgBuffer, offset: offset)

                var uniforms: FragmentUniforms
                var textureAndIndexes: [(any MTLTexture, Int)] = []
                switch m {
                case let unlit as UnlitMaterial:
                    uniforms = .init(
                        flags: [],
                        baseColor: .init(unlit.color.tint) ?? .zero,
                        baseColorTexture: 0,
                        emissiveColor: .zero,
                        emissiveColorTexture: 0,
                        orm: .init(1, 0, 0),
                        ormTexture: 0,
                        normalTexture: 0)
                    if let tex = baseColorTextureCache[entity.id] { // maybe key should be (entity.id, materialIndex)?
                        uniforms.flags.insert(.HasBaseColorTexture)
                        textureAndIndexes.append((tex, 2))
                    } else if let tr = unlit.color.texture?.resource {
                        baseColorTextureCache[entity.id] = textureCache(in: commandBuffer, tr: tr)
                    }
                case let pbr as PhysicallyBasedMaterial:
                    uniforms = .init(
                        flags: [],
                        baseColor: .init(pbr.baseColor.tint) ?? .zero,
                        baseColorTexture: 0,
                        emissiveColor: .init(pbr.emissiveColor.color) ?? .zero,
                        emissiveColorTexture: 0,
                        orm: .init(1, Float16(pbr.roughness.scale), Float16(pbr.metallic.scale)),
                        ormTexture: 0,
                        normalTexture: 0)
                    if let tex = baseColorTextureCache[entity.id] { // maybe key should be (entity.id, materialIndex)?
                        uniforms.flags.insert(.HasBaseColorTexture)
                        textureAndIndexes.append((tex, 2))
                    } else if let tr = pbr.baseColor.texture?.resource {
                        baseColorTextureCache[entity.id] = textureCache(in: commandBuffer, tr: tr)
                    }
                    if let tex = emissiveTextureCache[entity.id] {
                        uniforms.flags.insert(.HasEmissiveColorTexture)
                        textureAndIndexes.append((tex, 4))
                    } else if let tr = pbr.emissiveColor.texture?.resource {
                        emissiveTextureCache[entity.id] = textureCache(in: commandBuffer, tr: tr)
                    }
                    if let tex = ormTextureCache[entity.id] {
                        if pbr.ambientOcclusion.texture != nil {uniforms.flags.insert(.HasAOTexture)}
                        if pbr.roughness.texture != nil {uniforms.flags.insert(.HasRoughnessTexture)}
                        if pbr.metallic.texture != nil {uniforms.flags.insert(.HasMetalicTexture)}
                        textureAndIndexes.append((tex, 6))
                    } else if pbr.ambientOcclusion.texture != nil || pbr.roughness.texture != nil || pbr.metallic.texture != nil {
                        ormTextureCache[entity.id] = ormPack(createAnotherAndCommittingFrom: commandBuffer, ao: pbr.ambientOcclusion.texture?.resource, roughness: pbr.roughness.texture?.resource, metalic: pbr.metallic.texture?.resource)
                    }
                    if let tex = normalTextureCache[entity.id] {
                        uniforms.flags.insert(.HasNormalTexture)
                        textureAndIndexes.append((tex, 7))
                    } else if let tr = pbr.normal.texture?.resource {
                        normalTextureCache[entity.id] = textureCache(in: commandBuffer, tr: tr)
                    }
                default:
                    uniforms = .init(flags: [], baseColor: .init(.magenta)!, baseColorTexture: 0, emissiveColor: .init(.magenta)!, emissiveColorTexture: 0, orm: .init(1, 0, 0), ormTexture: 0, normalTexture: 0)
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

        // draw
        fragmentArgBufferOffset = 0
        encoder.setFragmentBuffer(fragmentArgBuffer, offset: 0, index: 0)

        func setVertexBuffersDefered(entity: Entity, llMesh: LowLevelMesh) -> () -> MTLBuffer {
            {
                encoder.setVertexBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: 0)
                let worldFromModelTransform = entity.convert(transform: .identity, to: nil).matrix
                for i in 0..<vertexUniforms.count {
                    vertexUniforms[i].worldFromModelTransform = worldFromModelTransform
                    vertexUniforms[i].cameraFromModelTransform = vertexUniforms[i].cameraFromWorldTransform * worldFromModelTransform
                }
                encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: 1)

                return llMesh.readIndices(using: commandBuffer)
            }
        }

        var shaderGraphMaterialParts: [(part: LowLevelMesh.Part, indexBuffer: () -> MTLBuffer, state: MTLRenderPipelineState)] = []
        for (entity, llMesh) in entityLLMeshes {
            // --
            let materials = (entity as? ModelEntity)?.model!.materials ?? []
            // --
            let deferred = setVertexBuffersDefered(entity: entity, llMesh: llMesh)
            let indexBuffer = deferred()
            for part in llMesh.parts {
                let m = part.materialIndex < materials.count ? materials[part.materialIndex] : nil
                if case let sgm as ShaderGraphMaterial = m, let name = sgm.name {
                    // ShaderGraphMaterial uses another fragment function and does not use fragment argument buffers for default fragment function
                    let fragmentFunctionName = "gbuffer_RCP_" + name // naming convention
                    let library = device.makeBundleDebugLibrary()!
                    if let fragmentFunction = library.makeFunction(name: fragmentFunctionName) {
                        let state = shaderGraphMaterialPipelineStates[fragmentFunction.name] ?? {
                            let d = pipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
                            d.label = fragmentFunction.name
                            d.fragmentFunction = fragmentFunction
                            let state = try! device.makeRenderPipelineState(descriptor: d)
                            shaderGraphMaterialPipelineStates[fragmentFunction.name] = state
                            return state
                        }()
                        shaderGraphMaterialParts.append((part, deferred, state))
                        continue // does not encode into fragment buffer, because using another fragment function
                    } else if !missingFunctions.contains(fragmentFunctionName) {
                        NSLog("%@", "⚠️ \(#function): [[fragment]] function `\(fragmentFunctionName)` should be exist in Metal Shaders, but not found.")
                        missingFunctions.append(fragmentFunctionName)
                    }
                }

                if fragmentArgBufferOffset != 0 {
                    encoder.setFragmentBufferOffset(fragmentArgBufferOffset, index: 0)
                }
                fragmentArgBufferOffset += argBufferAlignedLength
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: part.indexOffset, instanceCount: viewCount)
            }
        }

        // draw ShaderGraphMaterials with switching pipeline state
        for (part, deferred, state) in shaderGraphMaterialParts {
            encoder.setRenderPipelineState(state)
            let indexBuffer = deferred()
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: part.indexOffset, instanceCount: viewCount)
        }
    }

    @MainActor private func ormPack(createAnotherAndCommittingFrom commandBuffer: any MTLCommandBuffer, ao: TextureResource?, roughness: TextureResource?, metalic: TextureResource?) -> (any MTLTexture)? {
        let anotherBuffer = commandBuffer.commandQueue.makeCommandBuffer()!
        defer {anotherBuffer.commit()}
        return ormPack(in: anotherBuffer, ao: ao, roughness: roughness, metalic: metalic)
    }
    @MainActor private func ormPack(in commandBuffer: any MTLCommandBuffer, ao: TextureResource?, roughness: TextureResource?, metalic: TextureResource?) -> (any MTLTexture)? {
        let width = max(ao?.width ?? 1, roughness?.width ?? 1, metalic?.width ?? 1)
        let height = max(ao?.height ?? 1, roughness?.height ?? 1, metalic?.height ?? 1)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        let ormTex = state.device.makeTexture(descriptor: desc)!
        ormTex.label = "Packed ORM"
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        computeEncoder.setComputePipelineState(ormState)

        let textures: [(any MTLTexture)?] = [ao, roughness, metalic].map { (t: TextureResource?) -> (any MTLTexture)? in
            if let t {
                let tex = state.device.makeTexture(descriptor: {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: t.width, height: t.height, mipmapped: false)
                    d.usage = [.shaderRead, .shaderWrite]
                    return d
                }())!
                try! t.copy(to: tex)
                return tex
            } else { return nil }
        }
        computeEncoder.setTextures(textures, range: 0..<3)
        computeEncoder.setTexture(ormTex, index: 3)
        var flags: [UInt32] = textures.map {$0 != nil ? 1 : 0}
        computeEncoder.setBytes(&flags, length: MemoryLayout<Int>.stride * flags.count, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
                                   height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
                                   depth: 1)
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        generateMipmaps(in: commandBuffer, for: ormTex)
        return ormTex
    }

    @MainActor private func textureCache(in commandBuffer: any MTLCommandBuffer, tr: TextureResource) -> (any MTLTexture)? {
        let tex = state.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tr.pixelFormat, width: tr.width, height: tr.height, mipmapped: tr.mipmapLevelCount > 1)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite] // read for use in metal shaders, and write for tr.copy
            return d
        }())!
        try! tr.copy(to: tex)
        generateMipmaps(createAnotherAndCommittingFrom: commandBuffer, for: tex)
        return tex
    }

    private func generateMipmaps(createAnotherAndCommittingFrom commandBuffer: any MTLCommandBuffer, for tex: any MTLTexture) {
        let anotherBuffer = commandBuffer.commandQueue.makeCommandBuffer()!
        defer {anotherBuffer.commit()}
        generateMipmaps(in: anotherBuffer, for: tex)
    }
    private func generateMipmaps(in commandBuffer: any MTLCommandBuffer, for tex: any MTLTexture) {
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
    }
}
