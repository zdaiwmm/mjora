import Foundation
import BackgroundTasks
import Observation
import UIKit
import os

/// what the system progress ui needs from whatever is running. the scheduler
/// expires a task that stops reporting, so `onContinuedProgress` has to fire
/// more often than the wording changes.
@MainActor
protocol ContinuedWorkload: AnyObject {
    /// Stable for the account/request context that owns this workload.
    var continuedOwnerID: UUID { get }
    var isRunning: Bool { get }
    var continuedTitle: String { get }
    var continuedSubtitle: String { get }
    /// nil leaves the system bar where it is.
    var continuedProgress: ContinuedProgress? { get }
    /// reporting a failure makes the system tell the user the job failed,
    /// so a job the user stopped themselves must not count as one.
    var continuedFailed: Bool { get }
    var onContinuedProgress: (() -> Void)? { get set }

    /// starts the job if idle and suspends until it ends. the task has to
    /// outlive the whole thing, so it needs something to await.
    func runToCompletion() async
    /// Stops new work and retains the request. An ambiguous continued-task
    /// expiration requires an explicit action before any automatic retry.
    func pauseForBackgroundExpiration(requiresExplicitResume: Bool)
    /// stops the job for good, transfers included, and forgets the request.
    func cancel()
}

/// keeps a user-started job running after the app leaves the foreground and
/// feeds the system progress ui - the live activity ios draws in the dynamic
/// island and on the lock screen, with its own cancel button.
///
/// the api is only for work the user explicitly asked for, which is why the
/// backup instance covers explicit whole-library backup actions, including a
/// request to continue an existing run. It never starts from automatic changes.
/// Expiration carries no reason, so the job pauses until the person resumes it.
@Observable
final class ContinuedProcessing {
    static let backup = ContinuedProcessing(
        identifier: "\(Bundle.main.bundleIdentifier ?? "app.imora").backup"
    )

    /// Replacing an account's workload withdraws its request. A delayed launch
    /// must never treat the replacement account as the requesting person.
    @ObservationIgnored weak var workload: (any ContinuedWorkload)? {
        didSet { workloadDidChange(from: oldValue) }
    }

    private struct WorkloadBinding {
        let workload: any ContinuedWorkload
        let request: ContinuedSubmissionState.Request
        let generation: UUID
    }

    /// one fixed identifier per job kind, registered once. apple blocks wildcard
    /// handlers - the registered and submitted strings have to match - and only
    /// one job of each kind runs at a time, so a single id covers it.
    private let identifier: String
    private var isRegistered = false
    /// the task the system is drawing progress for, until it is completed.
    /// nothing may touch a task past that point.
    private var current: BGContinuedProcessingTask?
    private var lastSubtitle = ""
    private var submissionState = ContinuedSubmissionState()
    private var ownerGeneration = UUID()
    @ObservationIgnored private var pendingBinding: WorkloadBinding?
    @ObservationIgnored private var currentBinding: WorkloadBinding?
    @ObservationIgnored private let submitRequestOperation: @Sendable (String, String, String) async -> ContinuedSubmissionState.Denial?
    @ObservationIgnored private let cancelRequestOperation: @MainActor (String) -> Void

