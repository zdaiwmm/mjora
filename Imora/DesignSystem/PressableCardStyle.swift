import SwiftUI

/// subtle press-down scale for tappable cards.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(configuration.isPressed ? PhotosMotion.controls : PhotosMotion.layout, value: configuration.isPressed)
            // a pointer on ipad gets the system hover treatment; touch
            // platforms ignore it.
            .hoverEffect()
    }
}
