//
//  ImmersiveView.swift
//  MetalLighting
//
//  Created by banjun on R 7/11/24.
//

import SwiftUI
import RealityKit
import RealityKitContent


struct ImmersiveView: View {

    var body: some View {
        RealityView { content in
            let usdzLLEntity = try! await USDZLowLevelMeshImporter(usdz: ModelEntity(named: "ありす4")).modelEntity()
            usdzLLEntity.position = [0, 1, -1]
            content.add(usdzLLEntity)
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
