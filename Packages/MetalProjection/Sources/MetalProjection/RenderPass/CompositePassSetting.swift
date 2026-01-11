import Metal

class CompositePassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture

    init(device: any MTLDevice, outTexture: any MTLTexture) {
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: device, fragmentFunction: "composite_fragment", pixelFormat: outTexture.pixelFormat)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.outTexture = outTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inTextures: [(any MTLTexture)?]) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        var viewCount = outTexture.arrayLength
        encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

        var intensities: [Float] = [0, 0.25, 1, 2]
        inTextures.enumerated().forEach { i, inTexture in
            if let inTexture {
                encoder.setFragmentTexture(inTexture, index: i)
            } else {
                intensities[i] = 0
            }
        }
        encoder.setFragmentBytes(&intensities, length: MemoryLayout<Float>.stride * intensities.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)
    }
}
