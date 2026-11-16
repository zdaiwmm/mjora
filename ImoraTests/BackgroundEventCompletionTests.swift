import XCTest
@testable import Imora

@MainActor
final class BackgroundEventCompletionTests: XCTestCase {
    func testSystemEventCompletionRemainsBoundedWhenReceiptRecoveryIsBlocked() async throws {
        let uploader = BackgroundUploader.shared
        let journal = UploadJournal()
        let gate = ReceiptReplayHold()
        let ticket = BackgroundUploader.Ticket(account: "event-fixture", localId: UUID().uuidString,
            isMotion: false, bodyPath: "/synthetic-event-fixture")
        try journal.complete(.init(ticket: ticket, remoteId: "synthetic-event-asset"))
        defer {
            uploader.setOrphanHandler(nil)
            journal.acknowledge(ticket)
            Task { await gate.release() }
        }
        uploader.setOrphanHandler { _ in await gate.wait(); return [] }
        let completed = expectation(description: "System completion remains bounded")
        var count = 0
        uploader.setBackgroundCompletionHandler(.init(run: { count += 1; completed.fulfill() }),
            identifier: BackgroundUploader.sealedSessionID)
        uploader.receivedSealedEvents()
        await fulfillment(of: [completed], timeout: 25)
        let blocked = await gate.waitingCount
        XCTAssertGreaterThan(blocked, 0, "Receipt recovery must still be blocked at the deadline")
        await gate.release()
        await Task.yield()
        XCTAssertEqual(count, 1)
    }
}

private actor ReceiptReplayHold {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0
    func wait() async {
        guard !open else { return }
        waitingCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}
