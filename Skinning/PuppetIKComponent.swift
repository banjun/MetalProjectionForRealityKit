import RealityKit

struct PuppetIKComponent: Component {
    var L_wrist: Transform?
    var L_wrist_anchor: AnchoringComponent.Target? = .hand(.left, location: .joint(for: .littleFingerTip))
    var R_wrist: Transform?
    var R_wrist_anchor: AnchoringComponent.Target? = .hand(.left, location: .joint(for: .thumbTip))
}
