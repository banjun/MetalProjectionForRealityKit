import Metal
import RealityKit
import ARKit
import QuartzCore
import Observation

@Observable
final class MetalMap {
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let commandQueue: MTLCommandQueue
    private let llTexture: LowLevelTexture // type2DArray, [left, right]
    private let metalTexture: MTLTexture // type2DArray, [left, right]
    let textureResource: TextureResource // type2DArray, [left, right]
    private let vertexIndex: Int
    private let vertexUniformsIndex: Int
    private let fragmentUniformsIndex: Int
    private let baseColorTextureIndex: Int

    private let uniformsTexture: LowLevelTexture
    private let uniformsMetalTexture: MTLTexture
    private let uniformsBuffer: any MTLBuffer
    let uniformsTextureResource: TextureResource

    let pixelFormat: MTLPixelFormat = .rgba16Float

    private let depthPixelFormat: MTLPixelFormat = .depth16Unorm
    private let depthTexture: MTLTexture
    private let depthStencilState: MTLDepthStencilState

    var llMesh: LowLevelMesh? {
        didSet {
            createRenderPipelineState()
        }
    }
    private var renderPipelineState: MTLRenderPipelineState?

    private var materialTextureCache: [Entity.ID: MTLTexture] = [:]

    private var arkitSession: ARKitSession? {
        didSet {oldValue?.stop()}
    }
    private var worldTracker: WorldTrackingProvider?

