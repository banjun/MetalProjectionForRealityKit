import RealityKit

struct MetalMapSystem: System {
    struct Component: RealityKit.Component {
        var map: MetalMap?
    }
    init(scene: Scene) {
    }
    func update(context: SceneUpdateContext) {
        context.entities(matching: .init(where: .has(Component.self)), updatingSystemWhen: .rendering).forEach { e in
            let c = e.components[Component.self]!
            guard let map = c.map else { return }
            map.draw()
        }
    }
}
