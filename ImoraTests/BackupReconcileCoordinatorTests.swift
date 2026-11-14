import XCTest
@testable import Imora

@MainActor
final class BackupReconcileCoordinatorTests: XCTestCase {
    func testRoutineTriggersCoalesceButNewChangesAreDrained() async {
        var requests: [BackupReconcileRequest] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first incremental cycle started")
        let coordinator = BackupReconcileCoordinator { request in
            requests.append(request)
            if requests.count == 1 {
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
        }
        coordinator.request(.foreground)
        await fulfillment(of: [started])
        for _ in 0..<10 { coordinator.request(.foreground); coordinator.request(.reconnect) }
        coordinator.request(.localChange, localIDs: ["new-local"])
        coordinator.request(.remoteChange, remoteIDs: ["removed-remote"])
        release?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.localIDs, ["new-local"])
        XCTAssertEqual(requests.last?.remoteIDs, ["removed-remote"])
        XCTAssertFalse(requests.contains(where: \.requiresFullCheck))
    }

    func testNewReconnectWhileCatchUpFinishesIsNotDiscarded() async {
        var rounds = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first catchup")
        let coordinator = BackupReconcileCoordinator { _ in
            rounds += 1
            if rounds == 1 {
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
        }
        coordinator.request(.foreground)
        await fulfillment(of: [started])
        coordinator.request(.reconnect)
        release?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rounds, 2)
    }

    func testReconnectAfterCatchUpIsRetainedWhileIndependentUploadContinues() async {
        var rounds = 0
        var uploadFinished = false
        var finishUpload: CheckedContinuation<Void, Never>?
        let uploadStarted = expectation(description: "healthy upload started")
        let upload = Task { @MainActor in
            await withCheckedContinuation { finishUpload = $0; uploadStarted.fulfill() }
            uploadFinished = true
        }
        await fulfillment(of: [uploadStarted])
        let coordinator = BackupReconcileCoordinator { _ in rounds += 1 }
        let connection = UUID()
        coordinator.request(.reconnect, generation: connection)
        await coordinator.waitUntilIdle()
        coordinator.request(.reconnect, generation: connection)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rounds, 1, "Duplicate notification for a covered generation is ignored")
        coordinator.request(.reconnect, generation: UUID())
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rounds, 2)
        XCTAssertFalse(uploadFinished)
        XCTAssertFalse(upload.isCancelled)
        finishUpload?.resume()
        await upload.value
    }

    func testManualFullCheckSurvivesConcurrentRoutineRequests() async {
        var requests: [BackupReconcileRequest] = []
        let coordinator = BackupReconcileCoordinator { requests.append($0) }
        coordinator.request(.foreground)
        coordinator.request(.manualFullCheck)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].requiresFullCheck)
    }

    func testShutdownDropsQueuedAndFutureRequests() async {
        var runs = 0
        let coordinator = BackupReconcileCoordinator { _ in runs += 1 }
        coordinator.request(.foreground)
        coordinator.shutdown()
        coordinator.request(.localChange, localIDs: ["new"])
        await coordinator.waitUntilIdle()
        XCTAssertEqual(runs, 0)
    }
}
