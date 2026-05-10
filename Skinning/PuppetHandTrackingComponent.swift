import Foundation
import RealityKit
import ARKit

struct PuppetHandTrackingSystem: System {
    static let query1: EntityQuery = .init(where: .has(AnchoringComponent.self))
    static let query2: EntityQuery = .init(where: .has(PuppetIKComponent.self))
    static var dependencies: [SystemDependency] {[.before(PuppetIKSystem.self)]}
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        var transforms: [AnchoringComponent.Target: Transform] = [:]
        context.entities(matching: Self.query1, updatingSystemWhen: .rendering).forEach { e in
            let c = e.components[AnchoringComponent.self]!
            transforms[c.target] = e.convert(transform: .identity, to: nil)
        }

        context.entities(matching: Self.query2, updatingSystemWhen: .rendering).forEach { e in
            var c = e.components[PuppetIKComponent.self]!
            defer {e.components.set(c)}
            c.L_wrist = c.L_wrist_anchor.flatMap {transforms[$0]}
            c.R_wrist = c.R_wrist_anchor.flatMap {transforms[$0]}
        }
    }
}
