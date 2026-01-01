import Metal
import MetalProjectionBridgingHeader

class VolumeLightPassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture
    let depthTexture: any MTLTexture
    let depthStencilState: MTLDepthStencilState

    struct Vertex {
        var position: SIMD3<Float>
    }

    convenience init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, depthTexture: any MTLTexture, viewCount: Int) {
        self.init(device: device,
                  outTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: viewCount),
                  depthTexture: depthTexture)
    }
    init(device: any MTLDevice, outTexture: any MTLTexture, depthTexture: any MTLTexture) {
        let library = device.makeBundleDebugLibrary()!

        let d = MTLRenderPipelineDescriptor()
        d.inputPrimitiveTopology = .triangle
        d.rasterSampleCount = 1
        d.vertexFunction = library.makeFunction(name: "volume_light_vertex")!
        d.vertexDescriptor = .init()
        d.vertexDescriptor!.layouts[0]!.stride = MemoryLayout<Vertex>.stride
        d.vertexDescriptor!.attributes[0]!.format = .float3
        d.vertexDescriptor!.attributes[0]!.offset = MemoryLayout<Vertex>.offset(of: \.position)!
        d.vertexDescriptor!.attributes[0]!.bufferIndex = 0
        d.fragmentFunction = library.makeFunction(name: "volume_light_fragment")!
        d.colorAttachments[0].pixelFormat = outTexture.pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].rgbBlendOperation = .add
        d.colorAttachments[0].alphaBlendOperation = .add
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .one
        d.depthAttachmentPixelFormat = depthTexture.pixelFormat

        state = try! device.makeRenderPipelineState(descriptor: d)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture, depthTexture: depthTexture, depthLoadAction: .load, depthStoreAction: .dontCare)
        depthStencilState = device.makeDepthStencilState(descriptor: {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = false
            d.depthCompareFunction = .greaterEqual
            return d
        }())!
        self.outTexture = outTexture
        self.depthTexture = depthTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inDepthTexture: any MTLTexture, uniforms: Uniforms, lights: [VolumeSpotLight]) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        var uniforms = uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout.stride(ofValue: uniforms), index: 0)
        [inDepthTexture].enumerated().forEach { i, inDepthTexture in
            encoder.setFragmentTexture(inDepthTexture, index: i)
        }
        let divisionStep: Float = .pi / 8
        let normalizedConeVertices: [Vertex] = stride(from: 0, to: 2 * .pi, by: divisionStep).flatMap { a in [
            SIMD3<Float>.zero,
            SIMD3<Float>(cos(a), -1, sin(a)),
            SIMD3<Float>(cos(a + divisionStep), -1, sin(a + divisionStep)),
        ]}.map {Vertex(position: $0)}
        encoder.setVertexBytes(normalizedConeVertices, length: MemoryLayout<Vertex>.stride * normalizedConeVertices.count, index: 0)
        var vertexUniforms: [VertexUniforms] = (0..<outTexture.arrayLength).map { vid in
            let cameraTransform = vid == 0 ? uniforms.cameraTransformL : uniforms.cameraTransformR
            return VertexUniforms(
                viewCount: Int32(outTexture.arrayLength),
                modelTransform: .init(diagonal: [1, 1, 1, 1]), // TODO: model transform could be per light
                cameraTransform: cameraTransform,
                cameraTransformInverse: cameraTransform.inverse,
                projection: vid == 0 ? uniforms.projection0 : uniforms.projection1,
                projectionInverse: vid == 0 ? uniforms.projection0Inverse : uniforms.projection1Inverse,
            )
        }
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: 1)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setFrontFacing(.clockwise)
        encoder.setCullMode(.none)
        var lights = lights
        var lightCounts = lights.count
        encoder.setVertexBytes(&lights, length: MemoryLayout<VolumeSpotLight>.stride * lightCounts, index: 2)
        encoder.setVertexBytes(&lightCounts, length: MemoryLayout.stride(ofValue: lightCounts), index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: normalizedConeVertices.count, instanceCount: lightCounts * outTexture.arrayLength)
    }
}
