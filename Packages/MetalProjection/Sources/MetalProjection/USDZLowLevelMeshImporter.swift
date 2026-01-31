import Foundation
import RealityKit
import Metal

public struct USDZLowLevelMeshImporter {
    public var mesh: LowLevelMesh
    public var materials: [any RealityKit.Material]
    // just for accumulation for loading hierarchy
    private var verticesCount: Int
    private var indicesCount: Int

    @MainActor public func modelEntity() throws -> ModelEntity {
        ModelEntity(mesh: try MeshResource(from: mesh), materials: materials)
    }
    /// Metal-only rendering
    @MainActor public func emptyModelEntity() throws -> ModelEntity {
        ModelEntity(mesh: try! .generate(from: []), materials: materials)
    }

    enum ImportError: Error {
        case modelEntityNotFound
    }

    public init(mesh: LowLevelMesh, materials: [any RealityKit.Material], verticesCount: Int, indicesCount: Int) {
        self.mesh = mesh
        self.materials = materials
        self.verticesCount = verticesCount
        self.indicesCount = indicesCount
    }

    @MainActor public init(entityNamed name: String, in bundle: Bundle? = nil, descriptor: LowLevelMesh.Descriptor = Vertex.descriptor) async throws {
        try self.init(rootEntity: try await Entity(named: name, in: bundle), descriptor: descriptor)
    }
    @MainActor public init(rootEntity root: Entity, descriptor: LowLevelMesh.Descriptor = Vertex.descriptor) throws {
        var mesh: LowLevelMesh?
        var materials: [any RealityKit.Material] = []
        var verticesCount: Int = 0
        var indicesCount: Int = 0
        func recursive(on entity: Entity) throws {
            if case let me as ModelEntity = entity {
                let ll = try Self.init(model: me, meshAccumulated: mesh, materialsAccumulated: materials, verticesCountAccumulated: verticesCount, indicesCountAccumulated: indicesCount, rootFromModelTransform: root.convert(transform: .identity, from: me), descriptor: descriptor)
                mesh = ll.mesh
                materials = ll.materials
                verticesCount = ll.verticesCount
                indicesCount = ll.indicesCount
            }
            try entity.children.forEach(recursive(on:))
        }
        try recursive(on: root)
        if let mesh {
            self.init(mesh: mesh, materials: materials, verticesCount: verticesCount, indicesCount: indicesCount)
        } else {
            throw ImportError.modelEntityNotFound
        }
    }
    /// init from USDZ, typically loaded with ModelEntity(named: "name"). USDZ should be flattened. typically has many parts with instances, materials are indexed by materialIndex
    @MainActor public init(usdz: ModelEntity) throws {
        try self.init(model: usdz)
    }
    /// init from USDZ, or, hierarchical ModelEntities. For accumulation, mesh and materials are parameterized, and rootFromModelTransform for converting hierarycial position.
    @MainActor public init(model: ModelEntity, meshAccumulated: LowLevelMesh? = nil, materialsAccumulated: [any RealityKit.Material] = [], verticesCountAccumulated: Int = 0, indicesCountAccumulated: Int = 0, rootFromModelTransform: Transform = .identity, descriptor: LowLevelMesh.Descriptor = Vertex.descriptor) throws {
        let model = model.model!
        let meshModels = model.mesh.contents.models
        let meshInstances = model.mesh.contents.instances
        let usdzLLMesh = if let meshAccumulated {meshAccumulated} else {try LowLevelMesh(descriptor: descriptor)}
        self.mesh = usdzLLMesh
        self.materials = materialsAccumulated + model.materials
        NSLog("%@", "instances = \(meshInstances.map {($0.id, $0.model, $0.transform)}), rootFromModelTransform = \(rootFromModelTransform)")

        var totalVertexCount = verticesCountAccumulated
        var totalIndexCount = indicesCountAccumulated
        for model in meshModels {
            let instance = meshInstances.first {$0.model == model.id}
            let transform = rootFromModelTransform.matrix * (instance.map {$0.transform} ?? simd_float4x4(diagonal: [1,1,1,1]))
            for part in model.parts {
                guard let triangleIndices = part.triangleIndices else { continue }
                let indexOffset = totalIndexCount
                let indexCount = triangleIndices.count
                defer {totalIndexCount += indexCount}
                let positions = part.positions.map {
                    let t = transform * simd_float4($0, 1)
                    return SIMD3<Float>(t.x, t.y, t.z)
                }
                let bounds = positions.reduce(into: (min: SIMD3<Float>(9999, 9999, 9999), max: SIMD3<Float>(-999, -999, -999))) {
                    $0.min.x = min($0.min.x, $1.x)
                    $0.min.y = min($0.min.y, $1.y)
                    $0.min.z = min($0.min.z, $1.z)
                    $0.max.x = max($0.max.x, $1.x)
                    $0.max.y = max($0.max.y, $1.y)
                    $0.max.z = max($0.max.z, $1.z)
                }
                let llPart = LowLevelMesh.Part(indexOffset: indexOffset * MemoryLayout<UInt32>.stride, indexCount: indexCount, topology: .triangle, materialIndex: materialsAccumulated.count + part.materialIndex, bounds: .init(min: bounds.min, max: bounds.max))
                usdzLLMesh.parts.append(llPart)

                NSLog("%@", "appending \(positions.count) vertices at \(totalVertexCount), \(indexCount) indices at \(indexOffset), materialIndex = \(part.materialIndex)")

                let vertexOffset = totalVertexCount
                defer {totalVertexCount += positions.count}
                usdzLLMesh.withUnsafeMutableBytes(bufferIndex: 0) {
                    let uvs = part.textureCoordinates?.elements
                    let normals = part.normals?.elements
                    let tangents = part.tangents?.elements
                    let bitangents = part.bitangents?.elements
                    if uvs != nil { NSLog("%@", "uv found on part") }
                    if normals != nil { NSLog("%@", "normals found on part") }
                    if tangents != nil { NSLog("%@", "tangents found on part") }
                    if bitangents != nil { NSLog("%@", "bitangents found on part") }
                    guard uvs == nil || uvs?.count == positions.count else { fatalError() }
                    guard normals == nil || normals?.count == positions.count else { fatalError() }
                    guard tangents == nil || tangents?.count == positions.count else { fatalError() }
                    guard bitangents == nil || bitangents?.count == positions.count else { fatalError() }

                    let p = $0.bindMemory(to: Vertex.self)
                    positions.enumerated().forEach { i, xyz in
                        p[vertexOffset + i] = Vertex(position: xyz, uv: uvs?[i], normal: normals?[i], tangent: tangents?[i], bitangent: bitangents?[i])
                    }
                }
                usdzLLMesh.withUnsafeMutableIndices {
                    let p = $0.bindMemory(to: UInt32.self)
                    triangleIndices.enumerated().forEach {
                        p[indexOffset + $0.offset] = UInt32(vertexOffset) + $0.element
                    }
                }
            }
        }
        self.verticesCount = totalVertexCount
        self.indicesCount = totalIndexCount
    }

    public struct Vertex {
        public var position: SIMD3<Float>
        public var uv: SIMD2<Float>?
        public var normal: SIMD3<Float>?
        public var tangent: SIMD3<Float>?
        public var bitangent: SIMD3<Float>?

        public static let vertexAttributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Self>.offset(of: \.position)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Self>.offset(of: \.uv)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Self>.offset(of: \.normal)!),
            .init(semantic: .tangent, format: .float3, offset: MemoryLayout<Self>.offset(of: \.tangent)!),
            .init(semantic: .bitangent, format: .float3, offset: MemoryLayout<Self>.offset(of: \.bitangent)!),
        ]
        public static let vertexLayouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<Self>.stride)
        ]
        public static var descriptor: LowLevelMesh.Descriptor {
            var desc = LowLevelMesh.Descriptor()
            desc.vertexAttributes = Vertex.vertexAttributes
            desc.vertexLayouts = Vertex.vertexLayouts
            desc.indexType = .uint32
            desc.vertexCapacity = 100_000
            desc.indexCapacity = 1_000_000
            return desc
        }
    }
}