    init(width: Int = 32, height: Int = 32, viewCount: Int = DeviceDependants.viewCount, vertexIndex: Int = 0, vertexUniformsIndex: Int = 1, fragmentUniformsIndex: Int = 2, baseColorTextureIndex: Int = 0) {
        commandQueue = device.makeCommandQueue()!
        llTexture = try! LowLevelTexture(descriptor: .init(textureType: .type2DArray, pixelFormat: pixelFormat, width: width, height: height, arrayLength: viewCount)) // arrayLength: 2 for left/right eye
        metalTexture = llTexture.read()
        textureResource = try! .init(from: llTexture)

        self.vertexIndex = vertexIndex
        self.vertexUniformsIndex = vertexUniformsIndex
        self.fragmentUniformsIndex = fragmentUniformsIndex
        self.baseColorTextureIndex = baseColorTextureIndex

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 5)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 4 for camera center, transformL, transformR, projection0, projection1.
        uniformsMetalTexture = uniformsTexture.read()
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 5)!

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthPixelFormat,
            width: metalTexture.width,
            height: metalTexture.height,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        depthDescriptor.textureType = .type2DArray
        depthDescriptor.arrayLength = viewCount
        depthTexture = device.makeTexture(descriptor: depthDescriptor)!
        depthStencilState = device.makeDepthStencilState(descriptor: {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = true
            d.depthCompareFunction = .greaterEqual
            return d
        }())!
    }

    private func createRenderPipelineState() {
        guard let descriptor = llMesh?.descriptor else {
            renderPipelineState = nil
            return
        }
        let render_vertex = device.makeDefaultLibrary()!.makeFunction(name: "render_vertex")!
        let render_fragment = device.makeDefaultLibrary()!.makeFunction(name: "render_fragment")!

        renderPipelineState = try! device.makeRenderPipelineState(descriptor: {
            let d = MTLRenderPipelineDescriptor()
            d.inputPrimitiveTopology = .triangle
            d.rasterSampleCount = 1
            d.vertexFunction = render_vertex
            d.vertexDescriptor = .init()
            descriptor.vertexLayouts.enumerated().forEach { i, l in
                d.vertexDescriptor!.layouts[i]!.stride = l.bufferStride
            }
            let vertexAttributes: [LowLevelMesh.Attribute] = descriptor.vertexAttributes
            vertexAttributes.enumerated().forEach { i, a in
                d.vertexDescriptor!.attributes[i]!.format = a.format
                d.vertexDescriptor!.attributes[i]!.offset = a.offset
                d.vertexDescriptor!.attributes[i]!.bufferIndex = a.layoutIndex
            }
            d.fragmentFunction = render_fragment
            d.colorAttachments[0].pixelFormat = pixelFormat
            d.depthAttachmentPixelFormat = depthPixelFormat
            return d
        }())
    }

    func draw(_ entity: Entity) {
        guard let worldTracker else {
            let arkitSession = ARKitSession()
            let worldTracker = WorldTrackingProvider()
            Task {try! await arkitSession.run([worldTracker])}
            self.arkitSession = arkitSession
            self.worldTracker = worldTracker
            return
        }
        guard let deviceAnchor = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime() + 0.01) else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        let cameraTransformAndProjections = DeviceDependants.cameraTransformAndProjections(deviceAnchor: deviceAnchor)
        var uniforms = Uniforms(
            cameraTransformL: cameraTransformAndProjections.first!.transform,
            cameraTransformR: cameraTransformAndProjections.last!.transform,
            projection0: cameraTransformAndProjections.first!.projection,
            projection1: cameraTransformAndProjections.last!.projection,
            projection0Inverse: cameraTransformAndProjections.first!.projection.inverse,
            projection1Inverse: cameraTransformAndProjections.last!.projection.inverse,
        )
        var vertexUniforms: [VertexUniforms] = cameraTransformAndProjections.map {
            VertexUniforms(modelTransform: entity.transform.matrix,
                           cameraTransform: $0.transform,
                           cameraTransformInverse: $0.transform.inverse,
                           projection: $0.projection,
                           projectionInverse: $0.projection.inverse)
        }
        var fragmentUniforms: FragmentUniforms = .init(textureSize: .init(Int32(metalTexture.width), Int32(metalTexture.height)))

        if let llMesh, let renderPipelineState, let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
            let d = MTLRenderPassDescriptor()
            d.renderTargetArrayLength = metalTexture.arrayLength
            d.colorAttachments[0]?.texture = metalTexture
            d.colorAttachments[0]?.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            d.colorAttachments[0]?.loadAction = .clear
            d.colorAttachments[0]?.storeAction = .store

            d.depthAttachment.texture = depthTexture
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.storeAction = .dontCare
            d.depthAttachment.clearDepth = 0
            return d
        }()) {
            defer {renderEncoder.endEncoding()}
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: vertexIndex)
            renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: vertexUniformsIndex)
            renderEncoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: fragmentUniformsIndex)
            if let tex = materialTextureCache[entity.id] {
                renderEncoder.setFragmentTexture(tex, index: baseColorTextureIndex)
                renderEncoder.setDepthStencilState(depthStencilState)
                renderEncoder.setCullMode(.back) // just for performance, requires front facing = ccw (below)
                renderEncoder.setFrontFacing(.counterClockwise)
            } else if let baseColorTexture = ((entity as? ModelEntity)?.model!.materials.compactMap {$0 as? PhysicallyBasedMaterial}.first?.baseColor.texture) {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: baseColorTexture.resource.pixelFormat, width: baseColorTexture.resource.width, height: baseColorTexture.resource.height, mipmapped: baseColorTexture.resource.mipmapLevelCount > 1)
                desc.storageMode = .private
                desc.usage = [.shaderRead, .shaderWrite]
                let tex = renderPipelineState.device.makeTexture(descriptor: desc)!
                try! baseColorTexture.resource.copy(to: tex)
                materialTextureCache[entity.id] = tex
            }

            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: llMesh.parts.reduce(into: 0) {$0 += $1.indexCount}, indexType: .uint32, indexBuffer: llMesh.readIndices(using: commandBuffer), indexBufferOffset: 0, instanceCount: vertexUniforms.count) // instanceCount: 2 for left/right projection (view id)
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            defer {blit.endEncoding()}
            withUnsafeBytes(of: &uniforms) { u in
                uniformsBuffer.contents().copyMemory(from: u.baseAddress!, byteCount: MemoryLayout<Uniforms>.size)
            }
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 5, depth: 1), to: uniformsMetalTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
    }
}
