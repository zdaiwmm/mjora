import SwiftUI
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotosMotionCalibrationTests: XCTestCase {
    /// Compare emitted Core Animation springs to the system Photos capture,
    /// rather than asserting that a duration constant equals its own literal.
    func testUIKitSpringsMatchRecordedPhotosTrajectories() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let tile = UIView(frame: CGRect(x: 0, y: 100, width: 80, height: 80))
        controller.view.addSubview(tile)
        controller.view.layoutIfNeeded()
        // Captured on the dedicated iOS 27.2 Photos reference simulator:
        // opening, dismissal, and the mass-3 information/layout spring.
        let cases: [(TimeInterval, Double)] = [
            (PhotosMotion.viewerOpenDuration, 695.9667673959092),
            (PhotosMotion.viewerCloseDuration, 947.288099),
            (PhotosMotion.layoutDuration, 1000.0 / 3),
        ]
        for (duration, stiffness) in cases {
            tile.layer.removeAllAnimations()
            tile.center.x = 40
            let animator = PhotosMotion.springAnimator(duration: duration) { tile.center.x = 240 }
            animator.startAnimation()
            try await Task.sleep(for: .milliseconds(30))
            let emitted = try XCTUnwrap(tile.layer.animation(forKey: "position") as? CASpringAnimation)
            XCTAssertEqual(emitted.duration, duration, accuracy: 0.005)
            XCTAssertEqual(emitted.stiffness / emitted.mass, stiffness, accuracy: 1)
            XCTAssertEqual(emitted.damping / emitted.mass, 2 * stiffness.squareRoot(), accuracy: 0.1)
            animator.stopAnimation(true)
        }
    }

    func testSwiftUILayoutUsesTheRecordedInformationSpring() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let state = MotionProbeState()
        let host = UIHostingController(rootView: MotionProbe(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        state.expanded = true
        try await Task.sleep(for: .milliseconds(60))
        func springs(in layer: CALayer) -> [CASpringAnimation] {
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
                + (layer.sublayers ?? []).flatMap { springs(in: $0) }
        }
        let emitted = try XCTUnwrap(springs(in: host.view.layer).first)
        XCTAssertEqual(emitted.stiffness / emitted.mass, 1000.0 / 3, accuracy: 1)
        XCTAssertEqual(emitted.damping / emitted.mass, 2 * (1000.0 / 3).squareRoot(), accuracy: 0.1)
    }

    func testNewPinchDuringSlowerSettlingRetainsItsOwnOverlay() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let grid = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        grid.contentSize = CGSize(width: 300, height: 1000)
        controller.view.addSubview(grid)
        let transition = TimelineGridZoomTransition()
        let tile = TimelineGridZoomTransition.CapturedTile(
            id: "synthetic", frame: CGRect(x: 0, y: 100, width: 100, height: 100), makeReplica: { UIView() }
        )
        var supersededCompletion = false
        transition.begin(in: grid, captured: [tile], midpoint: CGPoint(x: 50, y: 150), reduceMotion: false)
        transition.finish(in: grid, frames: ["synthetic": CGRect(x: 0, y: 200, width: 150, height: 150)],
            scroll: { grid.contentOffset.y = $0 }, destinations: { [] }, completion: { supersededCompletion = true })
        try await Task.sleep(for: .milliseconds(80))
        transition.begin(in: grid, captured: [tile], midpoint: CGPoint(x: 50, y: 150), reduceMotion: false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(supersededCompletion, "A cancelled settle must not finish a replacement pinch")
        XCTAssertTrue(transition.isPrepared)
        XCTAssertEqual(controller.view.subviews.count, 2)
        transition.cancel()
        XCTAssertEqual(controller.view.subviews.count, 1)
    }
}

@MainActor @Observable
private final class MotionProbeState {
    var expanded = false
}

private struct MotionProbe: View {
    @Bindable var state: MotionProbeState
    var body: some View {
        Color.red.frame(width: 80, height: 80)
            .offset(x: state.expanded ? 100 : -100)
            .animation(PhotosMotion.layout, value: state.expanded)
    }
}
