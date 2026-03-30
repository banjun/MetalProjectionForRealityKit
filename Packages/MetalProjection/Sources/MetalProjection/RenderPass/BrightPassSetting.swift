import Metal

class BrightPassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture

    convenience init(rateMap: RateMap, pixelFormat: MTLPixelFormat, viewCount: Int) {
        self.init(rateMap: rateMap,
                  outTexture: RenderPassEncoderSettings.makeTexture(device: rateMap.device, width: rateMap.physical.width, height: rateMap.physical.height, pixelFormat: pixelFormat, viewCount: viewCount))
    }
    init(rateMap: RateMap, outTexture: any MTLTexture) {
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: rateMap.device, fragmentFunction: "bright_fragment", pixelFormat: outTexture.pixelFormat)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.outTexture = outTexture
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inTexture: any MTLTexture) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        var viewCount = outTexture.arrayLength
        encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

        [inTexture].enumerated().forEach { i, inTexture in
            encoder.setFragmentTexture(inTexture, index: i)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)
    }
}
