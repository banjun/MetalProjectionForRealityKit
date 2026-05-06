import RealityKit

struct PuppetIKComponent: Component {
    var L_wrist: Transform?
    var R_wrist: Transform?
}

struct PuppetIKSystem: System {
    static let query: EntityQuery = .init(where: .has(PuppetIKComponent.self) && .has(IKComponent.self))
    init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        context.entities(matching: Self.query, updatingSystemWhen: .rendering).forEach { e in
            let ik = e.components[IKComponent.self]!
            let puppet = e.components[PuppetIKComponent.self]!
            guard let solver = ik.solvers.first else { return }

            if let c = solver.constraints["L_wrist"], let t = puppet.L_wrist {
                c.target = e.convert(transform: t, from: nil)
                c.animationOverrideWeight = (1, 1)
            }
            if let c = solver.constraints["R_wrist"], let t = puppet.R_wrist {
                c.target = e.convert(transform: t, from: nil)
                c.animationOverrideWeight = (1, 1)
            }
            e.components.set(ik)
        }
    }

}
