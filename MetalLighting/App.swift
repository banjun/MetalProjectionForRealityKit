//
//  MetalLightingApp.swift
//  MetalLighting
//
//  Created by banjun on R 7/11/24.
//

import SwiftUI

@main
struct MetalLightingApp: App {
    @State private var appModel = AppModel()
    @State private var metalMap = MetalMap()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
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
