import Metal
import RealityKit
import ARKit
import QuartzCore
import Observation
import MetalProjectionBridgingHeader

private extension simd_float4 {
    var xyz: simd_float3 {.init(x, y, z)}
}

extension VolumeSpotLight {
    init(cameraFromWorld: (simd_float4x4, simd_float4x4), position: simd_float3, direction: simd_float3, angleCos: Float, color: simd_float3, intensity: Float) {
        let angleSin = sqrt(max(0, 1 - angleCos * angleCos))
        let angleTan = angleSin / angleCos
        let lightLength: Float = 10
        let worldFromModelTransform = Transform(
            scale: .init(angleTan, 1, angleTan) * lightLength,
            rotation: .init(from: [0, -1, 0], to: direction),
            translation: position).matrix
        self.init(
            worldFromModelTransform: worldFromModelTransform,
            modelFromWorldTransform: worldFromModelTransform.inverse,
            position: position,
            positionInView: (.init((cameraFromWorld.0 * simd_float4(position, 1)).xyz),
                             .init((cameraFromWorld.1 * simd_float4(position, 1)).xyz)),
            direction: direction,
            directionInView: (.init((cameraFromWorld.0 * simd_float4(direction, 0)).xyz),
                              .init((cameraFromWorld.1 * simd_float4(direction, 0)).xyz)),
            angleCos: angleCos,
            color: color,
            intensity: intensity)
    }
}

@Observable
public final class MetalMap {
    private let commandQueue: MTLCommandQueue
    private let llTexture: LowLevelTexture // type2DArray, [left, right]
    public let textureResource: TextureResource // type2DArray, [left, right]
    private let uniformsTexture: LowLevelTexture
    private let uniformsMetalTexture: MTLTexture
    private let uniformsBuffer: any MTLBuffer
    public let uniformsTextureResource: TextureResource

    // scene -> post effects (bright, bloom) -> composite -> llTexture -> textureResource
    private let scenePass: ScenePassSetting
    private let brightPass: BrightPassSetting
    private let bloomPass: BloomPassSetting
    private let volumeLightPass: VolumeLightPassSetting
    private let surfaceLightPass: SurfaceLightPassSetting
    private let compositePass: CompositePassSetting

    public var isBloomEnabled: Bool = false
    public var isMainLightsEnabled: Bool = true
    public var isLineLights1Enabled: Bool = false
    public var isLineLights2Enabled: Bool = false
    public var isLineLights3Enabled: Bool = false
    public var volumeLightBaseIntensity: Float = 1
    public var surfaceLightBaseIntensity: Float = 10
    public var imageBasedLightTexture: (any MTLTexture)?

    private var arkitSession: ARKitSession? {
        didSet {oldValue?.stop()}
    }
    private var worldTracker: WorldTrackingProvider?

    private let debugLLTexture: LowLevelTexture
    private let debugMetalTexture: any MTLTexture
    public let debugTextureResource: TextureResource
    public var debugBlit: DebugBlit? = .rate
    public enum DebugBlit: String, Hashable, Identifiable, CaseIterable {
        case scene, normal, emissive, depth, bloom, volumeLight, surfaceLight, rate, composite
        public var id: String {rawValue}
    }
    private let copyPass: CopyPassSetting
    private let depthToColorPass: DepthToColorPassSetting

    private let rateMap: RateMap
    private let rateMapDecodeTexture: RateMapDecodeTexture?
    public var rateMapDecodeTextureResource: TextureResource? {rateMapDecodeTexture?.textureResource}

    public var dmxHolder: DMXHolder?

