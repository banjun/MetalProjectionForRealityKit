//
//  ContentView.swift
//  Skinning
//
//  Created by banjun on R 8/05/06.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 40) {
            @Bindable var appModel = appModel
            HStack(spacing: 100) {
                Toggle(isOn: $appModel.showsRealityKitIK) {
                    Text("Show RealityKit IK").padding(20)
                }
                Toggle(isOn: $appModel.showsMetalIK) {
                    Text("Show Metal IK").padding(20)
                }
            }
            .buttonBorderShape(.roundedRectangle)
            .font(.extraLargeTitle)

            Divider()
            Toggle(isOn: $appModel.upperLimbVisibility) {
                Text("Show Hands").padding(20)
            }

            Divider()
            ToggleImmersiveSpaceButton()
        }
        .toggleStyle(.button)
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
