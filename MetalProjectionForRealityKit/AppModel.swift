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
    var estimatedIPD: Float? {
        guard projections.count == 2 else { return nil }
        let projection0 = projections[0]
        let projection1 = projections[1]

        let nearPlane = projection0[3][2] / (projection0[2][2] - 1.0)
        // 非対称 projection の x オフセット
        // Metal/OpenGL列優先行列: projection[0][2] = (r+l)/(r-l)
        let offsetL = projection0[2][0]; // 左目オフセット
        let offsetR = projection1[2][0]; // 右目オフセット

        // 左右 near plane 上の View Space x 座標
        let xL_near = -offsetL * nearPlane; // 簡易近似
        let xR_near = -offsetR * nearPlane;

        // near plane 上での左右差
        let deltaX_near = abs(xR_near - xL_near);

        // Parallel camera モデルでは、near plane 上の差 ≈ IPD
        // 実際は視線方向が平行なので、正確には nearPlane でスケーリング不要
        let ipd = deltaX_near;

        return ipd;
    }
}
