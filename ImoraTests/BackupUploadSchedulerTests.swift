import XCTest
@testable import Imora

@MainActor
final class BackupUploadSchedulerTests: XCTestCase {
    func testAuthorityPauseKeepsUnstartedQueueAndDoesNotCancelHealthyWorker() async {
        enum Outcome: Sendable { case uploaded, authorityPaused }
        let healthyStarted = expectation(description: "healthy transfer started")
        let pauseReceived = expectation(description: "pause received")
        var releaseHealthy: CheckedContinuation<Void, Never>?
        var started: [Int] = []
        var completed: [Int] = []
        var healthyWasCancelled = false
        let scheduler = Task { @MainActor in
            await BackupUploadScheduler.run(Array(0..<10), workers: 2, operation: { item in
                started.append(item)
                return { @MainActor in
                    if item == 0 {
                        await withCheckedContinuation { releaseHealthy = $0; healthyStarted.fulfill() }
                        healthyWasCancelled = Task.isCancelled
                        return Outcome.uploaded
                    }
                    return Outcome.authorityPaused
                }
            }, didFinish: { item, outcome in
                switch outcome {
                case .uploaded: completed.append(item); return .proceed
                case .authorityPaused:
                    if item == 1 { pauseReceived.fulfill() }
                    return .pause
                }
            })
        }
        await fulfillment(of: [healthyStarted, pauseReceived])
        releaseHealthy?.resume()
        await scheduler.value
        XCTAssertEqual(started.sorted(), [0, 1], "The eight unsent items must remain unstarted")
        XCTAssertEqual(completed, [0], "An authority pause is not counted as skipped/completed")
        XCTAssertFalse(healthyWasCancelled)
    }
}
