import Foundation
import XCTest
@testable import Imora

@MainActor
final class ContinuedProcessingLifecycleTests: XCTestCase {
    func testDaemonHandoffCompletesOnlyPreparationAndCannotExpireTheContinuingUpload() async {
        let diagnostics = BackgroundTaskDiagnostics()
        let owner = LifecycleWorkload(running: true, progress: .init(fraction: 0.35))
        let coordinator = makeCoordinator(owner, diagnostics: diagnostics)
        _ = await coordinator.submit(title: "Fixture", subtitle: "Fixture")
        let task = LifecycleTask()
        coordinator.begin(task)
        await owner.waitUntilRunning()
        let oldExpiration = task.expirationHandler
        owner.continuedSystemHandoffReady = true
        owner.onContinuedProgress?()
        XCTAssertEqual(task.completions, [true])
        XCTAssertTrue(owner.isRunning, "The library upload must continue after preparation finishes")
        XCTAssertTrue(coordinator.hasSystemHandoff)
        XCTAssertFalse(coordinator.canRequestContinuation)
        XCTAssertEqual(diagnostics.events.last?.lifecycle, .handedOff)
        oldExpiration?()
        await Task.yield()
        XCTAssertEqual(owner.explicitPauses, 0)
        owner.complete()
        await Task.yield()
        XCTAssertEqual(task.completions, [true])
    }

    func testLateHandoffCannotReviveAStoppedPreparationTask() async {
        let owner = LifecycleWorkload(running: true, progress: .init(fraction: 0.2))
        let coordinator = makeCoordinator(owner)
        _ = await coordinator.submit(title: "Fixture", subtitle: "Fixture")
        let task = LifecycleTask()
        coordinator.begin(task)
        await owner.waitUntilRunning()
        let lateProgress = owner.onContinuedProgress
        task.expirationHandler?()
        await owner.waitUntilPaused()
        owner.continuedSystemHandoffReady = true
        lateProgress?()
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(coordinator.hasSystemHandoff)
        XCTAssertEqual(owner.explicitPauses, 1)
        owner.complete()
    }

    func testPromotingARunningJobImmediatelyShowsItsExistingProgress() async {
        let owner = LifecycleWorkload(running: true, progress: .init(fraction: 0.27))
        let coordinator = makeCoordinator(owner)
        let accepted = await coordinator.submit(title: "Fixture", subtitle: "Fixture")
        XCTAssertTrue(accepted)
        let task = LifecycleTask()
        coordinator.begin(task)
        XCTAssertEqual(task.progress.fractionCompleted, 0.27, accuracy: 0.000001)
        coordinator.withdraw(for: owner)
        owner.complete()
    }

    func testRetryAfterATerminalPhaseDoesNotSeedTheNewJobAtOneHundredPercent() async {
        let owner = LifecycleWorkload(running: false, progress: .init(fraction: 1))
        let coordinator = makeCoordinator(owner)
        let accepted = await coordinator.submit(title: "Fixture", subtitle: "Fixture")
        XCTAssertTrue(accepted)
        let task = LifecycleTask()
        coordinator.begin(task)
        XCTAssertEqual(task.progress.fractionCompleted, 0)
        await owner.waitUntilRunning()
        XCTAssertEqual(task.progress.fractionCompleted, 0.05, accuracy: 0.000001)
        coordinator.withdraw(for: owner)
        owner.complete()
    }

    func testExpirationPersistsTheMeasuredPhaseBeforePausingAndIgnoresLateWorkerCompletion() async {
        let diagnostics = BackgroundTaskDiagnostics()
        let owner = LifecycleWorkload(running: true, progress: .init(fraction: 0.27))
        let coordinator = makeCoordinator(owner, diagnostics: diagnostics)
        let accepted = await coordinator.submit(title: "Fixture", subtitle: "Fixture")
        XCTAssertTrue(accepted)
        let task = LifecycleTask()
        coordinator.begin(task)
        await owner.waitUntilRunning()
        task.expirationHandler?()
        await owner.waitUntilPaused()
        XCTAssertEqual(owner.explicitPauses, 1)
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(diagnostics.events.last?.lifecycle, .expired)
        XCTAssertEqual(diagnostics.events.last?.phase, .checking)
        XCTAssertEqual(diagnostics.events.last?.progress?.completed, 270_000_000_000)
        owner.complete()
        await Task.yield()
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(coordinator.status, .paused)
    }

