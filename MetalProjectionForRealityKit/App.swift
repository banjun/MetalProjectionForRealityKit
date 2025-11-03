import SwiftUI

@main
struct App: SwiftUI.App {
    @State private var model = AppModel()
    var body: some Scene {
        Group {
            // Landing Window
            WindowScene()

            // RealityView, with Metal map
            ImmersiveViewScene()

            // For collecting projection values
            CompositorServiceScene()
        }
        .environment(model)
     }
}
