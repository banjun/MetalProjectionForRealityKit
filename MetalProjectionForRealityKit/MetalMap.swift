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
        var uniforms = Uniforms(
            cameraTransform: deviceAnchor.originFromAnchorTransform,
            projectionCount: 1,
            projection0: simd_float4x4([
                [1.0, 0.0, 0.0, 0.0],
                [0.0, 1.7777778, 0.0, 0.0],
                [0.0, 0.0, 0.0, -1.0],
                [0.0, 0.0, 0.1, 0.0]
            ]),
            projection1: .init(diagonal: [1,1,1,1]))

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
                var p = uniformsBuffer.contents()
                p.copyMemory(from: u.baseAddress!.advanced(by: MemoryLayout<Uniforms>.offset(of: \.cameraTransform)!), byteCount: MemoryLayout<simd_float4x4>.size)
                p += MemoryLayout<simd_float4x4>.size
                p.copyMemory(from: u.baseAddress!.advanced(by: MemoryLayout<Uniforms>.offset(of: \.projection0)!), byteCount: MemoryLayout<simd_float4x4>.size)
                p += MemoryLayout<simd_float4x4>.size
                p.copyMemory(from: u.baseAddress!.advanced(by: MemoryLayout<Uniforms>.offset(of: \.projection1)!), byteCount: MemoryLayout<simd_float4x4>.size)
            }
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 3, depth: 1), to: uniformsTexture.replace(using: commandBuffer), destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
    }
}