    func testOldSubmissionFailureCannotEndTheNewDiagnosticAttemptForTheSameOwner() async {
        let responses = LifecycleResponses()
        let diagnostics = BackgroundTaskDiagnostics()
        let owner = LifecycleWorkload(running: true, progress: .init(fraction: 0.27))
        let coordinator = ContinuedProcessing(identifier: "fixture.continued-lifecycle", isRegistered: true,
            diagnostics: diagnostics, submitRequest: { _, _, _ in await responses.submit() }, cancelRequest: { _ in })
        coordinator.workload = owner
        let oldRequest = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await responses.waitUntilRequested(1)
        let oldTask = LifecycleTask()
        coordinator.begin(oldTask)
        await owner.waitUntilRunning()
        oldTask.expirationHandler?()
        await owner.waitUntilPaused()
        owner.complete()

        let newRequest = Task { await coordinator.submit(title: "Fixture", subtitle: "Fixture") }
        await responses.waitUntilRequested(2)
        let newAttempt = diagnostics.attemptID
        await responses.complete(0, failure: .systemBusy)
        let oldAccepted = await oldRequest.value
        XCTAssertFalse(oldAccepted)
        XCTAssertEqual(diagnostics.attemptID, newAttempt)
        XCTAssertFalse(diagnostics.events.contains { $0.lifecycle == .denied },
            "An expired request's late answer must not end the new attempt's diagnostics")
        await responses.complete(1, failure: nil)
        let newAccepted = await newRequest.value
        XCTAssertTrue(newAccepted)
        XCTAssertEqual(coordinator.status, .accepted)
        coordinator.withdraw(for: owner)
    }

    private func makeCoordinator(_ owner: LifecycleWorkload,
                                 diagnostics: BackgroundTaskDiagnostics = BackgroundTaskDiagnostics()) -> ContinuedProcessing {
        let coordinator = ContinuedProcessing(identifier: "fixture.continued-lifecycle", isRegistered: true,
            diagnostics: diagnostics, submitRequest: { _, _, _ in nil }, cancelRequest: { _ in })
        coordinator.workload = owner
        return coordinator
    }
}

private actor LifecycleResponses {
    private var responses: [CheckedContinuation<ContinuedSubmissionState.Denial?, Never>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func submit() async -> ContinuedSubmissionState.Denial? {
        await withCheckedContinuation { continuation in
            responses.append(continuation)
            let ready = waiters.filter { responses.count >= $0.0 }
            waiters.removeAll { responses.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitUntilRequested(_ count: Int) async {
        if responses.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func complete(_ index: Int, failure: ContinuedSubmissionState.Denial?) {
        responses[index]?.resume(returning: failure)
        responses[index] = nil
    }
}

@MainActor
private final class LifecycleTask: ContinuedTask {
    let progress = Progress(totalUnitCount: 1)
    var expirationHandler: (@Sendable () -> Void)?
    private(set) var completions: [Bool] = []
    func updateTitle(_ title: String, subtitle: String) {}
    func setTaskCompleted(success: Bool) { completions.append(success) }
}

@MainActor
private final class LifecycleWorkload: ContinuedWorkload {
    let continuedOwnerID = UUID()
    var isRunning: Bool
    let continuedTitle = "Fixture"
    let continuedSubtitle = "Fixture"
    var continuedProgress: ContinuedProgress?
    var continuedFailed = false
    var continuedSystemHandoffReady = false
    var continuedDiagnosticPhase: BackgroundTaskDiagnostics.Phase { .checking }
    var onContinuedProgress: (() -> Void)?
    private var completion: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var explicitPauses = 0
    init(running: Bool, progress: ContinuedProgress) { isRunning = running; continuedProgress = progress }
    func runToCompletion() async {
        if !isRunning { isRunning = true; continuedProgress = .init(fraction: 0.05); onContinuedProgress?() }
        await withCheckedContinuation { continuation in
            completion = continuation
            let waiters = startedWaiters; startedWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
    func waitUntilRunning() async {
        if completion != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func waitUntilPaused() async {
        if explicitPauses > 0 { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }
    func pauseForBackgroundExpiration(requiresExplicitResume: Bool) {
        if requiresExplicitResume { explicitPauses += 1 }
        let waiters = pausedWaiters; pausedWaiters = []
        waiters.forEach { $0.resume() }
    }
    func complete() { completion?.resume(); completion = nil }
    func cancel() {}
}