    var status: ContinuedSubmissionState.Status { submissionState.status }
    var canRequestContinuation: Bool { current == nil && !status.isActive }
    private(set) var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    init(
        identifier: String,
        isRegistered: Bool = false,
        submitRequest: (@Sendable (String, String, String) async -> ContinuedSubmissionState.Denial?)? = nil,
        cancelRequest: (@MainActor (String) -> Void)? = nil
    ) {
        self.identifier = identifier
        self.isRegistered = isRegistered
        self.submitRequestOperation = submitRequest ?? { identifier, title, subtitle in
            await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
        }
        self.cancelRequestOperation = cancelRequest ?? { identifier in
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    private func workloadDidChange(from previous: (any ContinuedWorkload)?) {
        let sameObject = previous.map { ObjectIdentifier($0) } == workload.map { ObjectIdentifier($0) }
        let boundOwner = currentBinding?.request.owner ?? pendingBinding?.request.owner
        if sameObject, boundOwner == nil || boundOwner == workload?.continuedOwnerID { return }
        invalidateOwnerRequest()
    }

    /// An explicit in-app Cancel also withdraws a not-yet-launched request.
    /// An old manager cannot withdraw a replacement account's continuation.
    func withdraw(for owner: any ContinuedWorkload) {
        guard let workload, ObjectIdentifier(workload) == ObjectIdentifier(owner) else { return }
        invalidateOwnerRequest()
    }

    /// A withdrawn request returns false too, but must never restart a backup
    /// through the foreground-only fallback in its original button action.
    func canFallbackToForeground(for owner: any ContinuedWorkload) -> Bool {
        guard let workload, ObjectIdentifier(workload) == ObjectIdentifier(owner),
              case .denied = status else { return false }
        return true
    }

    private func invalidateOwnerRequest() {
        let hadRequest = status.isActive
        ownerGeneration = UUID()
        currentBinding?.workload.onContinuedProgress = nil
        pendingBinding = nil
        currentBinding = nil
        if let task = current {
            current = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: false)
        }
        submissionState.invalidateOwner()
        if hadRequest { cancelRequestOperation(identifier) }
    }

    private func bindingIsCurrent(_ binding: WorkloadBinding) -> Bool {
        guard let workload else { return false }
        return binding.generation == ownerGeneration
            && ObjectIdentifier(workload) == ObjectIdentifier(binding.workload)
            && workload.continuedOwnerID == binding.request.owner
    }

    /// called from the app initializer. continued-processing registrations are
    /// exempt from the finish-launching deadline, but there is no reason to wait.
    static func registerAll() {
        backup.register()
    }

    private func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [self] task in
            // the queue above pins this to the main thread, so adopting the main
            // actor is sound and the non-sendable task never crosses isolation.
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                self.begin(task)
            }
        }
        if !isRegistered {
            backupLog.error("continued processing identifier missing from the info plist")
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.backgroundRefreshStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBackgroundRefreshStatus() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBackgroundRefreshStatus() }
        }
    }

    func refreshBackgroundRefreshStatus() {
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    }

    /// asks the system to run the job as continued processing. false means it
    /// declined and the caller should just run in app.
    func submit(title: String, subtitle: String) async -> Bool {
        guard canRequestContinuation,
              let submission = submissionState.beginSubmission(owner: workload?.continuedOwnerID ?? ownerGeneration) else { return false }
        guard isRegistered, let workload else {
            submissionState.completeSubmission(submission, failure: .notPermitted)
            return false
        }
        let binding = WorkloadBinding(workload: workload, request: submission, generation: ownerGeneration)
        pendingBinding = binding
        // Background App Refresh is diagnostic information, not a substitute
        // for asking the scheduler whether this explicit task can run.
        refreshBackgroundRefreshStatus()
        let failure = await submitRequestOperation(identifier, title, subtitle)
        guard bindingIsCurrent(binding) else { return false }
        submissionState.completeSubmission(submission, failure: failure)
        if failure != nil, pendingBinding?.request == submission { pendingBinding = nil }
        return failure == nil
    }

    // MARK: - running

    private func begin(_ task: BGContinuedProcessingTask) {
        guard current == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let binding = pendingBinding, bindingIsCurrent(binding),
              submissionState.didStart(binding.request, owner: binding.workload.continuedOwnerID) else {
            pendingBinding = nil
            submissionState.invalidateOwner()
            task.setTaskCompleted(success: false)
            return
        }
        let workload = binding.workload
        let request = binding.request
        backupLog.info("continued processing task started")
        pendingBinding = nil
        currentBinding = binding
        current = task
        lastSubtitle = ""
        task.progress.totalUnitCount = 1
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task else { return }
                self.expire(task, request: request)
            }
        }
        workload.onContinuedProgress = { [weak self, weak task] in
            guard let self, let task else { return }
            self.report(to: task, request: request)
        }
        Task {
            guard task === current, currentBinding?.request == request else { return }
            await workload.runToCompletion()
            guard task === current, currentBinding?.request == request else { return }
            workload.onContinuedProgress = nil
            report(to: task, request: request)
            finish(task, request: request, success: !workload.continuedFailed)
        }
    }

    /// The system's Cancel action and resource expiration use the same handler.
    /// Retain work, stop immediately, and require a fresh foreground action.
    private func expire(_ task: BGContinuedProcessingTask, request: ContinuedSubmissionState.Request) {
        guard task === current, let binding = currentBinding, binding.request == request else { return }
        let workload = binding.workload
        workload.onContinuedProgress = nil
        workload.pauseForBackgroundExpiration(requiresExplicitResume: true)
        finish(task, request: request, success: false, paused: true)
        backupLog.info("continued processing stopped; explicit whole-library resume required")
    }

    private func report(to task: BGContinuedProcessingTask, request: ContinuedSubmissionState.Request) {
        guard task === current, let binding = currentBinding, binding.request == request else { return }
        let workload = binding.workload
        if let progress = workload.continuedProgress {
            task.progress.totalUnitCount = progress.totalUnitCount
            // PhotoKit can move to the next component of a Live Photo. Keep
            // measured task progress from moving backwards at that boundary.
            task.progress.completedUnitCount = max(task.progress.completedUnitCount, progress.completedUnitCount)
        }
        let subtitle = workload.continuedSubtitle
        // byte progress ticks far more often than the wording changes.
        guard subtitle != lastSubtitle else { return }
        lastSubtitle = subtitle
        task.updateTitle(workload.continuedTitle, subtitle: subtitle)
    }

    private func finish(_ task: BGContinuedProcessingTask, request: ContinuedSubmissionState.Request, success: Bool, paused: Bool = false) {
        guard task === current, currentBinding?.request == request else { return }
        current = nil
        currentBinding = nil
        submissionState.didFinish(request, paused: paused)
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }

    /// submission is documented as main-thread hostile and the request is not
    /// sendable, so it is built where it is used and only strings cross.
    @concurrent
    private nonisolated static func submitRequest(
        identifier: String,
        title: String,
        subtitle: String
    ) async -> ContinuedSubmissionState.Denial? {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        // queueing would show an indicator for a job that may never start;
        // failing fast lets the caller fall back to running in app.
        request.strategy = .fail
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            return nil
        } catch {
            let failure = error as NSError
            backupLog.info("continued processing declined: \(failure.code)")
            guard failure.domain == BGTaskScheduler.errorDomain else { return .unknown }
            switch BGTaskScheduler.Error.Code(rawValue: failure.code) {
            case .immediateRunIneligible: return .systemBusy
            case .unavailable: return .systemUnavailable
            case .notPermitted: return .notPermitted
            case .tooManyPendingTaskRequests: return .tooManyRequests
            default: return .unknown
            }
        }
    }
}
