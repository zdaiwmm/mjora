import UIKit
import XCTest
@testable import Imora

@MainActor
final class AssetViewerLifecycleTests: XCTestCase {
    func testClosingViewerReleasesPresentationAndAllowsAnotherAsset() async throws {
        try await exerciseClosingViewer(duringOpening: false)
    }

    func testClosingDuringOpeningReleasesPresentationAndAllowsAnotherAsset() async throws {
        try await exerciseClosingViewer(duringOpening: true)
    }

    private func exerciseClosingViewer(duringOpening: Bool) async throws {
        let presenter = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let presentation = ViewerPresentation()
        let registry = AssetTileRegistry()
        let session = SessionStore()
        let assets = [asset("first"), asset("second")]
        var opened: [String] = []
        var dismissed: [UUID] = []
        func open(_ index: Int) throws {
            let route = try XCTUnwrap(presentation.makeRoute(assets: assets, initialIndex: index))
            let viewer = AssetViewerHostingController(
                route: route, startsAsContextPreview: false, previewBounds: window.bounds.size,
                session: session, sourceRegistry: registry, album: nil, personID: nil,
                willPresent: { presentation.activate($0, presentsCover: false) },
                didPresent: { _ in opened.append(route.sourceAssetID) },
                didDismiss: { presentation.complete($0); dismissed.append($0) },
                onChange: { _ in }
            )
            viewer.presentDirectly(from: presenter)
        }
        try open(0)
        if !duringOpening {
            await waitUntil { opened.count == 1 }
            XCTAssertEqual(opened, ["first"])
        }
        (presenter.presentedViewController as? AssetViewerHostingController)?.requestDismissal()
        await waitUntil { presenter.presentedViewController == nil && !presentation.isTransitioning }
        XCTAssertNil(presenter.presentedViewController)
        XCTAssertFalse(presentation.isTransitioning, "The grid must be released after the UIKit modal detaches")
        XCTAssertEqual(dismissed.count, 1)
        opened = []
        try open(1)
        await waitUntil { opened == ["second"] }
        XCTAssertEqual(opened, ["second"])
        (presenter.presentedViewController as? AssetViewerHostingController)?.requestDismissal()
        await waitUntil { dismissed.count == 2 }
        XCTAssertEqual(dismissed.count, 2)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func asset(_ id: String) -> Asset {
        Asset(id: id, ownerId: "synthetic", isImage: true, isFavorite: false,
              isTrashed: false, visibility: .timeline, fileCreatedAt: Date(),
              localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
    }
}
