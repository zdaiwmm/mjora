import XCTest
@testable import Imora

@MainActor
final class Phase4LiveHoldTests: XCTestCase {
    func testOldMotionCacheCannotAuthorizeAnInaccessiblePhoto() async throws {
        let identifier = "\(UUID().uuidString)/L0/001"
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-photo-motion")
        let oldFile = directory.appending(path: identifier.replacingOccurrences(of: "/", with: "_") + ".mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("owned-stale-motion-fixture".utf8).write(to: oldFile, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: oldFile) }
        let item = await LocalImageLoader.shared.motionPlayerItem(localIdentifier: identifier, allowsNetwork: false)
        XCTAssertNil(item, "A leftover file is neither PhotoKit access nor a current Live source")
    }

    func testDeferredLiveControlsRemainAvailableBeforeThePlayerLoads() {
        func chrome(live: Bool, visible: Bool = true, contextPreview: Bool = false, atMedia: Bool = true) -> AssetViewerChromePresentation {
            .init(isCompact: true, isAtMedia: atMedia, isInformationPresented: !atMedia,
                isChromeVisible: visible, isContextPreview: contextPreview,
                isPlayable: true, isPlayerReady: false, isLivePhoto: live, isMediaZoomed: false)
        }
        XCTAssertTrue(chrome(live: true).showsTransportControls)
        XCTAssertFalse(chrome(live: false).showsTransportControls)
        XCTAssertFalse(chrome(live: true, visible: false).showsTransportControls)
        XCTAssertFalse(chrome(live: true, contextPreview: true).showsTransportControls)
        XCTAssertFalse(chrome(live: true, atMedia: false).showsTransportControls)
    }

    private func context(assetID: String = "live-a", generation: UUID = UUID(), session: UUID = UUID(),
                         active: Bool = true, zoom: Double = 1) -> LiveHoldContext {
        .init(assetID: assetID, pageGeneration: generation, sessionID: session, isActive: active, zoomScale: zoom)
    }

    func testReleaseBeforeLoadDoesNotPlay() throws {
        let controller = LiveHoldController(), context = context()
        XCTAssertTrue(controller.handle(event: .began, context: context).isEmpty)
        let token = try XCTUnwrap(controller.token)
        XCTAssertEqual(controller.handle(event: .recognized, context: context), [.prepare(token)])
        XCTAssertEqual(controller.handle(event: .ended, context: context), [.pause(token), .showPoster(token), .cancelLoad(token)])
        XCTAssertTrue(controller.handle(event: .loadReady(token), context: context).isEmpty)
        XCTAssertEqual(controller.phase, .rest)
    }

    func testReleaseBeforeRecognitionDoesNotRequestMotion() throws {
        let controller = LiveHoldController(), context = context()
        _ = controller.handle(event: .began, context: context)
        let token = try XCTUnwrap(controller.token)
        XCTAssertEqual(controller.handle(event: .ended, context: context), [.pause(token), .showPoster(token), .cancelLoad(token)])
        XCTAssertTrue(controller.handle(event: .recognized, context: context).isEmpty)
        XCTAssertEqual(LiveHoldController.minimumDuration, 0.35)
    }

    func testMoveBeyond10ptYieldsPaging() throws {
        for recognized in [false, true] {
            let controller = LiveHoldController(), context = context()
            _ = controller.handle(event: .began, context: context)
            if recognized { _ = controller.handle(event: .recognized, context: context) }
            let token = try XCTUnwrap(controller.token)
            XCTAssertTrue(controller.handle(event: .moved(distancePt: 10), context: context).isEmpty)
            XCTAssertEqual(controller.handle(event: .moved(distancePt: 10.01), context: context), [.pause(token), .showPoster(token), .cancelLoad(token)])
            XCTAssertTrue(controller.handle(event: .loadReady(token), context: context).isEmpty)
        }
    }

    func testSecondFingerAndLifecycleChangesCancelHold() throws {
        let events: [LiveHoldEvent] = [.secondFinger, .zoomBegan, .pageChanged, .sceneInactive, .cancelled]
        for event in events {
            let controller = LiveHoldController(), context = context()
            _ = controller.handle(event: .began, context: context)
            _ = controller.handle(event: .recognized, context: context)
            let token = try XCTUnwrap(controller.token)
            XCTAssertEqual(controller.handle(event: .loadReady(token), context: context), [.start(token)])
            XCTAssertEqual(controller.handle(event: event, context: context), [.pause(token), .showPoster(token), .cancelLoad(token)])
            XCTAssertEqual(controller.phase, .rest)
        }
    }

    func testVoiceOverPlaybackOwnsSinglePlayer() throws {
        let controller = LiveHoldController(), context = context()
        _ = controller.handle(event: .accessibilityToggle, context: context)
        let persistent = try XCTUnwrap(controller.token)
        XCTAssertEqual(controller.handle(event: .loadReady(persistent), context: context), [.start(persistent)])
        XCTAssertEqual(controller.phase, .playingPersistent)
        XCTAssertEqual(controller.handle(event: .began, context: context), [.pause(persistent), .showPoster(persistent), .cancelLoad(persistent)])
        let held = try XCTUnwrap(controller.token)
        XCTAssertNotEqual(held, persistent)
        _ = controller.handle(event: .recognized, context: context)
        XCTAssertTrue(controller.handle(event: .loadReady(persistent), context: context).isEmpty)
        XCTAssertEqual(controller.token, held)
        XCTAssertEqual(controller.handle(event: .loadReady(held), context: context), [.start(held)])
    }

    func testOldPageAndAccountCannotStartReadyMotion() throws {
        let original = context()
        let replacements = [
            context(assetID: "other", generation: original.pageGeneration, session: original.sessionID),
            context(generation: UUID(), session: original.sessionID),
            context(generation: original.pageGeneration, session: UUID()),
            context(generation: original.pageGeneration, session: original.sessionID, active: false),
            context(generation: original.pageGeneration, session: original.sessionID, zoom: 2)
        ]
        for replacement in replacements {
            let controller = LiveHoldController()
            _ = controller.handle(event: .began, context: original)
            _ = controller.handle(event: .recognized, context: original)
            let token = try XCTUnwrap(controller.token)
            XCTAssertEqual(controller.handle(event: .loadReady(token), context: replacement), [.pause(token), .showPoster(token), .cancelLoad(token)])
            XCTAssertEqual(controller.phase, .rest)
        }
    }

    func testExpensiveAndConstrainedDownloadsRequireConsentAndOfflineNeverDownloads() {
        func path(connected: Bool = true, expensive: Bool = false, constrained: Bool = false) -> NetworkPathSnapshot {
            .init(connected: connected, expensive: expensive, wifi: !expensive, cellular: expensive,
                  constrained: constrained, observedAt: .distantPast)
        }
        XCTAssertTrue(LiveNetworkPolicy.allows(path(), consent: false))
        for restricted in [path(expensive: true), path(constrained: true)] {
            XCTAssertFalse(LiveNetworkPolicy.allows(restricted, consent: false))
            XCTAssertTrue(LiveNetworkPolicy.allows(restricted, consent: true))
        }
        XCTAssertFalse(LiveNetworkPolicy.allows(path(connected: false), consent: false))
        XCTAssertFalse(LiveNetworkPolicy.allows(path(connected: false), consent: true))
    }

    func testNormalEndRequiresANewPress() throws {
        let controller = LiveHoldController(), context = context()
        _ = controller.handle(event: .began, context: context)
        _ = controller.handle(event: .recognized, context: context)
        let token = try XCTUnwrap(controller.token)
        _ = controller.handle(event: .loadReady(token), context: context)
        _ = controller.handle(event: .playbackEnded, context: context)
        XCTAssertTrue(controller.handle(event: .recognized, context: context).isEmpty)
        _ = controller.handle(event: .began, context: context)
        XCTAssertNotEqual(controller.token, token)
    }
}
