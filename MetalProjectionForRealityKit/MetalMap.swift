import Metal
import RealityKit
import ARKit
import QuartzCore

final class MetalMap {
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let commandQueue: MTLCommandQueue
    private let llTexture: LowLevelTexture
    let textureResource: TextureResource
    private let computePipelineState: MTLComputePipelineState
    private let threadGroupsPerGrid: MTLSize
    private let threadsPerThreadgroup: MTLSize
    private let outTextureIndex: Int
    private let uniformsIndex: Int

    private let uniformsTexture: LowLevelTexture
    private let uniformsBuffer: any MTLBuffer
    let uniformsTextureResource: TextureResource

    private var arkitSession: ARKitSession? {
        didSet {oldValue?.stop()}
    }
    private var worldTracker: WorldTrackingProvider?

    init(width: Int = 32, height: Int = 32, kernelName: String = "draw", outTextureIndex: Int = 0, uniformsIndex: Int = 1) {
        commandQueue = device.makeCommandQueue()!
        let function = device.makeDefaultLibrary()!.makeFunction(name: kernelName)!
        computePipelineState = try! device.makeComputePipelineState(function: function)
        llTexture =  try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height))
        textureResource = try! .init(from: llTexture)

        let threadWidth = computePipelineState.threadExecutionWidth
        let maxThreads = computePipelineState.maxTotalThreadsPerThreadgroup
        threadsPerThreadgroup = .init(width: threadWidth, height: maxThreads / threadWidth, depth: 1)
        threadGroupsPerGrid = .init(
            width: (width + threadWidth - 1) / threadsPerThreadgroup.width,
            height: (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1)
        self.outTextureIndex = outTextureIndex
        self.uniformsIndex = uniformsIndex

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 3)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 3 forcamera transform, projection0, projection1.
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 3)!
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
        guard let deviceAnchor = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }
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
            [0.7315394, 3.9901988e-07, 0.0, 3.1312097e-06],
            [2.0127231e-07, 0.91187435, 0.0, 9.520301e-07],
            [-0.26791388, -0.08751587, 0.0, -1.0000012],
            [0.0, 0.0, 0.09993004, 0.0]
        ])
        let projection1 = simd_float4x4([
            [0.73168945, -1.0521787e-07, 0.0, -2.2248819e-06],
            [1.8116259e-07, 0.9120613, 0.0, -6.887392e-07],
            [0.26794675, -0.0874681, 0.0, -1.0000007],
            [0.0, 0.0, 0.09995053, 0.0]
        ])
#endif
        var uniforms = Uniforms(
            cameraTransform: deviceAnchor.originFromAnchorTransform,
            projection0: projection0,
            projection1: projection1)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            defer {computeEncoder.endEncoding()}
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setTexture(llTexture.replace(using: commandBuffer), index: outTextureIndex)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: uniformsIndex)
            computeEncoder.dispatchThreadgroups(threadGroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            defer {blit.endEncoding()}
            withUnsafeBytes(of: &uniforms) { u in
                uniformsBuffer.contents().copyMemory(from: u.baseAddress!, byteCount: MemoryLayout<Uniforms>.size)
            }
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 3, depth: 1), to: uniformsTexture.replace(using: commandBuffer), destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
    }
}


