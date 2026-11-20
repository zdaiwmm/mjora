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

    func testPinchReleaseReturnsToOriginalDensityAfterRecordedReversal() {
        let initialSeparation: CGFloat = 0.740 - 0.260
        let samples: [(left: CGFloat, right: CGFloat)] = [
            (0.428, 0.572),
            (0.340, 0.660),
            (0.414, 0.586),
        ]
        var settle = TimelinePinchSettle()
        for sample in samples {
            settle.update((sample.right - sample.left) / initialSeparation)
        }
        XCTAssertEqual(settle.releaseScale, 1)
    }

    func testMonotonicPinchReleaseCommitsInBothDirections() {
        let gestures: [(scales: [CGFloat], columns: Int)] = [
            ([1, 1.18, 1.35, 1.47], 2),
            ([1, 0.86, 0.65, 0.30], 5),
        ]
        for gesture in gestures {
            var settle = TimelinePinchSettle()
            for scale in gesture.scales { settle.update(scale) }
            let columns = TimelineGridZoomGeometry.columns(base: 3, magnification: settle.releaseScale, width: 390)
            XCTAssertEqual(columns, gesture.columns)
        }
    }

    func testPinchReleaseUsesTheLatestScaleAfterSmallRetreats() {
        let gestures: [(extreme: CGFloat, jitter: CGFloat)] = [(1.47, 1.43), (0.52, 0.535)]
        for gesture in gestures {
            var settle = TimelinePinchSettle()
            settle.update(gesture.extreme)
            settle.update(gesture.jitter)
            XCTAssertEqual(settle.releaseScale, gesture.jitter)
        }
    }

    func testPinchReleaseRearmsAfterClearlyCrossingOriginalScale() {
        let gestures: [(extreme: CGFloat, nearNeutral: CGFloat, oppositeReach: CGFloat)] = [
            (0.30, 1.02, 1.47),
            (1.47, 0.98, 0.30),
        ]
        for gesture in gestures {
            var settle = TimelinePinchSettle()
            settle.update(gesture.extreme)
            settle.update(gesture.nearNeutral)
            XCTAssertEqual(settle.releaseScale, 1)
            settle.update(gesture.oppositeReach)
            XCTAssertEqual(settle.releaseScale, gesture.oppositeReach)
        }
    }

    func testPinchReleaseRearmsOnlyAfterPassingPreviousExtremeOnSameSide() {
        let gestures: [(extreme: CGFloat, retreat: CGFloat, freshReach: CGFloat)] = [
            (0.30, 0.34, 0.29),
            (1.50, 1.33, 1.51),
        ]
        for gesture in gestures {
            var settle = TimelinePinchSettle()
            settle.update(gesture.extreme)
            settle.update(gesture.retreat)
            XCTAssertEqual(settle.releaseScale, 1)
            settle.update(gesture.extreme)
            XCTAssertEqual(settle.releaseScale, 1)
            settle.update(gesture.freshReach)
            XCTAssertEqual(settle.releaseScale, gesture.freshReach)
        }
    }

    func testHeldPinchScalesTheSourceRowAndRetracesTheDestinationFade() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        let grid = UIScrollView(frame: container.bounds)
        grid.contentSize = CGSize(width: 300, height: 2_000)
        grid.contentOffset.y = 200
        container.addSubview(grid)
        let anchor = UIView()
        let neighbor = UIView()
        let destinationAnchor = UIView()
        let destinationNeighbor = UIView()
        let baseSide = AssetGridLayout.tileSide(viewportWidth: 300, columns: 3)
        let zoomedSide = AssetGridLayout.tileSide(viewportWidth: 300, columns: 2)
        let original: [TimelineGridZoomTransition.CapturedTile] = [
            .init(id: "anchor", frame: CGRect(x: 100, y: 160, width: baseSide, height: baseSide), makeReplica: { anchor }),
            .init(id: "neighbor", frame: CGRect(x: 200, y: 160, width: baseSide, height: baseSide), makeReplica: { neighbor })
        ]
        let transition = TimelineGridZoomTransition()
        let midpoint = CGPoint(x: 150, y: 400)
        transition.begin(in: grid, captured: original, midpoint: midpoint, reduceMotion: false) { _, _, columns in
            guard columns == 2 else { return nil }
            return .init(tiles: [
                "anchor": .init(id: "anchor", frame: CGRect(x: 151, y: 500, width: zoomedSide, height: zoomedSide), makeReplica: { destinationAnchor }),
                "neighbor": .init(id: "neighbor", frame: CGRect(x: 0, y: 651, width: zoomedSide, height: zoomedSide), makeReplica: { destinationNeighbor })
            ], verticalOffsets: 0...1500)
        }
        func frame(_ replica: UIView) -> CGRect { replica.convert(replica.bounds, to: container) }
        func assertFrame(_ actual: CGRect, matches expected: CGRect, line: UInt = #line) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, line: line)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, line: line)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, line: line)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, line: line)
        }
        func opacity(_ replica: UIView) -> CGFloat {
            guard let plane = replica.superview, !plane.isHidden else { return 0 }
            return replica.alpha * plane.alpha
        }
        XCTAssertEqual(frame(neighbor).minY, frame(anchor).minY, accuracy: 0.01)
        transition.update(scale: 1.18, midpoint: midpoint, in: grid)
        let onTheWayIn = frame(neighbor)
        let sourceOpacity = opacity(neighbor)
        let targetOpacity = opacity(destinationNeighbor)
        let destinationOnTheWayIn = frame(destinationNeighbor)
        XCTAssertEqual(frame(neighbor).minY, frame(anchor).minY, accuracy: 0.01,
                       "Adjacent photos in the source grid must keep their row while scaling")
        XCTAssertGreaterThan(frame(neighbor).width, baseSide)
        XCTAssertEqual(frame(anchor).minY + frame(anchor).height * (40 / baseSide), 200, accuracy: 0.01)
        XCTAssertEqual(grid.contentOffset.y, 200, accuracy: 0.01)
        transition.update(scale: 1.47, midpoint: midpoint, in: grid)
        XCTAssertLessThan(opacity(neighbor), sourceOpacity)
        XCTAssertGreaterThan(opacity(destinationNeighbor), targetOpacity)
        XCTAssertGreaterThan(frame(destinationNeighbor).midY, frame(destinationAnchor).midY)
        transition.update(scale: 1.18, midpoint: midpoint, in: grid)
        assertFrame(frame(neighbor), matches: onTheWayIn)
        XCTAssertEqual(opacity(neighbor), sourceOpacity, accuracy: 0.001)
        if targetOpacity > 0.001 {
            assertFrame(frame(destinationNeighbor), matches: destinationOnTheWayIn)
        }
        XCTAssertEqual(opacity(destinationNeighbor), targetOpacity, accuracy: 0.001)
        transition.update(scale: 1, midpoint: midpoint, in: grid)
        assertFrame(frame(neighbor), matches: original[1].frame)
        transition.cancel()
    }

    func testContractingGridShowsIncomingPhotosBeforeMovingExistingOnes() {
        let viewport = CGRect(x: 0, y: 0, width: 396, height: 600)
        let container = UIView(frame: viewport)
        let grid = UIScrollView(frame: viewport)
        grid.contentSize = CGSize(width: viewport.width, height: 2_000)
        container.addSubview(grid)
        let source = UIView(), duplicate = UIView(), entering = UIView()
        let startSide = AssetGridLayout.tileSide(viewportWidth: viewport.width, columns: 3)
        let targetSide = AssetGridLayout.tileSide(viewportWidth: viewport.width, columns: 4)
        let start = CGRect(x: 132, y: 200, width: startSide, height: startSide)
        let midpoint = CGPoint(x: start.midX, y: start.midY)
        let transition = TimelineGridZoomTransition()
        let original = TimelineGridZoomTransition.CapturedTile(id: "anchor", frame: start, makeReplica: { source })
        transition.begin(in: grid, captured: [original], midpoint: midpoint, reduceMotion: false) { _, _, columns in
            guard columns == 4 else { return nil }
            return .init(tiles: [
                "anchor": .init(id: "anchor", frame: CGRect(x: 99, y: 200, width: targetSide, height: targetSide), makeReplica: { duplicate }),
                "incoming": .init(id: "incoming", frame: CGRect(x: 0, y: 200, width: targetSide, height: targetSide), makeReplica: { entering })
            ], verticalOffsets: 0...1400)
        }
        transition.update(scale: 0.88, midpoint: midpoint, in: grid)

        let held = source.convert(source.bounds, to: container)
        XCTAssertEqual(held.midX, midpoint.x, accuracy: 0.01)
        XCTAssertEqual(held.midY, midpoint.y, accuracy: 0.01)
        XCTAssertLessThan(held.width, startSide)
        XCTAssertGreaterThan(source.alpha, 0)
        XCTAssertNotNil(entering.superview)
        XCTAssertGreaterThan(entering.alpha, duplicate.superview == nil ? 0 : duplicate.alpha)
        transition.cancel()
    }

    func testPinchReleaseAlignsReplicaWithCommittedGridBeforeRemovingOverlay() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let grid = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        grid.contentInsetAdjustmentBehavior = .never
        grid.contentSize = CGSize(width: 300, height: 1_000)
        controller.view.addSubview(grid)
        let replica = UIView()
        let committedTile = UIView()
        let transition = TimelineGridZoomTransition()
        let firstFrame = CGRect(x: 100, y: 100, width: 100, height: 100)
        let committedFrame = CGRect(x: 151, y: 900, width: 149, height: 149)
        transition.begin(in: grid, captured: [.init(id: "anchor", frame: firstFrame, makeReplica: { replica })],
            midpoint: CGPoint(x: 150, y: 150), reduceMotion: false)
        XCTAssertEqual(replica.frame, firstFrame)
        var mountedViewportFrame: CGRect?
        let settled = expectation(description: "Overlay is removed after aligned handoff")
        transition.finish(in: grid, frames: ["anchor": committedFrame], contentHeight: 1_200,
            scroll: { offset in
                grid.contentSize.height = 1_200
                grid.contentOffset.y = offset
                committedTile.frame = committedFrame
                grid.addSubview(committedTile)
            }, finalTiles: {
                let visible = committedTile.convert(committedTile.bounds, to: controller.view)
                mountedViewportFrame = visible
                return [.init(id: "anchor", frame: visible, makeReplica: { UIView() })]
            }, completion: {
                XCTAssertEqual(committedTile.convert(committedTile.bounds, to: controller.view), mountedViewportFrame)
                XCTAssertEqual(controller.view.subviews.count, 1)
                settled.fulfill()
            })
        XCTAssertEqual(grid.contentOffset.y, 700, accuracy: 0.01)
        XCTAssertEqual(replica.frame, firstFrame, "The outgoing replica must not slide across different grid slots")
        XCTAssertEqual(mountedViewportFrame, committedFrame.offsetBy(dx: 0, dy: -700))
        await fulfillment(of: [settled], timeout: 2)
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
            scroll: { grid.contentOffset.y = $0 }, completion: { supersededCompletion = true })
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
