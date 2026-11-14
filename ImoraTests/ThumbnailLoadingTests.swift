import Foundation
import XCTest
@testable import Imora

final class ThumbnailLoadingTests: XCTestCase {
    func testDegradedOnlyStartsServerAtDeadlineAndKeepsLocalAlive() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 600)
        state.localPreview()
        XCTAssertEqual(state.phase, .preview)
        XCTAssertEqual(state.localDeadline(), .thumbnail)
        XCTAssertEqual(state.localDeadline(), .none)
        XCTAssertEqual(state.localFinal(pixels: 600, originalPixels: 4000), .finished)
        XCTAssertEqual(state.phase, .ready)
    }

    func testDegradedThenTerminalImmediatelyTriesServer() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 600)
        state.localPreview()
        XCTAssertEqual(state.localUnavailable(), .thumbnail)
        XCTAssertEqual(state.phase, .preview)
    }

    func testUndersizedFinalDoesNotBecomeSuccessfulAndUpgradesOnlyOnce() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 600)
        XCTAssertEqual(state.localFinal(pixels: 120, originalPixels: 4000), .thumbnail)
        XCTAssertEqual(state.remoteResult(pixels: 256, isPreview: false), .preview)
        XCTAssertEqual(state.remoteResult(pixels: 400, isPreview: true), .finished)
        XCTAssertEqual(state.remoteResult(pixels: 256, isPreview: false), .none)
    }

    func testServerFailureTriesPreviewAndFailureRemainsRetryable() {
        var state = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: 600)
        XCTAssertEqual(state.remoteResult(pixels: nil, isPreview: false), .preview)
        XCTAssertEqual(state.remoteResult(pixels: nil, isPreview: true), .none)
        XCTAssertEqual(state.phase, .retry)
        XCTAssertEqual(state.remoteResult(pixels: 600, isPreview: true), .finished)
    }

    func testOffscreenCancellationRejectsLateLocalAndRemoteCompletions() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 600)
        state.cancel()
        XCTAssertEqual(state.localDeadline(), .none)
        XCTAssertEqual(state.localFinal(pixels: 600, originalPixels: 4000), .none)
        XCTAssertEqual(state.remoteResult(pixels: 600, isPreview: true), .none)
        XCTAssertEqual(state.phase, .cancelled)
    }

    func testSmallOriginalIsTerminalWithoutUpgrade() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 600)
        XCTAssertEqual(state.localFinal(pixels: 120, originalPixels: 120), .finished)
        XCTAssertEqual(state.localDeadline(), .none)
    }

    func testCloudOnlyLocalKeepsPreviewAndOffersRetry() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: false, targetPixels: 600)
        state.localPreview()
        XCTAssertEqual(state.localDeadline(), .none)
        XCTAssertEqual(state.phase, .retry)
    }

    func testPrefetchBoundsAreOneActualScreenOnEachSide() {
        XCTAssertEqual(ThumbnailLoadState.prefetchWindow(visible: 30..<50, count: 100), 10..<70)
        XCTAssertEqual(ThumbnailLoadState.prefetchWindow(visible: 0..<8, count: 100), 0..<16)
    }
}

extension ThumbnailLoadingTests {
    func testFourLoadsBoundConcurrencyAndCancelledWaiterNeverStarts() async throws {
        let limiter = ThumbnailLoadLimiter(limit: 4)
        var permits: [UUID] = []
        for _ in 0..<4 { permits.append(try await limiter.acquire()) }
        let fifth = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        fifth.cancel()
        do { _ = try await fifth.value; XCTFail("Cancelled queued load started") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await limiter.release(permits[0])
        let replacement = try await limiter.acquire()
        await limiter.release(replacement)
        for permit in permits.dropFirst() { await limiter.release(permit) }
    }
}
