import XCTest
@testable import Imora

@MainActor
final class DeviceCopyRemovalTests: XCTestCase {
    private func report() -> CleanupReport {
        CleanupReport(account: "fixture|user", generation: UUID(), candidates: [],
                      keptMedia: MediaCounts(), route: URL(string: "https://fixture.invalid/api")!)
    }

    func testOriginalReadbackRequiresExplicitConfirmation() async throws {
        let coordinator = DeviceCopyRemovalCoordinator()
        let report = report()
        let prepared = expectation(description: "report ready")
        var removals = 0
        let request = Task {
            try await coordinator.remove(prepare: {
                prepared.fulfill()
                return report
            }, perform: { report in
                removals += 1
                return CleanupOutcome(deletedIDs: ["actual"], deletedMedia: MediaCounts(), keptMedia: report.keptMedia)
            })
        }
        await fulfillment(of: [prepared])
        await Task.yield()
        XCTAssertEqual(removals, 0)
        coordinator.confirm()
        let outcome = try await request.value
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(outcome.deletedIDs, ["actual"])
    }

    func testDismissalResolvesWaitingRequestWithoutDeletion() async {
        let coordinator = DeviceCopyRemovalCoordinator()
        let report = report()
        let prepared = expectation(description: "report ready")
        var removals = 0
        let request = Task {
            try await coordinator.remove(prepare: {
                prepared.fulfill()
                return report
            }, perform: { report in
                removals += 1
                return CleanupOutcome(deletedIDs: [], deletedMedia: MediaCounts(), keptMedia: report.keptMedia)
            })
        }
        await fulfillment(of: [prepared])
        await Task.yield()
        coordinator.cancel()
        do { _ = try await request.value; XCTFail("Dismissal must cancel the request") }
        catch { XCTAssertTrue(error is CancellationError) }
        coordinator.confirm()
        XCTAssertEqual(removals, 0)
    }

    func testSecondRequestCannotReplaceTheSelectionBeingReviewed() async {
        let coordinator = DeviceCopyRemovalCoordinator()
        let report = report()
        let prepared = expectation(description: "first report ready")
        let request = Task {
            try await coordinator.remove(prepare: {
                prepared.fulfill()
                return report
            }, perform: { report in
                CleanupOutcome(deletedIDs: [], deletedMedia: MediaCounts(), keptMedia: report.keptMedia)
            })
        }
        await fulfillment(of: [prepared])
        await Task.yield()
        var preparedReplacement = false
        do {
            _ = try await coordinator.remove(prepare: {
                preparedReplacement = true
                return report
            }, perform: { report in
                CleanupOutcome(deletedIDs: [], deletedMedia: MediaCounts(), keptMedia: report.keptMedia)
            })
            XCTFail("A concurrent request must be rejected")
        } catch {
            XCTAssertTrue(error is CleanupVerificationError)
        }
        XCTAssertFalse(preparedReplacement)
        coordinator.cancel()
        _ = try? await request.value
    }

}
