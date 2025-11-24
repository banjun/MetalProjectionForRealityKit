import Metal
import RealityKit
import ARKit
import QuartzCore
import Observation

@Observable
final class MetalMap {
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let commandQueue: MTLCommandQueue
    private let llTexture: LowLevelTexture // type2DArray, [left, right]
    private let metalTexture: MTLTexture // type2DArray, [left, right]
    let textureResource: TextureResource // type2DArray, [left, right]
    private let vertexIndex: Int
    private let vertexUniformsIndex: Int
    private let fragmentUniformsIndex: Int

    private let uniformsTexture: LowLevelTexture
    private let uniformsMetalTexture: MTLTexture
    private let uniformsBuffer: any MTLBuffer
    let uniformsTextureResource: TextureResource

    let pixelFormat: MTLPixelFormat = .rgba16Float

    var llMesh: LowLevelMesh? {
        didSet {
            createRenderPipelineState()
        }
    }
    private var renderPipelineState: MTLRenderPipelineState?

    // see also: https://stackoverflow.com/questions/78664948/exactly-where-is-worldtrackingprovider-querydeviceanchor-attached-in-visionos?utm_source=chatgpt.com
    struct DeviceAnchorCameraTransformShift {
        var left: SIMD3<Float>
        var right: SIMD3<Float>
        // ipd: it maybe be distance between hardware cameras
        // sfhitY, shiftZ: derived from my experimentations. should be refined.
        init(ipd: Float = 0.064, shiftY: Float = -0.0261, shiftZ: Float = -0.0212) {
            left = .init(-ipd / 2, shiftY, shiftZ)
            right =  .init(ipd / 2, shiftY, shiftZ)
        }
    }

#if targetEnvironment(simulator)
    var deviceAnchorCameraTransformShift: DeviceAnchorCameraTransformShift = .init(ipd: 0, shiftY: 0, shiftZ: 0)
#else
    var deviceAnchorCameraTransformShift: DeviceAnchorCameraTransformShift = .init()
#endif

    private var arkitSession: ARKitSession? {
        didSet {oldValue?.stop()}
    }
    private var worldTracker: WorldTrackingProvider?

    init(width: Int = 32, height: Int = 32, vertexIndex: Int = 0, vertexUniformsIndex: Int = 1, fragmentUniformsIndex: Int = 2) {
        commandQueue = device.makeCommandQueue()!
        llTexture = try! LowLevelTexture(descriptor: .init(textureType: .type2DArray, pixelFormat: pixelFormat, width: width, height: height, arrayLength: 2)) // arrayLength: 2 for left/right eye
        metalTexture = llTexture.read()
        textureResource = try! .init(from: llTexture)

        self.vertexIndex = vertexIndex
        self.vertexUniformsIndex = vertexUniformsIndex
        self.fragmentUniformsIndex = fragmentUniformsIndex

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 5)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 4 for camera center, transformL, transformR, projection0, projection1.
        uniformsMetalTexture = uniformsTexture.read()
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 5)!
    }

    private func createRenderPipelineState() {
        guard let descriptor = llMesh?.descriptor else {
            renderPipelineState = nil
            return
        }
        let render_vertex = device.makeDefaultLibrary()!.makeFunction(name: "render_vertex")!
        let render_fragment = device.makeDefaultLibrary()!.makeFunction(name: "render_fragment")!

        renderPipelineState = try! device.makeRenderPipelineState(descriptor: {
            let d = MTLRenderPipelineDescriptor()
            d.inputPrimitiveTopology = .triangle
            d.rasterSampleCount = 1
            d.vertexFunction = render_vertex
            d.vertexDescriptor = .init()
            descriptor.vertexLayouts.enumerated().forEach { i, l in
                d.vertexDescriptor!.layouts[i]!.stride = l.bufferStride
            }
            let vertexAttributes: [LowLevelMesh.Attribute] = descriptor.vertexAttributes
            vertexAttributes.enumerated().forEach { i, a in
                d.vertexDescriptor!.attributes[i]!.format = a.format
                d.vertexDescriptor!.attributes[i]!.offset = a.offset
                d.vertexDescriptor!.attributes[i]!.bufferIndex = a.layoutIndex
            }
            d.fragmentFunction = render_fragment
            d.colorAttachments[0].pixelFormat = pixelFormat
            return d
        }())
    }

    func draw() {
        guard let worldTracker else {
            let arkitSession = ARKitSession()
            let worldTracker = WorldTrackingProvider()
            Task {try! await arkitSession.run([worldTracker])}
            self.arkitSession = arkitSession
            self.worldTracker = worldTracker
            return
        }
        guard let deviceAnchor = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime() + 0.01) else { return }
        // using hard coded value, because we cannot get at runtime, as the only way to get them is from CompsitorLayer Drawable that cannot run simultaneously with ImmersiveView with RealityView.
