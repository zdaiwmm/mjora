import XCTest
@testable import Imora

final class ThumbnailTerminalStateTests: XCTestCase {
    func testLatePreviewAndUndersizedFinalKeepRetryAfterRemoteExhaustion() {
        var state = ThumbnailLoadState(hasLocal: true, hasRemote: true, targetPixels: 300)
        XCTAssertEqual(state.localDeadline(), .thumbnail)
        XCTAssertEqual(state.remoteResult(pixels: nil, isPreview: false), .preview)
        XCTAssertEqual(state.remoteResult(pixels: nil, isPreview: true), .none)
        XCTAssertEqual(state.phase, .retry)
        state.localPreview()
        XCTAssertEqual(state.phase, .retry)
        _ = state.localUnavailable()
        XCTAssertEqual(state.phase, .retry)
        _ = state.localFinal(pixels: 30, originalPixels: 3000)
        XCTAssertEqual(state.phase, .retry)
        XCTAssertEqual(state.localFinal(pixels: 300, originalPixels: 3000), .finished)
        XCTAssertEqual(state.phase, .ready)
    }
}
