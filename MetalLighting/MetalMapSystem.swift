import RealityKit

struct MetalMapSystem: System {
    struct Component: RealityKit.Component {
        var map: MetalMap?
    }
    init(scene: Scene) {
    }
    func update(context: SceneUpdateContext) {
        for e in context.entities(matching: .init(where: .has(Component.self)), updatingSystemWhen: .rendering) {
            let c = e.components[Component.self]!
            guard let map = c.map else { continue }
            map.draw()
            return
        }
    }
}
