import RealityKit

public struct MetalMapSystem: System {
    public struct Component: RealityKit.Component {
        public var map: MetalMap?
        public var llMesh: LowLevelMesh
        public var skinningMatrices: [simd_float4x4]
        public init(map: MetalMap? = nil, llMesh: LowLevelMesh, skinningMatrices: [simd_float4x4] = []) {
            self.map = map
            self.llMesh = llMesh
            self.skinningMatrices = skinningMatrices
        }
    }
    public init(scene: Scene) {
    }
    public func update(context: SceneUpdateContext) {
        var maps: [ObjectIdentifier: (MetalMap, [Entity])] = [:]
        for e in context.entities(matching: .init(where: .has(Component.self)), updatingSystemWhen: .rendering) {
            guard e.isEnabledInHierarchy, let map = e.components[Component.self]!.map else { continue }
            maps[ObjectIdentifier(map), default: (map, [])].1.append(e)
        }
        for (map, entities) in maps.values {
            map.draw(entities)
        }
    }
}
