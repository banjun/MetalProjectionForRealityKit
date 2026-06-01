//
//  ContentView.swift
//  MetalLighting
//
//  Created by banjun on R 7/11/24.
//

import SwiftUI
import RealityKit
import ShaderGraphCoder
import MetalProjection

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    var metalMap: MetalMap {appModel.metalMap}

    var body: some View {
        RealityView { content in
            for vid in 0..<DeviceDependants.viewCount {
                let width: Float = 0.35
                let height: Float = width / DeviceDependants.aspectRatio
                let e = await ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [{
                    let color = SGTexture.texture(metalMap.debugTextureResource)
                        .image2DArrayColor4(index: .int(vid), defaultValue: .transparentBlack, magFilter: .nearest, minFilter: .nearest, uWrapMode: .clampToEdge, vWrapMode: .clampToEdge, noFlipV: .int(1))
                    return try! await ShaderGraphMaterial(surface: unlitSurface(color: color.rgb, opacity: color.a, applyPostProcessToneMap: true))
                }()])
                e.position.y = Float((vid * 2 - 1) * (DeviceDependants.viewCount - 1)) * (height / 2 + 0.01)
                e.position.z = -0.175
                content.add(e)
            }
        }
        .frame(height: 1024)
        .opacity(metalMap.debugBlit != nil ? 1 : 0)
        .ornament(attachmentAnchor: .scene(.top)) {
            ToggleImmersiveSpaceButton().padding().glassBackgroundEffect()
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VStack {
                Text("Debug Texture View")
                Picker("Debug Texture View", selection: .init(get: {metalMap.debugBlit}, set: {metalMap.debugBlit = $0})) {
                    Text("none").tag(MetalMap.DebugBlit?.none)
                    ForEach(MetalMap.DebugBlit.allCases) {
                        Text(String(describing: $0)).tag(MetalMap.DebugBlit?.some($0))
                    }
                }
                .pickerStyle(.palette)

                switch metalMap.debugBlit {
                case .bloom:
                    HStack {
                        Toggle("Bloom", isOn: .init(get: {metalMap.isBloomEnabled}, set: {metalMap.isBloomEnabled = $0})).toggleStyle(.button)
                        Divider().padding()
                        VStack {
                            @Bindable var metalMap = metalMap
                            HStack {
                                Text("Steps")
                                Picker("Steps", selection: $metalMap.bloomSteps) {
                                    ForEach([1, 2, 4, 8, 16], id: \.self) { s in
                                        Text("\(s)").tag(s)
                                    }
                                }
                                .pickerStyle(.palette)
                            }
                            HStack {
                                Text("Intensity = \(metalMap.bloomIntensity, format: .number.precision(.fractionLength(3)))")
                                Slider(value: $metalMap.bloomIntensity, in: 0...10)
                            }
                            HStack {
                                Text("Spread = \(metalMap.bloomSpread, format: .number.precision(.fractionLength(3)))")
                                Slider(value: $metalMap.bloomSpread, in: 0.01...2)
                            }
                        }
                    }
                case .volumeLight, .surfaceLight:
                    HStack {
                        Toggle("DMX", isOn: .init(get: {appModel.useDMX}, set: {appModel.useDMX = $0})).toggleStyle(.button)
                        Divider().padding()
                        VStack {
                            @Bindable var metalMap = metalMap
                            HStack {
                                Toggle("Main", isOn: .init(get: {metalMap.isMainLightsEnabled}, set: {metalMap.isMainLightsEnabled = $0})).toggleStyle(.button)
                                Toggle("Line1", isOn: .init(get: {metalMap.isLineLights1Enabled}, set: {metalMap.isLineLights1Enabled = $0})).toggleStyle(.button)
                                Toggle("Line2", isOn: .init(get: {metalMap.isLineLights2Enabled}, set: {metalMap.isLineLights2Enabled = $0})).toggleStyle(.button)
                                Toggle("Line3", isOn: .init(get: {metalMap.isLineLights3Enabled}, set: {metalMap.isLineLights3Enabled = $0})).toggleStyle(.button)
                            }
                            HStack {
                                if metalMap.debugBlit == .volumeLight {
                                    Text("Volume Intensity = \(metalMap.volumeLightBaseIntensity, format: .number.precision(.fractionLength(3)))")
                                    Slider(value: $metalMap.volumeLightBaseIntensity, in: 0.1...10)
                                } else {
                                    Text("Surface Intensity = \(metalMap.surfaceLightBaseIntensity, format: .number.precision(.fractionLength(3)))")
                                    Slider(value: $metalMap.surfaceLightBaseIntensity, in: 1...100)
                                }
                            }
                        }
                    }
                default: Text("No Options for \(metalMap.debugBlit?.rawValue ?? "none")")
                }
            }
            .padding()
            .glassBackgroundEffect()
        }
        .onAppear {
            Task.immediate {await openImmersiveSpace(id: appModel.immersiveSpaceID)}
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
