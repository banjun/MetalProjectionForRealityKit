import Metal

struct RateMap {
    let logical: MTLSize // screen size
    let physical: MTLSize // texture size
    let device: any MTLDevice
    let descriptor: MTLRasterizationRateMapDescriptor?
    let underlyingMap: (any MTLRasterizationRateMap)? // for setting render pass descriptor
    let data: (any MTLBuffer)?
}
extension RateMap {
    init(logicalWidth width: Int, height: Int, device : any MTLDevice, descriptor: MTLRasterizationRateMapDescriptor?) {
        let logical = MTLSize(width: width, height: height, depth: 1)
        let rasterizationRateMap: (any MTLRasterizationRateMap)? = if let descriptor, device.supportsRasterizationRateMap(layerCount: descriptor.layerCount) { device.makeRasterizationRateMap(descriptor: descriptor) } else { nil }
        self.init(
            logical: logical,
            physical: rasterizationRateMap?.physicalSize(layer: 0) ?? logical,
            device: device,
            descriptor: descriptor,
            underlyingMap: rasterizationRateMap,
            data: rasterizationRateMap.flatMap { map in
                guard let buffer = device.makeBuffer(length: map.parameterDataSizeAndAlign.size, options: .storageModeShared) else { return nil }
                map.copyParameterData(buffer: buffer, offset: 0)
                return buffer
            })
    }
}

func / (lhs: RateMap, rhs: Int) -> RateMap {
    let logical = MTLSize(width: lhs.logical.width / rhs, height: lhs.logical.height / rhs, depth: lhs.logical.depth)
    let descriptor = lhs.descriptor.flatMap { descriptor in
        MTLRasterizationRateMapDescriptor(screenSize: logical, layers: (0..<descriptor.layerCount).map {descriptor.layer(at: $0)!})
    }
    return RateMap(logicalWidth: logical.width, height: logical.height, device: lhs.device, descriptor: descriptor)
}

extension MTLRenderCommandEncoder {
    /// for extending rate map texture
    func setFragmentRasterizationRateMapData(rateMap: RateMap, index: Int) {
        setFragmentBuffer(rateMap.data, offset: 0, index: index)
    }
}
