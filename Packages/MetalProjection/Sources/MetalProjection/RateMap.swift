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
        MTLRasterizationRateMapDescriptor(screenSize: logical, layers: (0..<descriptor.layerCount).map {
            let layer = descriptor.layer(at: $0)!
            return .init(horizontal: (0..<layer.sampleCount.width).map {layer.horizontal[$0]},
                         vertical: (0..<layer.sampleCount.height).map {layer.vertical[$0]})
        })
    }
    return RateMap(logicalWidth: logical.width, height: logical.height, device: lhs.device, descriptor: descriptor)
}

extension MTLRenderCommandEncoder {
    /// for extending rate map texture
    func setFragmentRasterizationRateMapData(rateMap: RateMap, index: Int) {
        setFragmentBuffer(rateMap.data, offset: 0, index: index)
    }
}


import RealityKit

class RateMapDecodeTexture {
    var rateMap: RateMap {didSet {needsDraw = true}}
    private let llTexture: LowLevelTexture
    let mtlTexture: any MTLTexture
    let textureResource: TextureResource
    var needsDraw = true
    @MainActor init(rateMap: RateMap, width: Int = 128, height: Int = 128) {
        self.rateMap = rateMap
        llTexture = try! LowLevelTexture(descriptor: .init(textureType: .type2DArray, pixelFormat: .rgba16Float, width: width, height: height, arrayLength: rateMap.underlyingMap?.layerCount ?? 1, textureUsage: [.shaderRead, .shaderWrite]))
        mtlTexture = llTexture.read()
        textureResource = try! TextureResource(from: llTexture)
    }
    @MainActor func drawIfNeeded(in commandBuffer: any MTLCommandBuffer) {
        guard needsDraw, let map = rateMap.underlyingMap else { return }
        needsDraw = false

        let width = llTexture.descriptor.width
        let height = llTexture.descriptor.height
        let bytesPerComponents: Int
        let componentsPerPixel: Int
        switch llTexture.descriptor.pixelFormat {
        case .rg16Float:
            bytesPerComponents = 2
            componentsPerPixel = 2
        case .rgba16Float: // for debug use (only use RG, BA not in use)
            bytesPerComponents = 2
            componentsPerPixel = 4
        default:
            fatalError()
        }
        let bytesPerPixel = bytesPerComponents * componentsPerPixel
        let bytesPerImage = bytesPerPixel * width * height
        var components: [Float16] = .init(repeating: 0, count: width * height * componentsPerPixel)

        for layer in 0..<(rateMap.descriptor?.layerCount ?? 1) {
            for y in 0..<height {
                for x in 0..<width {
                    let uv = SIMD2(Float(x), Float(y)) / SIMD2(Float(width - 1), Float(height - 1))
                    let screenPixel = uv * SIMD2(Float(rateMap.logical.width), Float(rateMap.logical.height))

                    let physicalPixel = map.physicalCoordinates(screenCoordinates: .init(x: screenPixel.x, y: screenPixel.y), layer: layer)

                    let i = (y * width + x) * componentsPerPixel
                    components[i + 0] = Float16(physicalPixel.x / Float(rateMap.physical.width))
                    components[i + 1] = Float16(physicalPixel.y / Float(rateMap.physical.height))
                    if componentsPerPixel == 4 {
                        // debug values
                        components[i + 2] = 0
                        components[i + 3] = 1
                    }
                }
            }

            if let blit = commandBuffer.makeBlitCommandEncoder() {
                defer {blit.endEncoding()}
                let buffer = commandBuffer.device.makeBuffer(bytes: &components, length: bytesPerImage)!
                blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: width * bytesPerPixel, sourceBytesPerImage: width * height * bytesPerPixel, sourceSize: MTLSize(width: width, height: height, depth: 1), to: mtlTexture, destinationSlice: layer, destinationLevel: 0, destinationOrigin: .init())
            }
        }
    }
}
