import Metal

class CompositePassSetting {
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPassDescriptor
    let outTexture: any MTLTexture
    let rasterizationRateMapData: (any MTLBuffer)?

    init(device: any MTLDevice, outTexture: any MTLTexture, rasterizationRateMap: (any MTLRasterizationRateMap)?) {
        state = RenderPassEncoderSettings.makeRenderPipelineState(device: device, fragmentFunction: "composite_fragment", fragmentConstants: {
            let c = MTLFunctionConstantValues()
            var kUseVRS = rasterizationRateMap != nil
            c.setConstantValue(&kUseVRS, type: .bool, index: 0)
            return c
        }(), pixelFormat: outTexture.pixelFormat)
        descriptor = RenderPassEncoderSettings.renderPassDescriptor(texture: outTexture)
        self.outTexture = outTexture

        if let rasterizationRateMap, let rateMapData = device.makeBuffer(length: rasterizationRateMap.parameterDataSizeAndAlign.size, options: .storageModeShared) {
            rasterizationRateMap.copyParameterData(buffer: rateMapData, offset: 0)
            self.rasterizationRateMapData = rateMapData
        } else {
            self.rasterizationRateMapData = nil
        }
    }

    func encode(in commandBuffer: any MTLCommandBuffer, inTextures: [(any MTLTexture)?]) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = String(describing: type(of: self))
        defer {encoder.endEncoding()}
        encoder.setRenderPipelineState(state)

        var viewCount = outTexture.arrayLength
        encoder.setVertexBytes(&viewCount, length: MemoryLayout.stride(ofValue: viewCount), index: 1)

        var intensities: [Float] = [0, 0.25, 1, 1, 2]
        inTextures.enumerated().forEach { i, inTexture in
            if let inTexture {
                encoder.setFragmentTexture(inTexture, index: i)
            } else {
                intensities[i] = 0
            }
        }
        encoder.setFragmentBytes(&intensities, length: MemoryLayout<Float>.stride * intensities.count, index: 0)
        encoder.setFragmentBuffer(rasterizationRateMapData, offset: 0, index: 10)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: outTexture.arrayLength)
    }
}
