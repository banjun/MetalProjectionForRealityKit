import SwiftUI
import RealityKit

struct WindowContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack {
            HStack(spacing: 40) {
                ToggleImmersiveSpaceButton(
                    immersiveSpaceID: ImmersiveViewScene.id,
                    immersiveSpaceName: "Immersive Space")
                ToggleImmersiveSpaceButton(
                    immersiveSpaceID: CompositorServiceScene.id,
                    immersiveSpaceName: "Compositor Service")
            }
            Divider()
            HStack(alignment: .top, spacing: 40) {
                VStack {
                    if let cameraTransform = appModel.cameraTransform  {
                        Text("Camera Transform")
                        Float4x4Grid(value: cameraTransform)
                            .fixedSize()
                    }
                }

                VStack {
                    if !appModel.projections.isEmpty {
                        Text("Projections")
                        if let ipd = appModel.estimatedIPD {
                            Text("Estimated IPD = \(ipd, format: .number.precision(.fractionLength(3)))")
                        }
                    }
                    HStack(spacing: 40) {
                        ForEach(appModel.projections.indices, id: \.self) { i in
                            VStack {
                                Text("ViewIndex = \(i)")
                                Float4x4Grid(value: appModel.projections[i])
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct Float4x4Grid: View {
    var value: simd_float4x4
    var body: some View {
        Grid {
            ForEach(0..<4) { r in
                GridRow {
                    ForEach(0..<4) { c in
                        Text(value[c][r], format: .number.precision(.fractionLength(4)).sign(strategy: .always(includingZero: true)))
                    }
                }
            }
        }
        .font(.system(size: 32))
        .monospacedDigit()
        .fixedSize()
    }
}

