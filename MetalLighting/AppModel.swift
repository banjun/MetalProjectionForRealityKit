//
//  AppModel.swift
//  MetalLighting
//
//  Created by banjun on R 7/11/24.
//

import SwiftUI
import MetalProjection

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    let metalMap = MetalMap(width: 1024, height: 1024)
}
