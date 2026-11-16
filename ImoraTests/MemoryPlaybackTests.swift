import AVFoundation
import UIKit
import XCTest
@testable import Imora

@MainActor
final class MemoryPlaybackTests: XCTestCase {
    private func asset(_ id: String = "photo", video: Bool = false, duration: Int? = nil) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: !video, isFavorite: false,
              isTrashed: false, visibility: .timeline, thumbhash: nil, fileCreatedAt: Date(),
              localOffsetHours: 0, duration: duration, livePhotoVideoId: nil, ratio: 1,
              city: nil, country: nil, createdAt: nil)
    }

    func testOwnedMemoryFixtureCanBeReadOnlyOnItsAllocatedSimulator() throws {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "096710F4-E2E2-4F95-AAC2-3489F82B0F74" else {
            throw XCTSkip("Requires the separately allocated memory UI simulator and synthetic fixture.")
        }
        let fixture = try Phase4OwnedFixture.load("memories")
        XCTAssertEqual(fixture.apiURL, "http://127.0.0.1:33284/api")
        XCTAssertEqual(fixture.email, "legacy-ui@imora-phase4-fixture.invalid")
        XCTAssertThrowsError(try Phase4OwnedFixture.load("legacy"))
        #endif
    }

    func testDownloadTimeAndPausedTimeDoNotConsumeSlideDuration() {
        var position = MemoryPlaybackPosition(assets: [asset(), asset("next")])
        position.advance(by: 100)
        XCTAssertEqual(position.elapsed, 0)
        position.isReady = true
        position.advance(by: 2)
        position.isPlaying = false
        position.advance(by: 100)
        XCTAssertEqual(position.elapsed, 2)
        position.isPlaying = true
        XCTAssertTrue(position.advance(by: 3))
        XCTAssertEqual(position.index, 1)
        XCTAssertEqual(position.elapsed, 0)
        XCTAssertFalse(position.isReady)
    }

    func testLastFrameFinishesWithoutWrappingOrLeavingAudioPlaying() {
        var position = MemoryPlaybackPosition(assets: [asset()])
        position.isReady = true
        XCTAssertFalse(position.advance(by: 5))
        XCTAssertTrue(position.isFinished)
        XCTAssertFalse(position.isPlaying)
        XCTAssertEqual(position.progress, 1)
        position.advance(by: 10)
        XCTAssertEqual(position.index, 0)
    }

    func testScrubbingPreservesPauseAndRestartsAtChosenFrame() {
        var position = MemoryPlaybackPosition(assets: [asset(), asset("two"), asset("three")])
        position.isReady = true
        position.advance(by: 3)
        position.isPlaying = false
        XCTAssertTrue(position.select(2))
        XCTAssertEqual(position.index, 2)
        XCTAssertEqual(position.elapsed, 0)
        XCTAssertFalse(position.isPlaying)
        XCTAssertFalse(position.isReady)
    }

    func testInvalidNavigationDoesNotInvalidateTheVisibleFrame() {
        var position = MemoryPlaybackPosition(assets: [asset()])
        position.isReady = true
        position.advance(by: 1)
        let before = position
        XCTAssertFalse(position.select(-1))
        XCTAssertFalse(position.select(1))
        XCTAssertEqual(position, before)
    }

    func testVideoDurationsAreBoundedAndConvertedFromMilliseconds() {
        let position = MemoryPlaybackPosition(assets: [asset(), asset("clip", video: true, duration: 2_500),
            asset("long", video: true, duration: 60_000), asset("invalid", video: true, duration: -1)])
        XCTAssertEqual(position.durations, [5, 2.5, 12, 1])
    }

    func testInvalidClockSamplesDoNotCorruptProgress() {
        var position = MemoryPlaybackPosition(assets: [asset()])
        position.isReady = true
        for delta in [Double.nan, .infinity, -.infinity, -1, 0] { position.advance(by: delta) }
        XCTAssertEqual(position.progress, 0)
    }

    func testEmptyMemoryCannotSelectOrAdvance() {
        var position = MemoryPlaybackPosition(assets: [])
        XCTAssertFalse(position.select(0))
        XCTAssertFalse(position.advance(by: 5))
        XCTAssertEqual(position.progress, 0)
    }

    func testBundledLicensedSoundtrackDecodesAndHasAudibleSamples() throws {
        let url = try XCTUnwrap(MemorySoundtrack.url)
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(player.duration, 60)
        XCTAssertTrue(player.prepareToPlay())
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 441_000))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0, 0.0001)
    }

    func testReplayFromFinishedResetsReadinessBeforeStartingAgain() {
        var position = MemoryPlaybackPosition(assets: [asset()])
        position.isReady = true
        position.advance(by: 5)
        position.isPlaying = true
        XCTAssertTrue(position.select(0))
        XCTAssertFalse(position.isFinished)
        XCTAssertFalse(position.isReady)
        XCTAssertEqual(position.elapsed, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Memory playback did not reach the expected state")
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    func testSwitchDuringDownloadRejectsOldFrameAndStopReleasesMusic() async throws {
        let first = UUID().uuidString, second = UUID().uuidString, data = imageData()
        let gate = DispatchSemaphore(value: 0)
        let server = try LocalHTTPServer { request in
            if request.path.contains(first) { _ = gate.wait(timeout: .now() + 3) }
            return .init(headers: ["Content-Type": "image/png"], body: data)
        }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        let playback = MemorySlideshowPlayback(assets: [asset(first), asset(second)])
        defer { gate.signal(); playback.stop(); ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        playback.start(client: client)
        try await waitUntil { server.received.contains { $0.path.contains(first) } }
        playback.select(1)
        gate.signal()
        try await waitUntil { playback.frame?.id == second && playback.diagnostic.contains("music=true") }
        XCTAssertNil(playback.errorMessage)
        XCTAssertEqual(playback.index, 1)
        playback.stop()
        XCTAssertTrue(playback.diagnostic.contains("music=false"))
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(server.received.contains { $0.path.contains("original") || $0.path.contains("video") })
    }

    func testFailedItemCanBeRetriedOrSkippedWithoutConsumingItsDuration() async throws {
        let bad = UUID().uuidString, good = UUID().uuidString, data = imageData()
        let server = try LocalHTTPServer { request in
            request.path.contains(bad) ? .init(status: 500) : .init(headers: ["Content-Type": "image/png"], body: data)
        }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        let playback = MemorySlideshowPlayback(assets: [asset(bad), asset(good)])
        defer { playback.stop(); ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        playback.start(client: client)
        try await waitUntil { playback.errorMessage != nil }
        XCTAssertEqual(playback.progress, 0)
        XCTAssertTrue(playback.diagnostic.contains("music=false"))
        playback.retry()
        try await waitUntil { playback.errorMessage != nil }
        playback.select(1)
        try await waitUntil { playback.frame?.id == good }
        XCTAssertNil(playback.errorMessage)
        XCTAssertTrue(playback.position.isReady)
    }

    func testMemoryDeduplicatesAssetsAndExcludesLockedAndDeletedItems() throws {
        let base: [String: Any] = ["id": "cover", "ownerId": "fixture", "type": "IMAGE",
            "originalFileName": "synthetic.jpg", "fileCreatedAt": "2026-11-17T00:00:00Z",
            "localDateTime": "2026-11-17T00:00:00Z", "isFavorite": false, "isTrashed": false]
        var locked = base; locked["id"] = "locked"; locked["visibility"] = "locked"
        var deleted = base; deleted["id"] = "deleted"; deleted["isTrashed"] = true
        let object: [String: Any] = ["id": "memory", "type": "on_this_day", "memoryAt": "2026-11-17T00:00:00Z",
            "data": ["year": 2025], "assets": [base, base, locked, deleted]]
        let memory = try JSONDecoder().decode(Memory.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(memory.playableAssets.map(\.id), ["cover"])
        XCTAssertNotEqual(MemorySlideshowRoute(memory: memory).id, MemorySlideshowRoute(memory: memory).id)
    }
}
