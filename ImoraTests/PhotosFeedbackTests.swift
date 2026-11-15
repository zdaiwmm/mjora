import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotosFeedbackTests: XCTestCase {
    func testReturningToNewestEdgeRestoresNavigationEvenAfterSmallScrollSteps() {
        let controls = PhotosGridControls()
        controls.observeScroll(offset: 2_000, endOffset: 2_000, isUserScrolling: false)
        for offset in stride(from: 1_998, through: 1_900, by: -2) {
            controls.observeScroll(offset: CGFloat(offset), endOffset: 2_000, isUserScrolling: true)
        }
        XCTAssertTrue(controls.browsingPast, "Slow drags must enter date browsing too")
        controls.observeScroll(offset: 1_999, endOffset: 2_000, isUserScrolling: true)
        XCTAssertFalse(controls.browsingPast, "Newest edge must restore Photos/Albums")
    }

    func testShortLibraryBounceKeepsPhotosAndAlbumsNavigation() {
        let controls = PhotosGridControls()
        controls.observeScroll(offset: 0, endOffset: 0, isUserScrolling: false)
        controls.observeScroll(offset: -24, endOffset: 0, isUserScrolling: true)
        XCTAssertFalse(controls.browsingPast)
    }

    func testInsetChangesAndRestorationDoNotEnterDateBrowsing() {
        let controls = PhotosGridControls()
        controls.observeScroll(offset: 2_000, endOffset: 2_000, isUserScrolling: false)
        controls.observeScroll(offset: 1_900, endOffset: 1_900, isUserScrolling: false)
        XCTAssertFalse(controls.browsingPast)
        controls.browsingPast = true
        controls.observeScroll(offset: 1_900, endOffset: 1_900, isUserScrolling: false)
        XCTAssertFalse(controls.browsingPast)
        controls.isRestoring = true
        controls.observeScroll(offset: 100, endOffset: 1_900, isUserScrolling: true)
        XCTAssertFalse(controls.browsingPast)
    }

    func testFirstSelectionIndicatorHasFinalFrameBeforeItIsRevealed() throws {
        let tile = TimelineTileView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        tile.isSelectable = true
        tile.layoutIfNeeded()
        tile.updateSelectionAppearance(isSelecting: true)
        let indicator = try XCTUnwrap(tile.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(indicator.frame, CGRect(x: 90, y: 90, width: 24, height: 24))
        XCTAssertFalse(indicator.isHidden)
    }

    func testLivePhotoKeepsDecoderSurfaceMountedBehindStill() async throws {
        let playback = VideoPlayback()
        await playback.claim(assetID: "live", forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true) {
            AVPlayerItem(asset: AVMutableComposition())
        }
        let host = UIHostingController(rootView: MediaSurfaceStack(
            assetID: "live", aspectRatio: 1, mode: .livePhoto,
            posterLocalIdentifier: nil, posterURL: nil, posterFallbackURL: nil,
            thumbhash: nil, playback: playback))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; playback.release(assetID: "live") }
        host.view.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        func playerLayers(in view: UIView) -> [AVPlayerLayer] {
            (view.layer as? AVPlayerLayer).map { [$0] } ?? view.subviews.flatMap { playerLayers(in: $0) }
        }
        XCTAssertFalse(playback.isEngaged)
        XCTAssertEqual(playerLayers(in: host.view).count, 1,
                       "Still/clip switching must not create and destroy the decoding layer")
    }

    func testCollectionsMemoriesQueryIncludesExistingMemoriesOutsideTodayWindow() async throws {
        let server = try LocalHTTPServer { _ in .init(body: Data("[]".utf8)) }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        _ = try await client.memories()
        let request = try XCTUnwrap(server.received.first { $0.path.hasPrefix("/api/memories") })
        let url = try XCTUnwrap(URLComponents(string: "http://127.0.0.1" + request.path))
        XCTAssertFalse(url.queryItems?.contains { $0.name == "for" } ?? false)
        XCTAssertEqual(url.queryItems?.first { $0.name == "isUpcoming" }?.value, "false")
    }

    func testPreparedLivePhotoAdvancesAndReplaysUsingTheSamePlayer() async throws {
        let manifest = URL(fileURLWithPath: "/private/tmp/imora-341-ios-fixture.json")
        guard let bytes = try? Data(contentsOf: manifest),
              let fixture = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              fixture["apiURL"] as? String == "http://127.0.0.1:32283/api",
              let path = fixture["motionPath"] as? String,
              path.hasPrefix("/private/tmp/imora-ios-fixture-media-")
        else { throw XCTSkip("Prepare the dedicated synthetic motion fixture first.") }
        let playback = VideoPlayback()
        let url = URL(fileURLWithPath: path)
        await playback.claim(assetID: "synthetic-live", forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) {
            AVPlayerItem(url: url)
        }
        defer { playback.reload(assetID: "synthetic-live") }
        playback.prepareLocalItem(AVPlayerItem(url: url), assetID: "synthetic-live")
        let player = try XCTUnwrap(playback.player)
        XCTAssertFalse(playback.isEngaged)
        for _ in 0..<2 {
            playback.togglePlayPause()
            for _ in 0..<150 where playback.currentTime < 0.1 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let start = playback.currentTime
            XCTAssertGreaterThan(start, 0.09)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(playback.currentTime, start)
            XCTAssertTrue(playback.player === player)
            for _ in 0..<150 where playback.isEngaged || playback.isPlaying {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(playback.isEngaged)
            XCTAssertTrue(playback.player === player)
        }
    }
}
