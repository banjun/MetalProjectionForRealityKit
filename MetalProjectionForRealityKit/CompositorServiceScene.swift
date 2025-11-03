import SwiftUI
import CompositorServices
import ARKit
import Metal

struct CompositorServiceScene: Scene {
    static let id = "CS"
    @Environment(AppModel.self) private var appModel
    @State private var arkitSession = ARKitSession()
    @State private var worldTracker = WorldTrackingProvider()
    @State private var device = MTLCreateSystemDefaultDevice()!

    var body: some Scene {
        ImmersiveSpace(id: Self.id) {
            CompositorLayer { renderer in
                NSLog("%@", "isFoveationEnabled = \(renderer.configuration.isFoveationEnabled)")

                Task {
                    try! await arkitSession.run([worldTracker])
                    let commandQueue = device.makeCommandQueue()!

                    while true {
                        try! await Task.sleep(for: .microseconds(100))

                        guard let frame = renderer.queryNextFrame() else { continue }
                        frame.startUpdate()
                        guard let drawable = frame.queryDrawables().first else { continue }

                        if let deviceAnchor = worldTracker.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                            NSLog("%@", "deviceAnchor = \(deviceAnchor)")
                            drawable.deviceAnchor = deviceAnchor
                            appModel.cameraTransform = deviceAnchor.originFromAnchorTransform

                            let projections = drawable.views.enumerated().map { viewIndex, view in
                                drawable.computeProjection(viewIndex: viewIndex)
                            }
                            appModel.projections = projections
                            projections.enumerated().forEach { i, p in
                                NSLog("%@", "computeProjection[\(i)] = \(p.debugDescription)")
                                // here is captured sample values:
                                // sample value on visionOS 26.1 Simulator:
                                _ = simd_float4x4([
                                    [1.0, 0.0, 0.0, 0.0],
                                    [0.0, 1.7777778, 0.0, 0.0],
                                    [0.0, 0.0, 0.0, -1.0],
                                    [0.0, 0.0, 0.1, 0.0]
                                ])
                                // sample value on M5 AVP 26.1 (viewIndex 0, 1):
                                _ = simd_float4x4([
                                    [0.7315394, 3.9901988e-07, 0.0, 3.1312097e-06],
                                    [2.0127231e-07, 0.91187435, 0.0, 9.520301e-07],
                                    [-0.26791388, -0.08751587, 0.0, -1.0000012],
                                    [0.0, 0.0, 0.09993004, 0.0]
                                ])
                                _ = simd_float4x4([
                                    [0.73168945, -1.0521787e-07, 0.0, -2.2248819e-06],
                                    [1.8116259e-07, 0.9120613, 0.0, -6.887392e-07],
                                    [0.26794675, -0.0874681, 0.0, -1.0000007],
                                    [0.0, 0.0, 0.09995053, 0.0]
                                ])
                            }
                        }

                        frame.endUpdate()

                        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
                        frame.startSubmission()
                        drawable.encodePresent(commandBuffer: commandBuffer)
                        commandBuffer.commit()
                        frame.endSubmission()
                    }
                }
            }
            .onAppear {
                appModel.immersiveSpaceState = .open(Self.id)
            }
            .onDisappear {
                appModel.immersiveSpaceState = .closed // not called?
            }
        }
        .immersiveEnvironmentBehavior(.coexist)
    }
}
