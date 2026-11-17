import UIKit
import SwiftUI
import XCTest
import Synchronization
@testable import Imora

@MainActor
final class AssetViewerCarouselTests: XCTestCase {
    func testFailedThumbnailCanRetryThroughItsAccessibleCell() async throws {
        let failing = Mutex(true)
        let userID = "strip-retry-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") {
                return failing.withLock { $0 } ? .init(status: 503)
                    : .init(headers: ["Content-Type": "image/png"], body: bytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "synthetic-strip-retry", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        addTeardownBlock { await session.logOut(reportRemoteFailure: false) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = AssetViewerCarouselCollectionView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 52)
        controller.view.addSubview(view)
        let value = photo(0)
        view.apply(assets: [value], indexByID: [value.id: 0], selection: value.id,
            session: session, reduceMotion: true, aspectRatio: { $0.ratio })
        view.layoutIfNeeded()
        let cell = try XCTUnwrap(view.cellForItem(at: IndexPath(item: 0, section: 0)))
        for _ in 0..<100 {
            if cell.accessibilityCustomActions?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(cell.accessibilityValue)
        XCTAssertFalse(cell.accessibilityCustomActions?.isEmpty ?? true)
        let before = server.received.filter { $0.path.contains("/thumbnail") }.count
        failing.withLock { $0 = false }
        XCTAssertTrue(cell.accessibilityActivate())
        for _ in 0..<100 {
            if cell.accessibilityValue == nil && server.received.filter({ $0.path.contains("/thumbnail") }).count > before { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(server.received.filter { $0.path.contains("/thumbnail") }.count, before)
        XCTAssertNil(cell.accessibilityValue, "The actual recovered bitmap replaces the retry state")
        view.collectionView(view, didEndDisplaying: cell, forItemAt: IndexPath(item: 0, section: 0))
        XCTAssertNil(cell.accessibilityLabel, "Offscreen cells release their image request and represented photo")
    }

    func testViewerShellMountsTheSelectedThumbnailBeforeMediaActivation() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let session = SessionStore()
        for (run, count) in [12_000, 120, 12_000, 120, 12_000, 120].enumerated() {
            let window = UIWindow(windowScene: scene)
            let assets = (0..<count).map(photo)
            let selected = count - min(1_000, count / 4)
            let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
            let shell = AssetViewerScreen(assets: assets, indexByAssetID: index, initialIndex: selected,
                presentationID: UUID(), loadsViewerContent: false, usesExternalBackdrop: true,
                onDismissed: {}, onChange: { _ in }).environment(session)
            let start = ContinuousClock.now
            let host = UIHostingController(rootView: shell)
            let initialized = ContinuousClock.now
            window.rootViewController = host
            let assigned = ContinuousClock.now
            window.makeKeyAndVisible()
            let appeared = ContinuousClock.now
            host.view.layoutIfNeeded()
            let laidOut = ContinuousClock.now
            func carousel(in view: UIView) -> AssetViewerCarouselCollectionView? {
                if let carousel = view as? AssetViewerCarouselCollectionView { return carousel }
                return view.subviews.lazy.compactMap { carousel(in: $0) }.first
            }
            let strip = try XCTUnwrap(carousel(in: host.view))
            XCTAssertTrue(strip.indexPathsForVisibleItems.contains(IndexPath(item: selected, section: 0)))
            XCTAssertLessThan(strip.visibleCells.count, 24)
            print("VIEWER_CHROME_SHELL run=\(run) count=\(count) init=\(start.duration(to: initialized)) root=\(initialized.duration(to: assigned)) appear=\(assigned.duration(to: appeared)) layout=\(appeared.duration(to: laidOut)) total=\(start.duration(to: laidOut))")
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    func testInitialVideoDurationIsAvailableWithoutStartingMediaWork() {
        let playback = VideoPlayback(seedDuration: 42)
        XCTAssertEqual(playback.duration, 42)
        XCTAssertNil(playback.player)
        XCTAssertNil(playback.ownerID)
        XCTAssertEqual(VideoPlayback(seedDuration: .nan).duration, 0)
    }

    func testDistantInitialSelectionRealizesOnlyVisibleThumbnails() throws {
        let assets = (0..<12_000).map(photo)
        let view = AssetViewerCarouselCollectionView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 52)
        let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        var ratioRequests: [String] = []
        view.apply(assets: assets, indexByID: index, selection: assets[11_000].id,
                   session: SessionStore(), reduceMotion: true) {
            ratioRequests.append($0.id)
            return $0.ratio
        }
        view.layoutIfNeeded()
        let paths = view.indexPathsForVisibleItems
        XCTAssertTrue(paths.contains(IndexPath(item: 11_000, section: 0)))
        XCTAssertLessThan(paths.count, 24)
        XCTAssertTrue(ratioRequests.allSatisfy { $0 == assets[11_000].id })
        XCTAssertFalse(ratioRequests.isEmpty)
        let frame = try XCTUnwrap(view.layoutAttributesForItem(at: IndexPath(item: 11_000, section: 0))).frame
        XCTAssertEqual(frame.midX - view.contentOffset.x, view.bounds.width / 2, accuracy: 0.5 / max(1, view.traitCollection.displayScale) + 0.0001)
    }

    func testFirstLastAndResizedSelectionsRemainCentered() throws {
        let assets = (0..<80).map(photo)
        let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        let session = SessionStore(), view = AssetViewerCarouselCollectionView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 52)
        for selected in [0, 79, 40] {
            view.apply(assets: assets, indexByID: index, selection: assets[selected].id,
                       session: session, reduceMotion: true, aspectRatio: { $0.ratio })
            view.layoutIfNeeded()
            let attributes = try XCTUnwrap(view.layoutAttributesForItem(at: IndexPath(item: selected, section: 0)))
            XCTAssertEqual(attributes.frame.midX - view.contentOffset.x, view.bounds.width / 2, accuracy: 0.5 / max(1, view.traitCollection.displayScale) + 0.0001)
        }
        view.frame.size.width = 700
        view.layoutIfNeeded()
        let frame = try XCTUnwrap(view.layoutAttributesForItem(at: IndexPath(item: 40, section: 0))).frame
        XCTAssertEqual(frame.midX - view.contentOffset.x, 350, accuracy: 0.5 / max(1, view.traitCollection.displayScale) + 0.0001)
    }

    func testDraggingScrubsThePagerAndReleasingCentersItsCurrentPhoto() throws {
        let assets = (0..<80).map(photo)
        let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        let session = SessionStore(), view = AssetViewerCarouselCollectionView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 52)
        view.apply(assets: assets, indexByID: index, selection: assets[40].id,
                   session: session, reduceMotion: true, aspectRatio: { $0.ratio })
        view.layoutIfNeeded()
        var selected: [String] = []
        view.onSelection = { selected.append($0) }
        view.scrollViewWillBeginDragging(view)
        let frame = try XCTUnwrap(view.layoutAttributesForItem(at: IndexPath(item: 47, section: 0))).frame
        view.contentOffset.x = frame.midX - view.bounds.width / 2
        view.scrollViewDidScroll(view)
        XCTAssertEqual(selected.last, assets[47].id)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        view.layoutIfNeeded()
        let expanded = try XCTUnwrap(view.layoutAttributesForItem(at: IndexPath(item: 47, section: 0))).frame
        XCTAssertGreaterThan(expanded.width, 18)
        XCTAssertEqual(expanded.midX - view.contentOffset.x, view.bounds.width / 2, accuracy: 0.5 / max(1, view.traitCollection.displayScale) + 0.0001)
        let cell = try XCTUnwrap(view.cellForItem(at: IndexPath(item: 48, section: 0)))
        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(selected.last, assets[48].id)
    }

    func testRightToLeftLayoutPreservesPhotoIdentityAndEndpointCentering() {
        for index in [0, 47, 99_999] {
            let geometry = AssetViewerCarouselGeometry(count: 100_000, expandedIndex: index,
                expandedAspectRatio: 1.6, viewportWidth: 393, isRightToLeft: true)
            let frame = geometry.frame(at: index)
            XCTAssertEqual(geometry.index(nearest: frame.midX), index)
            XCTAssertEqual(frame.midX - geometry.offset(centering: index), 196.5, accuracy: 0.01)
            let visible = CGRect(x: geometry.offset(centering: index), y: 0, width: 393, height: 52)
            XCTAssertTrue(geometry.indices(intersecting: visible).contains(index))
            XCTAssertLessThan(geometry.indices(intersecting: visible).count, 24)
        }
    }

    func testDeletionAndEmptyLibraryDuringScrubbingKeepTheLayoutWithinTheNewLibrary() throws {
        var assets = (0..<80).map(photo)
        let session = SessionStore(), view = AssetViewerCarouselCollectionView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 52)
        func apply(_ selection: String?) {
            let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
            view.apply(assets: assets, indexByID: index, selection: selection,
                       session: session, reduceMotion: true, aspectRatio: { $0.ratio })
            view.layoutIfNeeded()
        }
        apply(assets[78].id)
        view.scrollViewWillBeginDragging(view)
        let selected = assets[78].id
        assets.removeFirst(60)
        apply(selected)
        XCTAssertTrue(view.indexPathsForVisibleItems.allSatisfy { $0.item < assets.count })
        let selectedPath = IndexPath(item: 18, section: 0)
        XCTAssertTrue(view.indexPathsForVisibleItems.contains(selectedPath))
        XCTAssertEqual(try XCTUnwrap(view.layoutAttributesForItem(at: selectedPath)).frame.midX - view.contentOffset.x,
                       view.bounds.width / 2, accuracy: 0.5 / max(1, view.traitCollection.displayScale) + 0.0001)
        view.scrollViewWillBeginDragging(view)
        assets = []
        apply(nil)
        XCTAssertTrue(view.indexPathsForVisibleItems.isEmpty)
        XCTAssertEqual(view.numberOfItems(inSection: 0), 0)
        XCTAssertEqual(view.contentOffset.x, 0)
    }

    private func photo(_ index: Int) -> Asset {
        Asset(id: "strip-\(index)", ownerId: "synthetic", isImage: true,
              isFavorite: false, isTrashed: false, visibility: .timeline,
              fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
              localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1.5, city: nil, country: nil)
    }
}
