import Metal

class BloomPassSetting {
    let state: MTLRenderPipelineState
    let descriptorAndOutTextures: [(MTLRenderPassDescriptor, any MTLTexture)] // for ping-pong, i.e. loop over in->0->1->0->1...and then the last tex is final output (depends on loop length)
    let kawaseBlurOffsets: [SIMD2<Float>]
    let rateMap: RateMap

    convenience init(rateMap: RateMap, pixelFormat: MTLPixelFormat, viewCount: Int) {
        self.init(outTextures: [
            RenderPassEncoderSettings.makeTexture(device: rateMap.device, width: rateMap.physical.width, height: rateMap.physical.height, pixelFormat: pixelFormat, viewCount: viewCount),
            RenderPassEncoderSettings.makeTexture(device: rateMap.device, width: rateMap.physical.width, height: rateMap.physical.height, pixelFormat: pixelFormat, viewCount: viewCount),
                  ],
                  rateMap: rateMap)
    }
    init(outTextures: [any MTLTexture], rateMap: RateMap) {
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: rateMap.device, fragmentFunction: "bloom_fragment", fragmentConstants: .bool(rateMap.data != nil), pixelFormat: outTextures[0].pixelFormat)
        descriptorAndOutTextures = outTextures.map {(RenderPassEncoderSettings.renderPassDescriptor(texture: $0), $0)}
        self.kawaseBlurOffsets = (0..<4)
            .map {40 * pow(1.5, Float($0))}
            .map {$0 * 2 / 1024 / 4 * Float(rateMap.logical.width / rateMap.physical.width) / .init(DeviceDependants.aspectRatio, 1)}
        self.rateMap = rateMap
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inTexture: any MTLTexture) -> any MTLTexture {
        var nextTexture = inTexture
        for (i, kawaseBlurOffset) in kawaseBlurOffsets.enumerated() {
            let (descriptor, outTexture) = descriptorAndOutTextures[i % descriptorAndOutTextures.count]
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = String(describing: type(of: self))
            defer {encoder.endEncoding()}
            encoder.setRenderPipelineState(state)
            encoder.setFragmentRasterizationRateMapData(rateMap: rateMap, index: 10)

            var viewCount = outTexture.arrayLength
            encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

            var kawaseOffset = kawaseBlurOffset
            encoder.setFragmentBytes(&kawaseOffset, length: MemoryLayout.stride(ofValue: kawaseOffset), index: 0)

            [nextTexture].enumerated().forEach { i, t in
                encoder.setFragmentTexture(t, index: i)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)

            nextTexture = outTexture
        }
        return nextTexture
    }
}
