import SwiftUI
import MetalProjection
import RealityKit

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

#if targetEnvironment(simulator)
    let metalMap = MetalMap(width: 1024, height: 1024)
#else
    let metalMap = MetalMap(
        width: 4096, height: 4096,
        rasterizationRateMap: (horizontal: [0.01, 0.01, 0.1, 1, 0.7, 0.1, 0.01],
                               vertical: [0.01, 0.01, 0.1, 1, 0.1, 0.01, 0.01]))
#endif
    var showsRealityKitIK: Bool = true {didSet {realityKitIKEntity.isEnabled = showsRealityKitIK}}
    var showsMetalIK: Bool = true {didSet {metalIKEntity.isEnabled = showsMetalIK}}
    let realityKitIKEntity: Entity = .init()
    let metalIKEntity: Entity = .init()
    var upperLimbVisibility: Bool = false
}
