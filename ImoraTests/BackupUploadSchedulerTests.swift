import XCTest
@testable import Imora

@MainActor
final class BackupUploadSchedulerTests: XCTestCase {
    func testRuntimeLimitChangesDrainExistingWorkBeforeStartingMore() async {
        var limit = 1
        var active = 0
        var maximum = 0
        var finished = 0
        await BackupUploadScheduler.run(Array(0..<12), workers: 3, workerLimit: { limit }, operation: { item in
            active += 1
            maximum = max(maximum, active)
            XCTAssertLessThanOrEqual(active, limit, "A reduced runtime budget must drain existing workers first")
            return {
                try? await Task.sleep(for: .milliseconds(5))
                return item
            }
        }, didFinish: { item, _ in
            active -= 1
            finished += 1
            if item == 0 { limit = 3 }
            if item == 1 { limit = 1 }
            return .proceed
        })
        XCTAssertEqual(finished, 12)
        XCTAssertEqual(maximum, 3)
        XCTAssertEqual(active, 0)
    }

    func testCriticalThermalBudgetRetainsEveryUnstartedItem() async {
        var started = 0
        await BackupUploadScheduler.run([1, 2, 3], workers: 3, workerLimit: { 0 }, operation: { item in
            started += 1
            return { item }
        }, didFinish: { _, _ in .proceed })
        XCTAssertEqual(started, 0)
    }

    func testSeriousHeatDuringTheRunLeavesRemainingOriginalsUnstarted() async {
        var thermal = ProcessInfo.ThermalState.nominal
        var started: [Int] = []
        var completed: [Int] = []
        await BackupUploadScheduler.run([0, 1, 2], workers: 1,
            workerLimit: { BackupRuntimePolicy.workers(requested: 1, background: false, lowPower: false, thermal: thermal) },
            operation: { item in
                started.append(item)
                return { item }
            }, didFinish: { item, _ in
                completed.append(item)
                thermal = .serious
                return .proceed
            })
        XCTAssertEqual(started, [0])
        XCTAssertEqual(completed, [0])
    }

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
