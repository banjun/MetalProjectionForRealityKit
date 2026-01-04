import Metal
import MetalProjectionBridgingHeader

class SurfaceLightPassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let gNormalTexture: any MTLTexture
    let depthTexture: any MTLTexture
    let outTexture: any MTLTexture

    init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, gNormalTexture: any MTLTexture, depthTexture: any MTLTexture) {
        let library = device.makeBundleDebugLibrary()!
        let outTexture = RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: gNormalTexture.arrayLength)

        let d = MTLRenderPipelineDescriptor()
        d.inputPrimitiveTopology = .triangle
        d.rasterSampleCount = 1
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")!
        d.fragmentFunction = library.makeFunction(name: "surface_light_fragment")!
        d.colorAttachments[0].pixelFormat = outTexture.pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].rgbBlendOperation = .add
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .one
        d.colorAttachments[0].alphaBlendOperation = .add
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .zero
        state = try! device.makeRenderPipelineState(descriptor: d)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.gNormalTexture = gNormalTexture
        self.depthTexture = depthTexture
        self.outTexture = outTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, uniforms: Uniforms, lightsBuffer: any MTLBuffer, lightsCount: Int) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)
        guard lightsCount > 0 else { return }

        var viewCount = outTexture.arrayLength
        encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

        [depthTexture, gNormalTexture].enumerated().forEach { i, inTexture in
            encoder.setFragmentTexture(inTexture, index: i)
        }

        var uniforms: [SurfaceLightUniforms] = [
            SurfaceLightUniforms(viewCount: Int32(outTexture.arrayLength),
                                 projectionInverse: uniforms.projection0Inverse,
                                 worldFromCameraTransform: uniforms.cameraTransformL),
            SurfaceLightUniforms(viewCount: Int32(outTexture.arrayLength),
                                 projectionInverse: uniforms.projection1Inverse,
                                 worldFromCameraTransform: uniforms.cameraTransformR),
        ]
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SurfaceLightUniforms>.stride * 2, index: 0)
        encoder.setFragmentBuffer(lightsBuffer, offset: 0, index: 1)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength * lightsCount)
    }
}
