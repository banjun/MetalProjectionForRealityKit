import Metal
import RealityKit
import MetalProjectionBridgingHeader

class ScenePassSetting {
    private let device: any MTLDevice
    private(set) var state: MTLRenderPipelineState?
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

    convenience init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat = .depth16Unorm, viewCount: Int) {
#if DEBUG
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead] // .shaderRead is just for debug. not needed for production
#else
        let usage: MTLTextureUsage = [.renderTarget]
#endif
        self.init(device: device,
                  outTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: viewCount),
                  depthTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: depthPixelFormat, usage: usage, viewCount: viewCount))
    }
    init(device: any MTLDevice, outTexture: any MTLTexture, depthTexture: any MTLTexture) {
        self.device = device
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture, depthTexture: depthTexture)

        // add g-buffers
        self.gNormalTexture = RenderPassEncoderSettings.makeTexture(device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rg16Snorm, viewCount: outTexture.arrayLength)
        self.gViewPosTexture = RenderPassEncoderSettings.makeTexture(device: device, width: outTexture.width, height: outTexture.height, pixelFormat: .rgba16Float, viewCount: outTexture.arrayLength)
        descriptor.colorAttachments[1].texture = gNormalTexture
        descriptor.colorAttachments[1].loadAction = .clear
        descriptor.colorAttachments[1].storeAction = .store
        descriptor.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 0)
        descriptor.colorAttachments[2].texture = gViewPosTexture
        descriptor.colorAttachments[2].loadAction = .clear
        descriptor.colorAttachments[2].storeAction = .store
        descriptor.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

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
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: device, vertexFunction: "render_vertex", fragmentFunction: "render_fragment", llMeshes: llMeshes, pixelFormats: [outTexture.pixelFormat, gNormalTexture.pixelFormat, gViewPosTexture.pixelFormat], depthPixelFormat: depthTexture.pixelFormat)
    }

    @MainActor func encode(in commandBuffer: any MTLCommandBuffer, cameraTransformAndProjections: [(transform: simd_float4x4, projection: simd_float4x4)], entities: [Entity]) {
        guard let state, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
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
        var fragmentUniforms: FragmentUniforms = .init(textureSize: .init(Int32(outTexture.width), Int32(outTexture.height)))

        encoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: 2)
        var prevBindTextures: [(any MTLTexture)?] = .init(repeating: nil, count: 1)
        var nextBindTextures: [(any MTLTexture)?] = .init(repeating: nil, count: prevBindTextures.count)
        for (entity, llMesh) in (entities.compactMap {e in e.components[MetalMapSystem.Component.self].map {(e, $0.llMesh)}}) {
            let materials = (entity as? ModelEntity)?.model!.materials ?? []
            if let tex = materialTextureCache[entity.id] {
                nextBindTextures[0] = tex
                encoder.setDepthStencilState(depthStencilState)
                encoder.setCullMode(.back) // just for performance, requires front facing = ccw (below)
                encoder.setFrontFacing(.counterClockwise)
            } else if let baseColorTexture = (
                materials.compactMap {($0 as? PhysicallyBasedMaterial)}.first?.baseColor.texture
                ?? materials.compactMap {$0 as? UnlitMaterial}.first?.color.texture) {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: baseColorTexture.resource.pixelFormat, width: baseColorTexture.resource.width, height: baseColorTexture.resource.height, mipmapped: baseColorTexture.resource.mipmapLevelCount > 1)
                desc.storageMode = .private
                desc.usage = [.shaderRead, .shaderWrite]
                let tex = state.device.makeTexture(descriptor: desc)!
                try! baseColorTexture.resource.copy(to: tex)
                materialTextureCache[entity.id] = tex
            } else {
                nextBindTextures[0] = nil
            }
            nextBindTextures.enumerated().forEach {
                // check identity just for avoiding redundant set insights from Metal Debugger
                guard prevBindTextures[$0.offset] !== $0.element else { return }
                encoder.setFragmentTexture($0.element, index: $0.offset)
                prevBindTextures[$0.offset] = $0.element
            }

            encoder.setVertexBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: 0)
            let worldFromModelTransform = entity.convert(transform: .identity, to: nil).matrix
            for i in 0..<vertexUniforms.count {
                vertexUniforms[i].worldFromModelTransform = worldFromModelTransform
                vertexUniforms[i].cameraFromModelTransform = vertexUniforms[i].cameraFromWorldTransform * worldFromModelTransform
            }
            encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: llMesh.parts.reduce(into: 0) {$0 += $1.indexCount}, indexType: .uint32, indexBuffer: llMesh.readIndices(using: commandBuffer), indexBufferOffset: 0, instanceCount: viewCount)
        }
    }
}
