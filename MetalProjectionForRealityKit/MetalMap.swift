import Metal
import RealityKit
import ARKit
import QuartzCore

final class MetalMap {
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let commandQueue: MTLCommandQueue
    private let llTexture0: LowLevelTexture
    private let llTexture1: LowLevelTexture
    let textureResource0: TextureResource
    let textureResource1: TextureResource
    private let computePipelineState: MTLComputePipelineState
    private let threadGroupsPerGrid: MTLSize
    private let threadsPerThreadgroup: MTLSize
    private let outTexture0Index: Int
    private let outTexture1Index: Int
    private let uniformsIndex: Int
    private let verticesIndex: Int
    private let indicesIndex: Int
    private let indicesCountIndex: Int

    private let uniformsTexture: LowLevelTexture
    private let uniformsBuffer: any MTLBuffer
    let uniformsTextureResource: TextureResource

    private let llMesh: LowLevelMesh
    let meshResource: MeshResource
    struct Vertex {
        var position: SIMD3<Float>

        static var vertexAttributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Self>.offset(of: \.position)!),
        ]
        static var vertexLayouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<Self>.stride)
        ]
        static var descriptor: LowLevelMesh.Descriptor {
            var desc = LowLevelMesh.Descriptor()
            desc.vertexAttributes = Vertex.vertexAttributes
            desc.vertexLayouts = Vertex.vertexLayouts
            desc.indexType = .uint32
            desc.vertexCapacity = 10000
            desc.indexCapacity = 10000
            return desc
        }
    }

    private var arkitSession: ARKitSession? {
        didSet {oldValue?.stop()}
    }
    private var worldTracker: WorldTrackingProvider?

    init(width: Int = 32, height: Int = 32, kernelName: String = "draw", outTexture0Index: Int = 0, outTexture1Index: Int = 1, uniformsIndex: Int = 0, verticesIndex: Int = 1, indicesIndex: Int = 2, indicesCountIndex: Int = 3) {
        commandQueue = device.makeCommandQueue()!
        let function = device.makeDefaultLibrary()!.makeFunction(name: kernelName)!
        computePipelineState = try! device.makeComputePipelineState(function: function)
        llTexture0 = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height))
        llTexture1 = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height))
        textureResource0 = try! .init(from: llTexture0)
        textureResource1 = try! .init(from: llTexture1)

        let threadWidth = computePipelineState.threadExecutionWidth
        let maxThreads = computePipelineState.maxTotalThreadsPerThreadgroup
        threadsPerThreadgroup = .init(width: threadWidth, height: maxThreads / threadWidth, depth: 1)
        threadGroupsPerGrid = .init(
            width: (width + threadWidth - 1) / threadsPerThreadgroup.width,
            height: (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1)
        self.outTexture0Index = outTexture0Index
        self.outTexture1Index = outTexture1Index
        self.uniformsIndex = uniformsIndex
        self.verticesIndex = verticesIndex
        self.indicesIndex = indicesIndex
        self.indicesCountIndex = indicesCountIndex

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 3)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 3 forcamera transform, projection0, projection1.
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 3)!

        llMesh = try! LowLevelMesh(descriptor: Vertex.descriptor)
        meshResource = try! MeshResource(from: llMesh)

        let meshVertices: [Vertex] = {
            let lbf: SIMD3<Float> = [-1, -1, +1]
            let rbf: SIMD3<Float> = [+1, -1, +1]
            let ltf: SIMD3<Float> = [-1, +1, +1]
            let rtf: SIMD3<Float> = [+1, +1, +1]
            let lbb: SIMD3<Float> = [-1, -1, -1]
            let rbb: SIMD3<Float> = [+1, -1, -1]
            let ltb: SIMD3<Float> = [-1, +1, -1]
            let rtb: SIMD3<Float> = [+1, +1, -1]
            return [
                lbf, rbf, rtf,
                lbf, rtf, ltf,
                lbf, ltf, ltb,
                lbf, ltb, lbb,
                rbf, rbb, rtb,
                rbf, rtb, rtf,
                ltf, rtf, rtb,
                ltf, rtb, ltb,
                lbf, rbb, rbf,
                lbf, lbb, rbb,
                lbb, rtb, rbb,
                lbb, ltb, rtb,
            ].map {Vertex(position: $0 * 0.25 + SIMD3<Float>(0.5, 1.25, -1.25))}
        }()
        let meshIndices: [UInt32] = Array(0..<UInt32(meshVertices.count))
        llMesh.withUnsafeMutableBytes(bufferIndex: 0) {
            let p = $0.bindMemory(to: Vertex.self)
            meshVertices.enumerated().forEach {
                p[$0.offset] = $0.element
            }
        }
        llMesh.withUnsafeMutableIndices {
            let p = $0.bindMemory(to: UInt32.self)
            meshIndices.forEach {
                p[Int($0)] = $0
            }
        }
        llMesh.parts.replaceAll([
            .init(indexCount: meshIndices.count,
                  topology: .triangle,
                  bounds: .init(min: .init(meshVertices.map(\.position.x).min()!,
                                           meshVertices.map(\.position.y).min()!,
                                           meshVertices.map(\.position.z).min()!),
                                max: .init(meshVertices.map(\.position.x).max()!,
                                           meshVertices.map(\.position.y).max()!,
                                           meshVertices.map(\.position.z).max()!)))
        ])
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
            projection0
            : projection0,
            projection1: projection1,
            projection0Inverse: projection0.inverse,
            projection1Inverse: projection1.inverse,
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            defer {computeEncoder.endEncoding()}
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setTexture(llTexture0.replace(using: commandBuffer), index: outTexture0Index)
            computeEncoder.setTexture(llTexture1.replace(using: commandBuffer), index: outTexture1Index)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: uniformsIndex)
            computeEncoder.setBuffer(llMesh.read(bufferIndex: 0, using: commandBuffer), offset: 0, index: verticesIndex)
            let indices = llMesh.readIndices(using: commandBuffer)
            var indicesCount = llMesh.parts.reduce(into: 0) {$0 += $1.indexCount}
            computeEncoder.setBuffer(indices, offset: 0, index: indicesIndex)
            computeEncoder.setBytes(&indicesCount, length: MemoryLayout<Int>.size, index: indicesCountIndex)
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


