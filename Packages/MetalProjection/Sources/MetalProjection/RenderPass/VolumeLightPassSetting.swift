import Metal
import MetalProjectionBridgingHeader

class VolumeLightPassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture

    convenience init(device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, viewCount: Int) {
        self.init(device: device,
                  outTexture: RenderPassEncoderSettings.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat, viewCount: viewCount))
    }
    init(device: any MTLDevice, outTexture: any MTLTexture) {
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: device, fragmentFunction: "volumeLight_fragment", pixelFormat: outTexture.pixelFormat)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.outTexture = outTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inDepthTexture: any MTLTexture, uniforms: Uniforms, lights: [VolumeSpotLight]) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        [inDepthTexture].enumerated().forEach { i, inDepthTexture in
            encoder.setFragmentTexture(inDepthTexture, index: i)
        }
        var uniforms = uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout.stride(ofValue: uniforms), index: 0)
        var lights = lights
        var lightCounts = lights.count
        encoder.setFragmentBytes(&lights, length: MemoryLayout<VolumeSpotLight>.stride * lightCounts, index: 1)
        encoder.setFragmentBytes(&lightCounts, length: MemoryLayout.stride(ofValue: lightCounts), index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)
    }
}
