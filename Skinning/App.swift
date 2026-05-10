//
//  SkinningApp.swift
//  Skinning
//
//  Created by banjun on R 8/05/06.
//

import SwiftUI

@main
struct SkinningApp: App {
    @State private var appModel = AppModel()
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .onAppear {
                    Task {
                        await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    }
                }
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)
     }
}
