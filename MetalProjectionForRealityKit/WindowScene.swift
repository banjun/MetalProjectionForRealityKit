import SwiftUI

struct WindowScene: Scene {
    var body: some Scene {
        WindowGroup {
            WindowContentView()
        }
        .windowResizability(.contentSize)
    }
}
