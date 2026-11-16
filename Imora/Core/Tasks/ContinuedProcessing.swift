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
    var continuedSystemHandoffReady: Bool { get }
    var continuedDiagnosticPhase: BackgroundTaskDiagnostics.Phase { get }
    var continuedDiagnosticFailure: BackgroundTaskDiagnostics.Failure? { get }
    var onContinuedProgress: (() -> Void)? { get set }

    /// Starts an idle job and awaits its verified end. A system task may
    /// release its preparation budget after a daemon handoff; the workload
    /// keeps its independent run and durable backup intent.
    func runToCompletion() async
    /// Stops new work and retains the request. An ambiguous continued-task
    /// expiration requires an explicit action before any automatic retry.
    func pauseForBackgroundExpiration(requiresExplicitResume: Bool)
    /// stops the job for good, transfers included, and forgets the request.
    func cancel()
}

extension ContinuedWorkload {
    var continuedSystemHandoffReady: Bool { false }
    var continuedDiagnosticPhase: BackgroundTaskDiagnostics.Phase { .idle }
    var continuedDiagnosticFailure: BackgroundTaskDiagnostics.Failure? { nil }
}

/// Only the operations owned by this coordinator. The adapter keeps Apple's
/// system-created task behind the same lifecycle boundary exercised in tests.
@MainActor
protocol ContinuedTask: AnyObject, Sendable {
    var progress: Progress { get }
    var expirationHandler: (@Sendable () -> Void)? { get set }
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@MainActor
private final class SystemContinuedTask: ContinuedTask {
    let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }
    var progress: Progress { task.progress }
    var expirationHandler: (@Sendable () -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }
    func updateTitle(_ title: String, subtitle: String) { task.updateTitle(title, subtitle: subtitle) }
    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
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
        identifier: "\(Bundle.main.bundleIdentifier ?? "app.imora").backup",
        diagnostics: .shared
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
    private(set) var hasSystemHandoff = false
    /// the task the system is drawing progress for, until it is completed.
    /// nothing may touch a task past that point.
    private var current: (any ContinuedTask)?
    private var lastTitle = ""
    private var lastSubtitle = ""
    private var lastReportTime: TimeInterval?
    private var submissionState = ContinuedSubmissionState()
    private var ownerGeneration = UUID()
    @ObservationIgnored private var pendingBinding: WorkloadBinding?
    @ObservationIgnored private var currentBinding: WorkloadBinding?
    @ObservationIgnored private let submitRequestOperation: @Sendable (String, String, String) async -> ContinuedSubmissionState.Denial?
    @ObservationIgnored private let cancelRequestOperation: @MainActor (String) -> Void
    @ObservationIgnored private let diagnostics: BackgroundTaskDiagnostics

