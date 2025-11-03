import SwiftUI

struct ImmersiveViewScene: Scene {
    static let id = "ImmersiveView"
    @Environment(AppModel.self) private var appModel
    var body: some Scene {
        ImmersiveSpace(id: Self.id) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open(Self.id)
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)
    }
}
