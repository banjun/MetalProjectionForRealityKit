import Metal
import MetalProjectionBridgingHeader

class SurfaceLightPassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let gViewPosTexture: any MTLTexture // avoid heavy (and incorrect resulting) inverse from depth tex
    let gNormalTexture: any MTLTexture
    let outTexture: any MTLTexture

    init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, gNormalTexture: any MTLTexture, gViewPosTexture: any MTLTexture) {
        let library = device.makeBundleDebugLibrary()!
        let downsampleFactor: Int
#if targetEnvironment(simulator)
        downsampleFactor = 1 // make larger for fast development on simulator 
#else
        downsampleFactor = 1
#endif
        let outTexture = RenderPassEncoderSettings.makeTexture(device: device, width: width / downsampleFactor, height: height / downsampleFactor, pixelFormat: pixelFormat, viewCount: gNormalTexture.arrayLength)

        let d = MTLRenderPipelineDescriptor()
        d.label = #file
        d.inputPrimitiveTopology = .triangle
        d.rasterSampleCount = 1
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")!
        d.fragmentFunction = library.makeFunction(name: "surface_light_fragment")!
        d.colorAttachments[0].pixelFormat = outTexture.pixelFormat
        // NOTE: blending is needed only for instancing light accumulations
//        d.colorAttachments[0].isBlendingEnabled = true
//        d.colorAttachments[0].rgbBlendOperation = .add
//        d.colorAttachments[0].sourceRGBBlendFactor = .one
//        d.colorAttachments[0].destinationRGBBlendFactor = .one
//        d.colorAttachments[0].alphaBlendOperation = .add
//        d.colorAttachments[0].sourceAlphaBlendFactor = .one
//        d.colorAttachments[0].destinationAlphaBlendFactor = .zero
        state = try! device.makeRenderPipelineState(descriptor: d)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.gViewPosTexture = gViewPosTexture
        self.gNormalTexture = gNormalTexture
        self.outTexture = outTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, uniforms: Uniforms, lightsBuffer: any MTLBuffer, lightsCount: Int) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)
        guard lightsCount > 0 else { return }

        var viewCount = outTexture.arrayLength
        encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

        [gViewPosTexture, gNormalTexture].enumerated().forEach { i, inTexture in
            encoder.setFragmentTexture(inTexture, index: i)
        }

        var uniforms: [SurfaceLightUniforms] = [
            SurfaceLightUniforms(viewCount: Int32(outTexture.arrayLength),
                                 lightCount: Int32(lightsCount),
                                 cameraFromProjectionTransform: uniforms.projection0Inverse,
                                 worldFromCameraTransform: uniforms.cameraTransformL,
                                 cameraFromWorldTransform: uniforms.cameraTransformL.inverse),
            SurfaceLightUniforms(viewCount: Int32(outTexture.arrayLength),
                                 lightCount: Int32(lightsCount),
                                 cameraFromProjectionTransform: uniforms.projection1Inverse,
                                 worldFromCameraTransform: uniforms.cameraTransformR,
                                 cameraFromWorldTransform: uniforms.cameraTransformR.inverse),
        ]
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SurfaceLightUniforms>.stride * 2, index: 0)
        encoder.setFragmentBuffer(lightsBuffer, offset: 0, index: 1)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)
    }
}