    @MainActor public init(device: MTLDevice = MTLCreateSystemDefaultDevice()!, pixelFormat: MTLPixelFormat = .rgba16Float, width: Int = 256, height: Int = 256, viewCount: Int = DeviceDependants.viewCount, rasterizationRateMap: (horizontal: [Float], vertical: [Float])? = nil) {
        commandQueue = device.makeCommandQueue()!
        commandQueue.label = String(describing: type(of: self))

        let rasterizationRateMapDescriptor = if let rasterizationRateMap { MTLRasterizationRateMapDescriptor(screenSize: .init(width: width, height: height, depth: 1), layers: [
                // assuming viewCount = 2
                MTLRasterizationRateLayerDescriptor(
                    horizontal: rasterizationRateMap.horizontal,
                    vertical: rasterizationRateMap.vertical,
                ),
                MTLRasterizationRateLayerDescriptor(
                    horizontal: rasterizationRateMap.horizontal.reversed(),
                    vertical: rasterizationRateMap.vertical,
                )
            ])
        } else { MTLRasterizationRateMapDescriptor?.none }

        // use physical size converted by rrm
        NSLog("%@", "logical size: \(width) x \(height)")
        let rateMap = RateMap(logicalWidth: width, height: height, device: device, descriptor: rasterizationRateMapDescriptor)
        self.rateMap = rateMap
        NSLog("%@", "physical size: \(rateMap.physical)")
#if DEBUG
        let llTextureUsage: MTLTextureUsage = [.renderTarget, .shaderRead] // .shaderRead is just for debug. not needed for production
#else
        let llTextureUsage: MTLTextureUsage = [.renderTarget]
#endif
        llTexture = try! LowLevelTexture(descriptor: .init(textureType: .type2DArray, pixelFormat: pixelFormat, width: rateMap.physical.width, height: rateMap.physical.height, arrayLength: viewCount, textureUsage: llTextureUsage)) // arrayLength: 2 for left/right eye
        textureResource = try! .init(from: llTexture)

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 5)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 4 for camera center, transformL, transformR, projection0, projection1.
        uniformsMetalTexture = uniformsTexture.read()
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 5)!

        scenePass = .init(rateMap: rateMap, pixelFormat: pixelFormat, viewCount: viewCount)
        brightPass = .init(rateMap: rateMap / 2, pixelFormat: pixelFormat, viewCount: viewCount)
        bloomPass = .init(rateMap: rateMap / 4, pixelFormat: pixelFormat, viewCount: viewCount)
        volumeLightPass = .init(device: device, width: rateMap.physical.width, height: rateMap.physical.height, pixelFormat: pixelFormat, depthTexture: scenePass.depthTexture, viewCount: viewCount)
        surfaceLightPass = .init(rateMap: rateMap, pixelFormat: pixelFormat, gAlbedoTexture: scenePass.outTexture, gNormalTexture: scenePass.gNormalTexture, gViewPosTexture: scenePass.gViewPosTexture, gORMTexture: scenePass.gORMTexture)
        compositePass = .init(rateMap: rateMap, outTexture: llTexture.read())

        debugLLTexture = try! LowLevelTexture(descriptor: .init(textureType: .type2DArray, pixelFormat: pixelFormat, width: rateMap.physical.width, height: rateMap.physical.height, arrayLength: viewCount, textureUsage: []))
        debugMetalTexture = debugLLTexture.read()
        debugTextureResource = try! .init(from: debugLLTexture)
        copyPass = .init(device: device, outTexture: debugMetalTexture)
        depthToColorPass = .init(device: device, outTexture: debugMetalTexture)

        rateMapDecodeTexture = rateMap.underlyingMap.map {_ in RateMapDecodeTexture(rateMap: rateMap)}
    }

    private var lastDraw: Date = .distantPast
    private var deviceAnchorHistory: [DeviceAnchor] = []

    @MainActor func draw(_ entities: [Entity]) {
        //        let now = Date()
        //        guard now.timeIntervalSince(lastDraw) > (1.0 / 90) else { return }
        //        lastDraw = now

        guard let worldTracker else {
            let arkitSession = ARKitSession()
            let worldTracker = WorldTrackingProvider()
            Task {try! await arkitSession.run([worldTracker])}
            self.arkitSession = arkitSession
            self.worldTracker = worldTracker
            return
        }
        guard let deviceAnchorPredicted = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime() + 0.010) else { return }
#if targetEnvironment(simulator)
        deviceAnchorHistory.append(deviceAnchorPredicted)
        let deviceAnchorTransform = deviceAnchorHistory.count < 8 ? deviceAnchorPredicted.originFromAnchorTransform : {
            let late = deviceAnchorHistory.removeFirst()
            var t = deviceAnchorPredicted.originFromAnchorTransform
            t.columns.3 = late.originFromAnchorTransform.columns.3
            return t
        }()
#else
        let deviceAnchorTransform = deviceAnchorPredicted.originFromAnchorTransform
