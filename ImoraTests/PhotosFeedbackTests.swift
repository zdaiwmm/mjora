import AVFoundation
import CryptoKit
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
        XCTAssertTrue(tile.subviews.compactMap { $0 as? UIImageView }.allSatisfy(\.isHidden),
                      "Entering selection must not draw empty circles")
        tile.isSelected = true
        tile.updateSelectionAppearance(isSelecting: true)
        let indicator = try XCTUnwrap(tile.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(indicator.frame, CGRect(x: 90, y: 90, width: 24, height: 24))
        XCTAssertFalse(indicator.isHidden)
        tile.isSelected = false
        tile.updateSelectionAppearance(isSelecting: true)
        XCTAssertTrue(indicator.isHidden)
    }

    func testFavoritesFilterDoesNotRequestPartnerAssets() {
        let favorites = PhotosLaunchSelection.cloudFilter(mergesSharedSpaces: false, favorites: true)
        XCTAssertEqual(favorites.isFavorite, true)
        XCTAssertFalse(favorites.withPartners, "Immich rejects favorite time buckets with partner assets")
        XCTAssertFalse(favorites.queryItems.contains { $0.name == "withPartners" })
        XCTAssertTrue(PhotosLaunchSelection.cloudFilter(mergesSharedSpaces: false).withPartners)
    }

    func testRetiredThumbnailOffersRetryWithoutBlockingTheOtherInitialPhotos() {
        let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let asset = Asset(id: "retry-\(UUID())", ownerId: "fixture", isImage: true, isFavorite: false,
                          isTrashed: false, visibility: .timeline, thumbhash: "retired",
                          fileCreatedAt: .now, localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 416)
        _ = ImageLoader.shared.invalidateSubjects(client: client, subjects: [key.subject], keys: [key])
        let tile = TimelineTileView(frame: CGRect(x: 0, y: 0, width: 132, height: 132))
        tile.projectImage(asset: asset, source: .init(assetID: asset.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: 416)
        XCTAssertTrue(tile.initialDisplayIsReady)
        XCTAssertFalse(tile.hasPreparedInitialImage)
        XCTAssertFalse(tile.initialImageIsCurrent)
        XCTAssertTrue(tile.subviews.compactMap { $0 as? UIButton }.contains { !$0.isHidden })
    }

    func testToastExpiresWithoutAMountedHostAndAdvancesQueue() async throws {
        let center = ErrorToastCenter(duration: .milliseconds(60))
        center.show("First", style: .information)
        center.show("Second", style: .information)
        center.show("First", style: .information)
        let first = try XCTUnwrap(center.current?.id)
        for _ in 0..<100 where center.current?.id == first { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(center.current?.message, "Second")
        center.dismiss(first)
        XCTAssertEqual(center.current?.message, "Second", "A stale host cannot dismiss a newer toast")
        for _ in 0..<100 where center.current != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(center.current)
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

    private func ownedMotionURL() throws -> URL {
        let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
        let manifest = root.appending(path: "native-integration-fixture.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw XCTSkip("Prepare the dedicated local Immich 3.4.1 iOS fixture first.")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber
        guard manifest.resolvingSymlinksInPath().path == manifest.path, permissions?.intValue == 0o600,
              let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              fixture["apiURL"] as? String == "http://127.0.0.1:33284/api",
              let email = fixture["email"] as? String, email.hasSuffix("@imora-phase4-fixture.invalid"),
              let owner = fixture["ownerID"] as? String, UUID(uuidString: owner) != nil,
              let path = fixture["motionPath"] as? String,
              let expected = fixture["motionChecksum"] as? String else { throw ServerTrustError.untrustedTarget }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path == root.appending(path: "services/video-media/live-motion.mov").resolvingSymlinksInPath().path else {
            throw ServerTrustError.untrustedTarget
        }
        let actual = Insecure.SHA1.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == expected.lowercased() else { throw ServerTrustError.untrustedTarget }
        return url
    }

    func testOwnedMotionFixtureGuard() throws {
        let url = try ownedMotionURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLiveHoldReleasedBeforeDeferredItemRejectsActualLateMovie() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        var pending: CheckedContinuation<AVPlayerItem?, Never>?
        await playback.claim(assetID: "held-synthetic-live", forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) {
            await withCheckedContinuation { pending = $0 }
        }
        let context = LiveHoldContext(assetID: "held-synthetic-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        playback.configureLiveHold(context: context, isAuthorized: { true })
        defer { pending?.resume(returning: nil); playback.reload(assetID: context.assetID) }
        playback.handleLiveHold(.began, context: context)
        playback.handleLiveHold(.recognized, context: context)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let delivery = try XCTUnwrap(pending); pending = nil
        XCTAssertTrue(playback.isBuffering)
        playback.handleLiveHold(.ended, context: context)
        XCTAssertFalse(playback.isBuffering); XCTAssertFalse(playback.isEngaged)
        delivery.resume(returning: AVPlayerItem(url: url))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(playback.player, "A real movie arriving after release must not even install an old player")
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(playback.isEngaged)
    }

    func testLiveHoldStopsActualPreparedPlayerAndOldPageCannotStopNewPress() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        let context = LiveHoldContext(assetID: "prepared-synthetic-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) { AVPlayerItem(url: url) }
        playback.configureLiveHold(context: context, isAuthorized: { true })
        playback.prepareLiveItem(AVPlayerItem(url: url), assetID: context.assetID)
        let player = try XCTUnwrap(playback.player)
        defer { playback.reload(assetID: context.assetID) }
        playback.handleLiveHold(.began, context: context)
        playback.handleLiveHold(.recognized, context: context)
        for _ in 0..<150 where playback.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(playback.currentTime, 0.09); XCTAssertTrue(playback.isEngaged)
        playback.handleLiveHold(.ended, context: context)
        XCTAssertEqual(player.rate, 0); XCTAssertFalse(playback.isEngaged); XCTAssertFalse(playback.isPlaying)

        let newer = LiveHoldContext(assetID: context.assetID, pageGeneration: UUID(), sessionID: context.sessionID, isActive: true, zoomScale: 1)
        playback.configureLiveHold(context: newer, isAuthorized: { true })
        playback.handleLiveHold(.began, context: newer)
        playback.handleLiveHold(.recognized, context: newer)
        for _ in 0..<150 where !playback.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(playback.player === player); XCTAssertGreaterThan(player.rate, 0)
        playback.releaseLivePage(assetID: context.assetID, pageGeneration: context.pageGeneration)
        XCTAssertGreaterThan(player.rate, 0, "An old page's teardown must not pause the newer page's player")
        playback.releaseLivePage(assetID: newer.assetID, pageGeneration: newer.pageGeneration)
        XCTAssertEqual(player.rate, 0); XCTAssertFalse(playback.isEngaged)
    }

    func testFailedLivePlayerCanRetryTheSameSource() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        let missing = URL(fileURLWithPath: "/private/tmp/imora-phase4-missing-live-\(UUID()).mov")
        var attempts = 0
        let context = LiveHoldContext(assetID: "retry-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) {
            attempts += 1
            return AVPlayerItem(url: attempts == 1 ? missing : url)
        }
        playback.configureLiveHold(context: context, isAuthorized: { true })
        defer { playback.reload(assetID: context.assetID) }
        playback.togglePlayPause()
        for _ in 0..<200 where !playback.isFailed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(playback.isFailed); XCTAssertEqual(attempts, 1)
        XCTAssertFalse(playback.isEngaged)
        playback.togglePlayPause()
        for _ in 0..<200 where playback.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(attempts, 2)
        XCTAssertGreaterThan(playback.currentTime, 0.09)
        XCTAssertTrue(playback.isEngaged); XCTAssertFalse(playback.isFailed)
        playback.cancelLivePlayback()
        XCTAssertEqual(playback.player?.rate, 0)
    }

    func testNormalLiveEndRestoresPosterAndNewPressReplays() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        let context = LiveHoldContext(assetID: "ending-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) { AVPlayerItem(url: url) }
        playback.configureLiveHold(context: context, isAuthorized: { true })
        defer { playback.reload(assetID: context.assetID) }
        playback.handleLiveHold(.began, context: context)
        playback.handleLiveHold(.recognized, context: context)
        for _ in 0..<200 where playback.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(playback.currentTime, 0.09)
        for _ in 0..<250 where playback.isEngaged { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(playback.isEngaged); XCTAssertEqual(playback.player?.rate, 0)
        playback.handleLiveHold(.recognized, context: context)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(playback.isEngaged, "The still-held token must not loop automatically")
        playback.handleLiveHold(.ended, context: context)
        playback.handleLiveHold(.began, context: context)
        playback.handleLiveHold(.recognized, context: context)
        for _ in 0..<200 where playback.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(playback.currentTime, 0.09); XCTAssertTrue(playback.isEngaged)
    }

    func testRevokedLiveAuthorizationRejectsActualDeferredMovie() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        var pending: CheckedContinuation<AVPlayerItem?, Never>?, authorized = true
        let context = LiveHoldContext(assetID: "revoked-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) {
            await withCheckedContinuation { pending = $0 }
        }
        playback.configureLiveHold(context: context, isAuthorized: { authorized })
        defer { pending?.resume(returning: nil); playback.reload(assetID: context.assetID) }
        playback.togglePlayPause()
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let delivery = try XCTUnwrap(pending); pending = nil
        authorized = false
        delivery.resume(returning: AVPlayerItem(url: url))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(playback.player); XCTAssertFalse(playback.isEngaged)
        playback.cancelLivePlayback()
        XCTAssertFalse(playback.isBuffering)
    }

    func testLiveMeteredConsentEndsWithItsPage() async {
        let playback = VideoPlayback()
        let context = LiveHoldContext(assetID: "consent-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) { nil }
        playback.configureLiveHold(context: context, isAuthorized: { true })
        defer { playback.reload(assetID: context.assetID) }
        playback.allowLiveDownloadAndPlay()
        XCTAssertTrue(playback.permitsExpensiveLiveDownload)
        playback.releaseLivePage(assetID: context.assetID, pageGeneration: context.pageGeneration)
        XCTAssertFalse(playback.permitsExpensiveLiveDownload)
    }

    func testPreparedLivePhotoAdvancesAndReplaysUsingTheSamePlayer() async throws {
        let url = try ownedMotionURL()
        let playback = VideoPlayback()
        await playback.claim(assetID: "synthetic-live", forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) {
            AVPlayerItem(url: url)
        }
        defer { playback.reload(assetID: "synthetic-live") }
        playback.prepareLiveItem(AVPlayerItem(url: url), assetID: "synthetic-live")
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

    func testLoopLivePhotoRestartsAndSwitchingOffStopsThePreparedPlayer() async throws {
        let url = try ownedMotionURL(), playback = VideoPlayback()
        let context = LiveHoldContext(assetID: "loop-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        await playback.claim(assetID: context.assetID, forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) { AVPlayerItem(url: url) }
        defer { playback.reload(assetID: context.assetID) }
        playback.configureLiveHold(context: context, isAuthorized: { true })
        playback.prepareLiveItem(AVPlayerItem(url: url), assetID: context.assetID)
        let player = try XCTUnwrap(playback.player)
        playback.setLiveMode(.loop)
        var reachedEnd = false, restarted = false
        for _ in 0..<250 {
            try await Task.sleep(for: .milliseconds(20))
            if playback.duration > 0, playback.currentTime > playback.duration * 0.75 { reachedEnd = true }
            if reachedEnd, playback.currentTime < playback.duration * 0.25, playback.isEngaged { restarted = true; break }
        }
        XCTAssertTrue(restarted, "Loop must cross the end and restart the same prepared movie")
        XCTAssertTrue(playback.player === player)
        playback.setLiveMode(.off)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(playback.isEngaged)
    }
}

@MainActor
final class PhotosPolishTests: XCTestCase {
    func testBounceCannotBeSelectedBeforeReverseDecodingIsAvailable() {
        let playback = VideoPlayback()
        XCTAssertFalse(playback.canBounce)
        playback.setLiveMode(.bounce)
        XCTAssertEqual(playback.liveMode, .live)
    }

    func testChinesePlaceNamesAreSharedOfflineAndPreserveWireValues() throws {
        let zh = Locale(identifier: "zh_Hans_CN")
        XCTAssertTrue(PhotoPlaceName.localized("Hangzhou", locale: zh).hasPrefix("杭州"))
        XCTAssertTrue(PhotoPlaceName.localized("Hángzhōu", locale: zh).hasPrefix("杭州"))
        XCTAssertEqual(PhotoPlaceName.localized("Chengdu", locale: zh), "成都")
        XCTAssertEqual(PhotoPlaceName.localized("Suzhou", locale: zh), "苏州")
        XCTAssertEqual(PhotoPlaceName.localized("China", locale: zh), "中国")
        XCTAssertEqual(PhotoPlaceName.localized("CN", locale: zh), "中国")
        XCTAssertEqual(PhotoPlaceName.localized("Unknown village", locale: zh), "Unknown village")
        XCTAssertEqual(PhotoPlaceName.localized("Hangzhou", country: "United States", locale: zh), "Hangzhou")
        XCTAssertEqual(PhotoPlaceName.localized("Hangzhou", locale: Locale(identifier: "en_US")), "Hangzhou")
        XCTAssertEqual(PhotoPlaceName.title(city: " ", country: "China", locale: zh), "中国")
        XCTAssertNil(PhotoPlaceName.title(city: nil, country: nil, locale: zh))
        var filter = SearchFilter()
        filter.city = .value("Hangzhou")
        XCTAssertEqual(filter.city?.wireValue, "Hangzhou", "Localized presentation must not change the server filter")
    }

    func testLiveModesStopPlaybackAndOffIgnoresPresses() async {
        let playback = VideoPlayback()
        await playback.claim(assetID: "polish-live", forceMuted: true, seedDuration: nil,
                             autoPlays: false, rewindsAtEnd: true, defersItem: true) { nil }
        let context = LiveHoldContext(assetID: "polish-live", pageGeneration: UUID(), sessionID: UUID(), isActive: true, zoomScale: 1)
        playback.configureLiveHold(context: context, isAuthorized: { true })
        playback.setLiveMode(.off)
        playback.handleLiveHold(.began, context: context)
        playback.handleLiveHold(.recognized, context: context)
        XCTAssertFalse(playback.isEngaged)
        XCTAssertFalse(playback.isBuffering)
        XCTAssertEqual(playback.liveMode, .off)
        playback.setLiveMode(.live)
        XCTAssertEqual(playback.liveMode, .live)
    }
}
