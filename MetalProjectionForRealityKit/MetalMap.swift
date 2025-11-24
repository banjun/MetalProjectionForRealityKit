import Metal
import RealityKit
import ARKit
import QuartzCore
import Observation

@Observable
final class MetalMap {
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let commandQueue: MTLCommandQueue
    private let llTexture0: LowLevelTexture
    private let llTexture1: LowLevelTexture
    private let metalTexture0: MTLTexture
    private let metalTexture1: MTLTexture
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
    private let uniformsMetalTexture: MTLTexture
    private let uniformsBuffer: any MTLBuffer
    let uniformsTextureResource: TextureResource

    private let llMesh: LowLevelMesh
    let meshResource: MeshResource
    struct Vertex {
        var position: SIMD3<Float>
        var mask: UInt32

        static var vertexAttributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Self>.offset(of: \.position)!),
            //            .init(semantic: .unspecified, format: .uint, offset: MemoryLayout<Self>.offset(of: \.mask)!), // NOTE: specifying unspecified attribute cause Direct Mesh Validation error on init
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

    init(width: Int = 32, height: Int = 32, kernelName: String = "draw", outTexture0Index: Int = 0, outTexture1Index: Int = 1, uniformsIndex: Int = 0, verticesIndex: Int = 1, indicesIndex: Int = 2, indicesCountIndex: Int = 3) {
        commandQueue = device.makeCommandQueue()!
        let function = device.makeDefaultLibrary()!.makeFunction(name: kernelName)!
        computePipelineState = try! device.makeComputePipelineState(function: function)
        llTexture0 = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height))
        llTexture1 = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height))
        metalTexture0 = llTexture0.read()
        metalTexture1 = llTexture1.read()
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

        uniformsTexture = try! LowLevelTexture(descriptor: .init(pixelFormat: .rgba32Float, width: 4, height: 5)) // rgba for 1 row of simd_float4x4, total simd_float4x4 is rgba x 4, thus width = 4, and height 4 for camera center, transformL, transformR, projection0, projection1.
        uniformsMetalTexture = uniformsTexture.read()
        uniformsTextureResource = try! .init(from: uniformsTexture)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.size * 5)!

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
            return [lbf, rbf, ltf, rtf, lbb, rbb, ltb, rtb]
                .map {Vertex(position: $0 * SIMD3<Float>(0.125, 0.125, 0.030) + SIMD3<Float>(0.5, 1.25, -0.55),
                             mask: ($0.z == Float(-1)) ? 1 : 0)} // mask=1: sink
        }()
        let meshIndices: [UInt32] = [
            0, 1, 3,
            0, 3, 2,
            0, 2, 6,
            0, 6, 4,
            1, 5, 7,
            1, 7, 3,
            2, 3, 7,
            2, 7, 6,
            0, 5, 1,
            0, 4, 5,
            4, 7, 5,
            4, 6, 7,
        ]
        llMesh.withUnsafeMutableBytes(bufferIndex: 0) {
            let p = $0.bindMemory(to: Vertex.self)
            meshVertices.enumerated().forEach {
                p[$0.offset] = $0.element
            }
        }
        llMesh.withUnsafeMutableIndices {
            let p = $0.bindMemory(to: UInt32.self)
            meshIndices.enumerated().forEach {
                p[$0.offset] = $0.element
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
        guard let deviceAnchor = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime() + 0.01) else { return }
        // using hard coded value, because we cannot get at runtime, as the only way to get them is from CompsitorLayer Drawable that cannot run simultaneously with ImmersiveView with RealityView.
#if targetEnvironment(simulator)
        let projection0 = simd_float4x4([
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.7777778, 0.0, 0.0],
            [0.0, 0.0, 0.0, -1.0],
            [0.0, 0.0, 0.1, 0.0],
        ])
//        let projection0 = simd_float4x4([
//            [0.70956117, 2.7048769e-05, 0.0, 0.00025395412],
//            [1.6707818e-06, 0.8844015, 0.0, 6.786168e-06],
//            [-0.26731065, -0.08808379, 0.0, -1.0000936],
//            [0.0, 0.0, 0.09691928, 0.0],
//        ])
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
        var projection0FixedZ = projection0
//        projection0FixedZ[2][2] = -1
        var projection1FixedZ = projection1
//        projection1FixedZ[2][2] = -1
        var uniforms = Uniforms(
            cameraTransform: cameraTransform,
            cameraTransformL: cameraTransformL,
            cameraTransformR: cameraTransformR,
            projection0: projection0FixedZ,
            projection1: projection1FixedZ,
            projection0Inverse: projection0FixedZ.inverse,
            projection1Inverse: projection1FixedZ.inverse,
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        defer {commandBuffer.commit()}

        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            defer {computeEncoder.endEncoding()}
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setTexture(metalTexture0, index: outTexture0Index)
            computeEncoder.setTexture(metalTexture1, index: outTexture1Index)
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
            blit.copy(from: uniformsBuffer, sourceOffset: 0, sourceBytesPerRow: MemoryLayout<simd_float4x4>.size, sourceBytesPerImage: uniformsBuffer.length, sourceSize: MTLSize(width: 4, height: 5, depth: 1), to: uniformsMetalTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
    }
}


