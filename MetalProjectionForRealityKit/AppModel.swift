import SwiftUI
import ARKit

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    enum ImmersiveSpaceState: Equatable {
        case closed
        case inTransition(String?)
        case open(String)
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    var cameraTransform: simd_float4x4?
    var projections: [simd_float4x4] = []
}
