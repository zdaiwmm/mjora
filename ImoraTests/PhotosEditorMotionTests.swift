import SwiftUI
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotosEditorMotionTests: XCTestCase {
    func testPinchKeepsThePointInsideThePhotoAtTheGestureMidpoint() {
        let offset = TimelineGridZoomGeometry.offset(
            frame: CGRect(x: 0, y: 1_000, width: 200, height: 200),
            unitY: 0.25, viewportY: 300, topInset: 62, endOffset: 5_000)
        XCTAssertEqual(offset, 812)
        XCTAssertEqual(1_000 + 200 * 0.25 - (offset - 62), 300)
    }

    func testPinchAnchorClampsAtBothLibraryEnds() {
        XCTAssertEqual(TimelineGridZoomGeometry.offset(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            unitY: 0, viewportY: 400, topInset: 62, endOffset: 100), 0)
        XCTAssertEqual(TimelineGridZoomGeometry.offset(
            frame: CGRect(x: 0, y: 900, width: 100, height: 100),
            unitY: 1, viewportY: 100, topInset: 0, endOffset: 500), 500)
    }

    func testPinchReversalAndInvalidScaleStayInSupportedColumnRange() {
        XCTAssertEqual(TimelineGridZoomGeometry.columns(base: 3, magnification: 1.5, width: 393), 2)
        XCTAssertEqual(TimelineGridZoomGeometry.columns(base: 3, magnification: 0.6, width: 393), 5)
        XCTAssertEqual(TimelineGridZoomGeometry.columns(base: 3, magnification: 1, width: 393), 3)
        for scale: CGFloat in [.nan, .infinity, 0, -1] {
            XCTAssertEqual(TimelineGridZoomGeometry.columns(base: 3, magnification: scale, width: 393), 3)
        }
        XCTAssertEqual(TimelineGridZoomGeometry.columns(base: 3, magnification: .leastNonzeroMagnitude, width: 393), 5)
    }

    func testInteractiveFramesFollowScaleAndMidpointTranslation() {
        let frame = TimelineGridZoomGeometry.scaled(
            CGRect(x: 20, y: 40, width: 100, height: 100), by: 1.5,
            around: CGPoint(x: 70, y: 90), to: CGPoint(x: 80, y: 110))
        XCTAssertEqual(frame, CGRect(x: 5, y: 35, width: 150, height: 150))
    }

    func testPinchOverGutterAnchorsTheSamePointInsideTheNearestPhoto() {
        let anchor = TimelineGridZoomGeometry.anchor(
            frame: CGRect(x: 0, y: 100, width: 100, height: 100), midpoint: CGPoint(x: 102, y: 100))
        XCTAssertEqual(anchor.point, CGPoint(x: 50, y: 150))
        XCTAssertEqual(anchor.unitY, 0.5)
        XCTAssertEqual(TimelineGridZoomGeometry.offset(
            frame: CGRect(x: 0, y: 600, width: 200, height: 200), unitY: anchor.unitY,
            viewportY: anchor.point.y, topInset: 0, endOffset: 2_000), 550)
    }

    func testSavedPreviewPreservesCropAndRotationWithBackgroundRendering() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        var state = EditTransform.State()
        state.crop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        state.rotation = 90
        state.flipH = true
        let rendered = await AssetEditPreviewRenderer.projection(source, state: state, adjust: .neutral)
        let data = try XCTUnwrap(rendered)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size, CGSize(width: 6, height: 4))
    }

    func testCancelledAndRepeatedPinchesReleaseEveryOverlay() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let grid = UIScrollView(frame: parent.bounds)
        parent.addSubview(grid)
        let transition = TimelineGridZoomTransition()
        let tile = TimelineGridZoomTransition.CapturedTile(
            id: "synthetic", frame: CGRect(x: 0, y: 100, width: 100, height: 100), makeReplica: { UIView() })
        for _ in 0..<3 {
            transition.begin(in: grid, captured: [tile], midpoint: CGPoint(x: 50, y: 150), reduceMotion: false)
            XCTAssertEqual(parent.subviews.count, 2)
            transition.update(scale: 1.4, midpoint: CGPoint(x: 50, y: 160), in: grid)
        }
        transition.cancel()
        transition.cancel()
        XCTAssertEqual(parent.subviews.count, 1)
        XCTAssertFalse(transition.isPrepared)
        XCTAssertFalse(transition.isTracking)
    }

    func testPinchScalesRowsTogetherAroundTheFingersAndCanReverse() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let grid = UIScrollView(frame: parent.bounds)
        parent.addSubview(grid)
        let anchor = UIView(), moving = UIView()
        let transition = TimelineGridZoomTransition()
        transition.begin(in: grid, captured: [
            .init(id: "anchor", frame: CGRect(x: 0, y: 100, width: 100, height: 100), makeReplica: { anchor }),
            .init(id: "moving", frame: CGRect(x: 0, y: 200, width: 100, height: 100), makeReplica: { moving })
        ], midpoint: CGPoint(x: 50, y: 150), reduceMotion: false)
        defer { transition.cancel() }
        transition.update(scale: 0.85, midpoint: CGPoint(x: 50, y: 150), in: grid)
        XCTAssertTrue(transition.isTracking)
        let visibleAnchor = anchor.convert(anchor.bounds, to: parent)
        let visibleNeighbor = moving.convert(moving.bounds, to: parent)
        XCTAssertEqual(visibleNeighbor.minX, 7.5, accuracy: 0.01)
        XCTAssertEqual(visibleNeighbor.width, 85, accuracy: 0.01)
        XCTAssertEqual(visibleAnchor.midX, 50, accuracy: 0.01)
        XCTAssertEqual(visibleAnchor.midY, 150, accuracy: 0.01)
        XCTAssertEqual(visibleNeighbor.minY, visibleAnchor.maxY, accuracy: 0.01)
        transition.update(scale: 1, midpoint: CGPoint(x: 50, y: 150), in: grid)
        XCTAssertEqual(moving.convert(moving.bounds, to: parent), CGRect(x: 0, y: 200, width: 100, height: 100))
        XCTAssertTrue(transition.isTracking)
    }

    func testReducedMotionRestoresAnchorWithoutBuildingReplicasOrLeavingAnOverlay() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let grid = UIScrollView(frame: parent.bounds)
        grid.contentSize = CGSize(width: 300, height: 1_000)
        parent.addSubview(grid)
        let transition = TimelineGridZoomTransition()
        var replicaCount = 0
        let tile = TimelineGridZoomTransition.CapturedTile(
            id: "synthetic", frame: CGRect(x: 0, y: 100, width: 100, height: 100), makeReplica: {
                replicaCount += 1
                return UIView()
            })
        transition.begin(in: grid, captured: [tile], midpoint: CGPoint(x: 102, y: 100), reduceMotion: true)
        var restoredOffset: CGFloat?
        var completed = false
        transition.finish(in: grid, frames: ["synthetic": CGRect(x: 0, y: 600, width: 200, height: 200)],
            scroll: { restoredOffset = $0 }, completion: { completed = true })
        XCTAssertEqual(replicaCount, 0)
        XCTAssertEqual(restoredOffset, 550)
        XCTAssertTrue(completed)
        XCTAssertEqual(parent.subviews.count, 1)
        XCTAssertFalse(transition.isPrepared)
    }
}
