import RealityKit
import SwiftUI

extension DragGesture {
    static func simpleManipulation(targeting entity: Entity, grabSoundEffect: AudioResource? = nil, placeSoundEffect: AudioResource? = nil) -> some Gesture {
        func transform(t: Transform, value: EntityTargetValue<Value>) -> Transform {
            var t = t
            let translation = value.convert(value.translation3D, from: .global, to: .scene)
            if let pose = value.inputDevicePose3D, let startPose = value.startInputDevicePose3D {
                let rotation = value.convert(pose.rotation, from: .global, to: .scene)
                let startRotation = value.convert(startPose.rotation, from: .global, to: .scene)
                t.rotation = rotation * startRotation.inverse * t.rotation
            }
            t.translation += .init(translation)
            return t
        }
        var state: Transform?
        return DragGesture(minimumDistance: 0, coordinateSpace: .immersiveSpace).targetedToEntity(entity).onChanged { value in
            if state == nil {
                state = value.entity.transform
                if let grabSoundEffect {
                    value.entity.playAudio(grabSoundEffect)
                }
            }
            let t = state!
            value.entity.transform = transform(t: t, value: value)
        }.onEnded { value in
            if let placeSoundEffect {
                value.entity.playAudio(placeSoundEffect)
            }
            guard let t = state else { return }
            value.entity.transform = transform(t: t, value: value)
            state = nil
        }
    }
}
extension GestureComponent {
    static func simpleManipulation(targeting entity: Entity, grabSoundEffect: AudioResource? = nil, placeSoundEffect: AudioResource? = nil) -> GestureComponent {
        GestureComponent(DragGesture.simpleManipulation(targeting: entity, grabSoundEffect: grabSoundEffect, placeSoundEffect: placeSoundEffect))
    }
}
extension Entity {
    func configureSimpleManipulationGestureComponent(allowedInputTypes: InputTargetComponent.InputType = .indirect, collisionShapes: [ShapeResource] = [], enableHoverEffect: Bool = false, grabSoundEffect: AudioResource? = nil, placeSoundEffect: AudioResource? = nil) {
        components.set(InputTargetComponent(allowedInputTypes: allowedInputTypes))
        if !collisionShapes.isEmpty {
            components.set(CollisionComponent(shapes: collisionShapes, isStatic: true))
        }
        if enableHoverEffect {
            components.set(HoverEffectComponent())
        }
        components.set(GestureComponent.simpleManipulation(targeting: self, grabSoundEffect: grabSoundEffect, placeSoundEffect: placeSoundEffect))
    }
}
