import XCTest
@testable import Imora

@MainActor
final class ContinuedProcessingOwnershipTests: XCTestCase {
    func testWorkloadReplacementCancelsTheOriginatingPendingRequestAndRejectsItsLateSuccess() async {
        let scheduler = DeferredContinuedSubmission()
        var cancelled: [String] = []
        let coordinator = ContinuedProcessing(identifier: "fixture.whole-library", isRegistered: true,
            submitRequest: { _, _, _ in await scheduler.submit() },
            cancelRequest: { cancelled.append($0) })
        let first = OwnershipWorkload(), replacement = OwnershipWorkload()
        coordinator.workload = first
        let request = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await scheduler.waitUntilRequested()
        XCTAssertEqual(coordinator.status, .accepting)
        coordinator.workload = replacement
        XCTAssertEqual(cancelled, ["fixture.whole-library"])
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertTrue(coordinator.canRequestContinuation)
        await scheduler.complete()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(replacement.starts, 0)
        XCTAssertEqual(replacement.pauses, 0)
    }

    func testClearingTheWorkloadDuringSubmissionResetsStatusAndDoesNotPauseAnotherOwner() async {
        let scheduler = DeferredContinuedSubmission()
        let coordinator = ContinuedProcessing(identifier: "fixture.whole-library", isRegistered: true,
            submitRequest: { _, _, _ in await scheduler.submit() }, cancelRequest: { _ in })
        let first = OwnershipWorkload()
        coordinator.workload = first
        let request = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await scheduler.waitUntilRequested()
        coordinator.workload = nil
        await scheduler.complete()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertTrue(coordinator.canRequestContinuation)
        XCTAssertEqual(first.pauses, 0)
    }

    func testExplicitCancelBeforeLaunchWithdrawsBothInFlightAndAcceptedRequests() async {
        for acceptedBeforeCancel in [false, true] {
            let scheduler = DeferredContinuedSubmission()
            var cancelled: [String] = []
            let coordinator = ContinuedProcessing(identifier: "fixture.whole-library", isRegistered: true,
                submitRequest: { _, _, _ in await scheduler.submit() },
                cancelRequest: { cancelled.append($0) })
            let owner = OwnershipWorkload()
            coordinator.workload = owner
            let request = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
            await scheduler.waitUntilRequested()
            if acceptedBeforeCancel {
                await scheduler.complete()
                let accepted = await request.value
                XCTAssertTrue(accepted)
                XCTAssertEqual(coordinator.status, .accepted)
            }
            coordinator.withdraw(for: owner)
            XCTAssertEqual(cancelled, ["fixture.whole-library"])
            XCTAssertEqual(coordinator.status, .idle)
            XCTAssertTrue(coordinator.canRequestContinuation)
            XCTAssertFalse(coordinator.canFallbackToForeground(for: owner))
            if !acceptedBeforeCancel {
                await scheduler.complete()
                let accepted = await request.value
                XCTAssertFalse(accepted)
            }
            XCTAssertEqual(coordinator.status, .idle)
            XCTAssertEqual(owner.starts, 0)
        }
    }

    func testAnOldOwnersCancelCannotWithdrawTheReplacementOwnersRequest() async {
        let scheduler = DeferredContinuedSubmission()
        var cancelled: [String] = []
        let coordinator = ContinuedProcessing(identifier: "fixture.whole-library", isRegistered: true,
            submitRequest: { _, _, _ in await scheduler.submit() },
            cancelRequest: { cancelled.append($0) })
        let first = OwnershipWorkload(), replacement = OwnershipWorkload()
        coordinator.workload = first
        coordinator.workload = replacement
        let request = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await scheduler.waitUntilRequested()
        coordinator.withdraw(for: first)
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertEqual(coordinator.status, .accepting)
        await scheduler.complete()
        let accepted = await request.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(coordinator.status, .accepted)
    }

    func testSchedulerDenialAllowsForegroundFallbackUntilTheSameOwnerExplicitlyCancels() async {
        let scheduler = DeferredContinuedSubmission()
        let coordinator = ContinuedProcessing(identifier: "fixture.whole-library", isRegistered: true,
            submitRequest: { _, _, _ in await scheduler.submit() }, cancelRequest: { _ in })
        let owner = OwnershipWorkload(), anotherOwner = OwnershipWorkload()
        coordinator.workload = owner
        let request = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await scheduler.waitUntilRequested()
        await scheduler.complete(.systemBusy)
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(coordinator.canFallbackToForeground(for: owner))
        XCTAssertFalse(coordinator.canFallbackToForeground(for: anotherOwner))
        coordinator.withdraw(for: owner)
        XCTAssertFalse(coordinator.canFallbackToForeground(for: owner))
    }
}

private actor DeferredContinuedSubmission {
    private var response: CheckedContinuation<ContinuedSubmissionState.Denial?, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func submit() async -> ContinuedSubmissionState.Denial? {
        await withCheckedContinuation { continuation in
            response = continuation
            let waiters = started
            started = []
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func complete(_ failure: ContinuedSubmissionState.Denial? = nil) {
        response?.resume(returning: failure)
        response = nil
    }
}

@MainActor
private final class OwnershipWorkload: ContinuedWorkload {
    let continuedOwnerID = UUID()
    var isRunning = false
    var continuedTitle = "Fixture"
    var continuedSubtitle = "Fixture"
    var continuedProgress: ContinuedProgress? { nil }
    var continuedFailed = false
    var onContinuedProgress: (() -> Void)?
    private(set) var starts = 0
    private(set) var pauses = 0
    func runToCompletion() async { starts += 1 }
    func pauseForBackgroundExpiration(requiresExplicitResume: Bool) { pauses += 1 }
    func cancel() {}
}