#endif
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        let cameraTransformAndProjections = DeviceDependants.cameraTransformAndProjections(deviceAnchorTransform: deviceAnchorTransform)
        var uniforms = Uniforms(
            cameraTransformL: cameraTransformAndProjections.first!.transform,
            cameraTransformR: cameraTransformAndProjections.last!.transform,
            projection0: cameraTransformAndProjections.first!.projection,
            projection1: cameraTransformAndProjections.last!.projection,
            projection0Inverse: cameraTransformAndProjections.first!.projection.inverse,
            projection1Inverse: cameraTransformAndProjections.last!.projection.inverse,
        )

        let cameraFromWorld = (uniforms.cameraTransformL.inverse, uniforms.cameraTransformR.inverse)
        let dmx = dmxHolder?.dmx?.value
        func light(position: simd_float3, direction: simd_float3, angleCos: Float, color: simd_float3, intensity: Float, dmxStart: Int? = nil) -> VolumeSpotLight {
            var color = color
            var intensity = intensity
            var direction = direction
            if let dmx, let start = dmxStart {
                let s = start - 1 // start channel is 1-origin
                color = .init(SIMD3<UInt8>(dmx[s + 0], dmx[s + 1], dmx[s + 2])) / 255.0
                intensity *= .init(dmx[s + 3]) / 255.0
                // 4,5: pan, panFine
                // 6,7: tilt, tiltFine
                let pan = Float(UInt16(dmx[s + 4]) << 8 + UInt16(dmx[s + 5])) / 0xFFFF
                let tilt = Float(UInt16(dmx[s + 6]) << 8 + UInt16(dmx[s + 7])) / 0xFFFF
                let panRange = 3 * Float.pi
                let tiltRange = Float.pi
                direction = (
                    simd_quatf(angle: (pan - 0.5) * panRange, axis: [0,-1,0])
                    * simd_quatf(angle: tilt * tiltRange, axis: [-1,0,0])
                ).act([0, -1, 0])
                // -- stride = 8 --
            }
            return VolumeSpotLight(cameraFromWorld: cameraFromWorld, position: position, direction: direction, angleCos: angleCos, color: color, intensity: intensity)
            // TODO: compute view position in compute shader
        }

        let time: Float = Float(CACurrentMediaTime())
        let dmxStride = 8
        let mainLights: [VolumeSpotLight] = [
            light(position: .init(-1.0, 3, -1), direction: simd_quatf(angle: .pi / 6, axis: [0,0,1]).act([0, -1, 0]), angleCos: cos(.pi / 10), color: .init(0.25, 0.5, 1), intensity: 1, dmxStart: 1),
            light(position: .init(-0.5, 3, -1), direction: simd_quatf(angle: .pi / 8, axis: [0,0,1]).act([0.2 * cos(time), -1, 0.2 * sin(time)]), angleCos: cos(.pi / 10), color: .init(1, 0.25, 0.5), intensity: 1, dmxStart: 1 + dmxStride),
            light(position: .init(0, 3, -1), direction: simd_quatf(angle:  0, axis: [0,0,1]).act([0, -1, 0]), angleCos: cos(.pi / 10), color: .init(1, 1, 1), intensity: 0.8, dmxStart: 1 + dmxStride * 2),
            light(position: .init(0.5, 3, -1), direction: simd_quatf(angle:  -.pi / 8, axis: [0,0,1]).act([0.2 * cos(time), -1, 0.2 * -sin(time)]), angleCos: cos(.pi / 10), color: .init(0.25, 0.5, 1), intensity: 1, dmxStart: 1 + dmxStride * 3),
            light(position: .init(1.0, 3, -1), direction: simd_quatf(angle:  -.pi / 6, axis: [0,0,1]).act([0, -1, 0]), angleCos: cos(.pi / 10), color: .init(1, 0.25, 0.5), intensity: 1, dmxStart: 1 + dmxStride * 4),
        ]
        let lineLights1: [VolumeSpotLight] = (0..<32).map {
            let direction = simd_quatf(angle: time + 0.1 * Float($0), axis: [1, 0, 0]).act([0, -1, 0])
            return light(position: simd_float3((Float($0) - 15), 5, -5), direction: direction, angleCos: cos(.pi / 12), color: simd_float3(1, 1, 1), intensity: max(0, dot(direction, [0, -1, 0])), dmxStart: (mainLights.count + $0) * dmxStride + 1)
        }
        let lineLights2: [VolumeSpotLight] = (0..<32).map {
            let direction = simd_quatf(angle: time + 0.1 * Float($0), axis: [1, 0, 0]).act([0, -1, 0])
            return light(position: simd_float3((Float($0) - 15), 5, -10), direction: direction, angleCos: cos(.pi / 12), color: simd_float3(1, 1, 1), intensity: max(0, dot(direction, [0, -1, 0]))) // NOTE: up to 64 lights in 1 universe:, dmxStart: (mainLights.count + lineLights1.count + $0) * dmxStride + 1)
        }
        let lineLights3: [VolumeSpotLight] = (0..<32).map {
            let direction = simd_quatf(angle: time + 0.1 * Float($0), axis: [1, 0, 0]).act([0, -1, 0])
            return light(position: simd_float3((Float($0) - 15), 5, -15), direction: direction, angleCos: cos(.pi / 12), color: simd_float3(1, 1, 1), intensity: max(0, dot(direction, [0, -1, 0]))) // NOTE: up to 64 lights in 1 universe:, dmxStart: (mainLights.count + lineLights1.count + lineLights2.count + $0) * dmxStride + 1)
        }
        let lights: [VolumeSpotLight] = [
            isMainLightsEnabled ? mainLights : [],
            isLineLights1Enabled ? lineLights1 : [],
            isLineLights2Enabled ? lineLights2 : [],
            isLineLights3Enabled ? lineLights3 : [],
        ].flatMap(\.self)

        scenePass.encode(in: commandBuffer, cameraTransformAndProjections: cameraTransformAndProjections, entities: entities)
        let bloomOut: (any MTLTexture)? = isBloomEnabled ? {
            //            brightPass.encode(in: commandBuffer, inTexture: scenePass.gEmissiveTexture)
            return bloomPass.encode(in: commandBuffer, inTexture: scenePass.gEmissiveTexture)
        }() : nil
        volumeLightPass.encode(in: commandBuffer, uniforms: uniforms, lights: lights, intensity: volumeLightBaseIntensity)
        surfaceLightPass.encode(in: commandBuffer, uniforms: uniforms, lightsBuffer: volumeLightPass.lightsBuffer, lightsCount: lights.count, imageBasedLight: imageBasedLightTexture, intensity: surfaceLightBaseIntensity)
        compositePass.encode(in: commandBuffer, inTextures: [scenePass.gEmissiveTexture, bloomOut, volumeLightPass.outTexture, surfaceLightPass.outTexture])

        rateMapDecodeTexture?.drawIfNeeded(in: commandBuffer)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            defer {blit.endEncoding()}
            withUnsafeBytes(of: &uniforms) { u in
                uniformsBuffer.contents().copyMemory(from: u.baseAddress!, byteCount: MemoryLayout<Uniforms>.size)
            }
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 5, depth: 1), to: uniformsMetalTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }

        // copyPass.encode requires shaderRead, but blit does not require it
        func blitToDebugTexture(from: any MTLTexture) {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                defer {blit.endEncoding()}
                blit.copy(from: from, to: debugMetalTexture)
            }
        }
        switch debugBlit {
        case .none: break
        case .scene?: blitToDebugTexture(from: scenePass.outTexture)
        case .normal?: copyPass.encode(in: commandBuffer, inTexture: scenePass.gNormalTexture)
        case .emissive?: blitToDebugTexture(from: scenePass.gEmissiveTexture)
        case .depth?: depthToColorPass.encode(in: commandBuffer, inTexture: scenePass.depthTexture)
//        case .bright?: copyPass.encode(in: commandBuffer, inTexture: brightPass.outTexture)
        case .bloom?: if let bloomOut {copyPass.encode(in: commandBuffer, inTexture: bloomOut)}
        case .volumeLight?: blitToDebugTexture(from: volumeLightPass.outTexture)
        case .surfaceLight?: blitToDebugTexture(from: surfaceLightPass.outTexture)
        case .rate?: if let rateMapDecodeTexture {copyPass.encode(in: commandBuffer, inTexture: rateMapDecodeTexture.mtlTexture)}
        case .composite?: copyPass.encode(in: commandBuffer, inTexture: compositePass.outTexture)
        }
    }

    @MainActor public func setImageBasedLightTexture(_ texture: TextureResource?) throws {
        if let texture {
            if imageBasedLightTexture == nil {
                let imageBasedLightTexture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor: {
                    let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 128, mipmapped: true)
                    d.usage = [.shaderRead, .shaderWrite]
                    return d
                }())
                self.imageBasedLightTexture = imageBasedLightTexture
            }
            try texture.copy(to: imageBasedLightTexture!)
        } else {
            imageBasedLightTexture = nil
        }
    }
}