    var status: ContinuedSubmissionState.Status { submissionState.status }
    var canRequestContinuation: Bool {
        current == nil && !status.isActive && !(hasSystemHandoff && workload?.continuedSystemHandoffReady == true)
    }
    private(set) var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    init(
        identifier: String,
        isRegistered: Bool = false,
        diagnostics: BackgroundTaskDiagnostics = BackgroundTaskDiagnostics(),
        submitRequest: (@Sendable (String, String, String) async -> ContinuedSubmissionState.Denial?)? = nil,
        cancelRequest: (@MainActor (String) -> Void)? = nil
    ) {
        self.identifier = identifier
        self.isRegistered = isRegistered
        self.diagnostics = diagnostics
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
        hasSystemHandoff = false
        let hadRequest = status.isActive
        if hadRequest, let workload = currentBinding?.workload ?? pendingBinding?.workload {
            recordDiagnostic(.invalidated, workload: workload, success: false)
        }
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
                self.begin(SystemContinuedTask(task))
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
        for (notification, lifecycle) in [
            (UIApplication.didEnterBackgroundNotification, BackgroundTaskDiagnostics.Lifecycle.backgrounded),
            (UIApplication.didBecomeActiveNotification, .foregrounded)
        ] {
            _ = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let workload = self.currentBinding?.workload else { return }
                    self.recordDiagnostic(lifecycle, workload: workload)
                }
            }
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
        hasSystemHandoff = false
        diagnostics.beginAttempt(phase: workload?.continuedDiagnosticPhase ?? .idle)
        guard isRegistered, let workload else {
            submissionState.completeSubmission(submission, failure: .notPermitted)
            diagnostics.record(.denied, phase: workload?.continuedDiagnosticPhase ?? .idle, success: false)
            return false
        }
        let binding = WorkloadBinding(workload: workload, request: submission, generation: ownerGeneration)
        pendingBinding = binding
        // Background App Refresh is diagnostic information, not a substitute
        // for asking the scheduler whether this explicit task can run.
        refreshBackgroundRefreshStatus()
        let failure = await submitRequestOperation(identifier, title, subtitle)
        guard bindingIsCurrent(binding) else { return false }
        let awaitingThisResponse = pendingBinding?.request == submission && status == .accepting
        submissionState.completeSubmission(submission, failure: failure)
        if awaitingThisResponse {
            recordDiagnostic(failure == nil ? .accepted : .denied, workload: workload,
                success: failure == nil ? nil : false)
        }
        if failure != nil, pendingBinding?.request == submission { pendingBinding = nil }
        return failure == nil
    }

    // MARK: - running

    func begin(_ task: any ContinuedTask) {
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
        recordDiagnostic(.launched, workload: workload)
        lastTitle = ""
        lastSubtitle = ""
        lastReportTime = nil
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
        // Continuing an existing run must immediately show its measured phase
        // and progress instead of waiting for the next worker callback.
        if workload.isRunning { report(to: task, request: request, force: true) }
        Task {
            guard task === current, currentBinding?.request == request else { return }
            await workload.runToCompletion()
            guard task === current, currentBinding?.request == request else { return }
            workload.onContinuedProgress = nil
            report(to: task, request: request, force: true)
            finish(task, request: request, success: !workload.continuedFailed)
        }
    }

    /// The system's Cancel action and resource expiration use the same handler.
    /// Retain work, stop immediately, and require a fresh foreground action.
    private func expire(_ task: any ContinuedTask, request: ContinuedSubmissionState.Request) {
        guard task === current, let binding = currentBinding, binding.request == request else { return }
        let workload = binding.workload
        recordDiagnostic(.expired, workload: workload, success: false)
        workload.onContinuedProgress = nil
        workload.pauseForBackgroundExpiration(requiresExplicitResume: true)
        finish(task, request: request, success: false, paused: true)
        backupLog.info("continued processing stopped; explicit whole-library resume required")
    }

    private func report(to task: any ContinuedTask, request: ContinuedSubmissionState.Request, force: Bool = false) {
        guard task === current, let binding = currentBinding, binding.request == request else { return }
        let workload = binding.workload
        if workload.continuedSystemHandoffReady {
            workload.onContinuedProgress = nil
            hasSystemHandoff = true
            task.updateTitle(String(localized: "Background upload started"),
                subtitle: String(localized: "Prepared files are uploading. Check Backup for remaining items."))
            // This task now completes its preparation/handoff goal. Whole-library
            // completion remains the manager's independently verified state.
            task.progress.totalUnitCount = 1
            task.progress.completedUnitCount = 1
            finish(task, request: request, success: true, handedOff: true)
            return
        }
        if !force { recordDiagnostic(.progress, workload: workload) }
        let title = workload.continuedTitle
        let subtitle = workload.continuedSubtitle
        let now = ProcessInfo.processInfo.systemUptime
        guard force || title != lastTitle || subtitle != lastSubtitle
                || lastReportTime.map({ now - $0 >= 0.5 }) ?? true else { return }
        lastReportTime = now
        if let progress = workload.continuedProgress {
            task.progress.totalUnitCount = progress.totalUnitCount
            // PhotoKit can move to the next component of a Live Photo. Keep
            // measured task progress from moving backwards at that boundary.
            task.progress.completedUnitCount = max(task.progress.completedUnitCount, progress.completedUnitCount)
        }
        // byte progress ticks far more often than the wording changes.
        guard title != lastTitle || subtitle != lastSubtitle else { return }
        lastTitle = title
        lastSubtitle = subtitle
        task.updateTitle(title, subtitle: subtitle)
    }

    private func finish(_ task: any ContinuedTask, request: ContinuedSubmissionState.Request, success: Bool, paused: Bool = false, handedOff: Bool = false) {
        guard task === current, currentBinding?.request == request else { return }
        if !paused, let workload = currentBinding?.workload {
            recordDiagnostic(handedOff ? .handedOff : .completed, workload: workload, success: success)
        }
        current = nil
        currentBinding = nil
        submissionState.didFinish(request, paused: paused)
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }

    private func recordDiagnostic(_ lifecycle: BackgroundTaskDiagnostics.Lifecycle,
                                  workload: any ContinuedWorkload, success: Bool? = nil) {
        let progress = workload.continuedProgress.map {
            BackgroundTaskDiagnostics.ProgressSnapshot(completed: $0.completedUnitCount, total: $0.totalUnitCount)
        }
        let thermal: BackgroundTaskDiagnostics.ThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
        diagnostics.record(lifecycle, phase: workload.continuedDiagnosticPhase, progress: progress,
            success: success, failure: workload.continuedDiagnosticFailure,
            environment: lifecycle == .progress ? nil : .init(
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: thermal, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable))
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