#if targetEnvironment(simulator)
        let projection0 = simd_float4x4([
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.7777778, 0.0, 0.0],
            [0.0, 0.0, 0.0, -1.0],
            [0.0, 0.0, 0.1, 0.0],
        ])
        let projection1 = projection0
#else
        let projection0 = simd_float4x4([
            [0.70956117, 2.7048769e-05, 0.0, 0.00025395412],
            [1.6707818e-06, 0.8844015, 0.0, 6.786168e-06],
            [-0.26731065, -0.08808379, 0.0, -1.0000936],
            [0.0, 0.0, 0.09691928, 0.0],
        ])
        let projection1 = simd_float4x4([
            [0.70965976, -1.7333849e-05, 0.0, -0.00025292352],
            [2.0678665e-06, 0.8845193, 0.0, -8.016048e-06],
            [0.2677407, -0.086908735, 0.0, -1.0000918],
            [0.0, 0.0, 0.09693231, 0.0],
        ])
#endif
        let cameraTransform = deviceAnchor.originFromAnchorTransform
        let cameraRight4 = normalize(SIMD4<Float>(cameraTransform.columns.0.x,
                                                  cameraTransform.columns.0.y,
                                                  cameraTransform.columns.0.z,
                                                  0))
        let cameraUp4 = normalize(SIMD4<Float>(cameraTransform.columns.1.x,
                                               cameraTransform.columns.1.y,
                                               cameraTransform.columns.1.z,
                                               0))
        let cameraForward4 = normalize(SIMD4<Float>(cameraTransform.columns.2.x,
                                                    cameraTransform.columns.2.y,
                                                    cameraTransform.columns.2.z,
                                                    0))
        var cameraTransformL = cameraTransform
        var cameraTransformR = cameraTransform
        let shiftForL = deviceAnchorCameraTransformShift.left
        let shiftForR = deviceAnchorCameraTransformShift.right
        cameraTransformL.columns.3 += cameraRight4 * shiftForL.x + cameraUp4 * shiftForL.y + cameraForward4 * shiftForL.z
        cameraTransformR.columns.3 += cameraRight4 * shiftForR.x + cameraUp4 * shiftForR.y + cameraForward4 * shiftForR.z
        var uniforms = Uniforms(
            cameraTransform: cameraTransform,
            cameraTransformL: cameraTransformL,
            cameraTransformR: cameraTransformR,
            projection0: projection0,
            projection1: projection1,
            projection0Inverse: projection0.inverse,
            projection1Inverse: projection1.inverse,
        )
        var vertexUniforms: [VertexUniforms] = [
            .init(cameraTransform: cameraTransformL,
                  cameraTransformInverse: cameraTransformL.inverse,
                  projection: projection0,
                  projectionInverse: projection0.inverse,
                 ),
        ]
//#if targetEnvironment(simulator)
//#else
        vertexUniforms.append(
            .init(cameraTransform: cameraTransformR,
                  cameraTransformInverse: cameraTransformR.inverse,
                  projection: projection1,
                  projectionInverse: projection1.inverse,
                 ),
        )
//#endif
        let viewCount = vertexUniforms.count
        var fragmentUniforms: FragmentUniforms = .init(textureSize: .init(Int32(metalTexture.width), Int32(metalTexture.height)))

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        if let llMesh, let renderPipelineState, let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
            let d = MTLRenderPassDescriptor()
            d.renderTargetArrayLength = metalTexture.arrayLength
            d.colorAttachments[0]?.texture = metalTexture
            d.colorAttachments[0]?.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            d.colorAttachments[0]?.loadAction = .clear
            d.colorAttachments[0]?.storeAction = .store
            return d
        }()) {
            defer {renderEncoder.endEncoding()}
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: vertexIndex)
            renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride * vertexUniforms.count, index: vertexUniformsIndex)
            renderEncoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: fragmentUniformsIndex)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: llMesh.parts.reduce(into: 0) {$0 += $1.indexCount}, indexType: .uint32, indexBuffer: llMesh.readIndices(using: commandBuffer), indexBufferOffset: 0, instanceCount: viewCount) // instanceCount: 2 for left/right projection (view id)
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            defer {blit.endEncoding()}
            withUnsafeBytes(of: &uniforms) { u in
                uniformsBuffer.contents().copyMemory(from: u.baseAddress!, byteCount: MemoryLayout<Uniforms>.size)
            }
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 5, depth: 1), to: uniformsMetalTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
    }
}


