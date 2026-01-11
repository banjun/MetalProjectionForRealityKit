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
    var immersiveSpaceState = ImmersiveSpaceState.closed {
        didSet {
            switch immersiveSpaceState {
            case .closed: dmxHolder?.stop()
            case .inTransition: break
            case .open: dmxHolder?.start()
            }
        }
    }

    let metalMap = MetalMap(width: 1024, height: 1024)
    var dmxHolder: DMXHolder? {
        didSet {
            oldValue?.stop()
            metalMap.dmxHolder = dmxHolder
        }
    }
    var useDMX: Bool = false {
        didSet {
            dmxHolder = useDMX ? DMXHolder(universe: 1) : nil
            if useDMX {
                dmxHolder?.start()
            }
        }
    }
}
