import SwiftUI
import UIKit

/// Calibrated against system Photos on iOS 27.2. Durations are seconds;
/// gesture tracking stays unanimated and native presentations keep their timing.
nonisolated enum PhotosMotion {
    static let viewerOpenDuration = 0.35
    static let viewerCloseDuration = 0.30
    static let chromeDuration = 0.20
    static let layoutDuration = 0.5058237870785645
    static let editorToolsDuration = 0.25
    static let imageFadeDuration = 0.25
    static let removalDuration = 0.30

    // Photos' information/layout spring: mass 3, stiffness 1000, damping 500.
    // Core Animation clamps it to critical damping; normalize to unit mass
    // so SwiftUI follows the same trajectory instead of an overdamped tail.
    static let information = Animation.interpolatingSpring(
        mass: 1, stiffness: 1000.0 / 3, damping: 2 * (1000.0 / 3).squareRoot()
    )

    @MainActor static var layout: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : information
    }

    @MainActor static var controls: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: chromeDuration)
    }

    @MainActor static var editorTools: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: editorToolsDuration)
    }

    @MainActor static var removal: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: removalDuration)
    }

    /// Use UIKit's duration/damping-ratio initializer: on the reference
    /// runtime, UISpringTimingParameters(duration:bounce:) stretches a 350 ms
    /// request to 514 ms and produces a different stiffness. Regression tests
    /// compare the emitted CA animation with the recorded Photos trajectory.
    @MainActor static func springAnimator(
        duration: TimeInterval, animations: @escaping () -> Void
    ) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration, dampingRatio: 1, animations: animations)
    }
}
