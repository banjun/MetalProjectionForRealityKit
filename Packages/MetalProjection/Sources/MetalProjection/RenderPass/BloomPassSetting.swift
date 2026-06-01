import Metal

class BloomPassSetting {
    let state: MTLRenderPipelineState
    let descriptorAndOutTextures: [(MTLRenderPassDescriptor, any MTLTexture)] // for ping-pong, i.e. loop over in->0->1->0->1...and then the last tex is final output (depends on loop length)
    var kawaseBlurOffsets: [SIMD2<Float>] = []
    var kawaseBlurSteps: Int = 4 {
        didSet {recalculateOffsets()}
    }
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
        self.rateMap = rateMap
        recalculateOffsets()
    }

    func recalculateOffsets() {
        guard kawaseBlurOffsets.count != kawaseBlurSteps else { return }
        self.kawaseBlurOffsets = (0..<kawaseBlurSteps)
            .map {40 * pow(1.5, Float($0))}
            .map {$0 * 8 / SIMD2<Float>(Float(rateMap.physical.width), Float(rateMap.physical.height))}
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inTexture: any MTLTexture, inTextureRateMap: RateMap, intensity: Float = 0.5, spread: Float = 1.0, steps: Int = 4) -> any MTLTexture {
        kawaseBlurSteps = steps
        var nextTexture = inTexture
        var nextRateMap = inTextureRateMap
        for (i, kawaseBlurOffset) in kawaseBlurOffsets.enumerated() {
            let (descriptor, outTexture) = descriptorAndOutTextures[i % descriptorAndOutTextures.count]
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = String(describing: type(of: self))
            defer {encoder.endEncoding()}
            encoder.setRenderPipelineState(state)
            encoder.setFragmentRasterizationRateMapData(rateMap: nextRateMap, index: 10)

            var viewCount = outTexture.arrayLength
            encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

            var kawaseOffset = kawaseBlurOffset
            encoder.setFragmentBytes(&kawaseOffset, length: MemoryLayout.stride(ofValue: kawaseOffset), index: 0)
            var intensity = intensity
            encoder.setFragmentBytes(&intensity, length: MemoryLayout.stride(ofValue: intensity), index: 1)
            var spread = spread
            encoder.setFragmentBytes(&spread, length: MemoryLayout.stride(ofValue: spread), index: 2)

            [nextTexture].enumerated().forEach { i, t in
                encoder.setFragmentTexture(t, index: i)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)

            nextTexture = outTexture
            nextRateMap = rateMap
        }
        return nextTexture
    }
}
