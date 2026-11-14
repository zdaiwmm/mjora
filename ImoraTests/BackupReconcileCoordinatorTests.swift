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
