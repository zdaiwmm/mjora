import Foundation
import Observation
import Photos
import os

nonisolated let backupLog = Logger(subsystem: "app.imora", category: "backup")

nonisolated enum BackupPhase: Equatable {
    case idle
    case scanning
    case hashing(done: Int, total: Int)
    case checking
    case uploading(done: Int, total: Int)
    case done(BackupSummary)
    case error(String)
    /// the user stopped the run, or the system reclaimed it. nothing to
    /// announce, and the next launch or foreground picks up where it left off.
    case cancelled
}

nonisolated struct BackupSummary: Equatable, Sendable {
    var uploadedMedia = MediaCounts()
    var duplicateMedia = MediaCounts()
    var failedMedia = MediaCounts()
    var skippedMedia = MediaCounts()
    var unsupportedMedia = MediaCounts()
    var uploaded: Int { uploadedMedia.total }
    var duplicates: Int { duplicateMedia.total }
    var failed: Int { failedMedia.total }
    var skipped: Int { skippedMedia.total }
    var unsupported: Int { unsupportedMedia.total }
}

/// live per-asset upload state, keyed by local identifier. drives the
/// progress overlay on timeline tiles.
nonisolated enum LocalUploadState: Equatable, Sendable {
    case uploading(Double)
    case failed
}

nonisolated enum SingleAssetBackupError: LocalizedError {
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            String(localized: "the photo is no longer available on this device.")
        case .failed(let reason):
            reason
        }
    }
}

/// outcome of a multi-select backup started from the grid.
nonisolated struct BulkBackupOutcome: Equatable, Sendable {
    var uploaded = 0
    var alreadyBackedUp = 0
    var skipped = 0
    var failed = 0
    var firstFailure: String?
}

/// device asset paired with what the backup index knows about it.
nonisolated struct LocalTimelineItem: Equatable, Sendable {
    let device: DeviceAsset
    let remoteId: String?
    let backedUp: Bool
}

/// per-install identifier sent as deviceId on uploads. dedup is checksum
/// based, so a fresh id after reinstall is harmless.
nonisolated enum DeviceID {
    private static let key = "imora.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

/// orchestrates the backup pipeline: scan, hash, bulk-check, upload. state
/// mutations stay on the main actor; heavy work runs in the services.
@Observable
final class BackupManager {
    static let autoBackupKey = "imora.backupEnabled"
    static let cellularBackupKey = "imora.backupOnCellular"
    static let reminderDismissedKey = "imora.backupReminderDismissed"
    static let excludeScreenshotsKey = "imora.backupExcludeScreenshots"
    static let lowBatteryKey = "imora.backupPauseOnLowBattery"
    static let batteryThresholdKey = "imora.backupBatteryThreshold"
    private static let cellularOverrideKey = "imora.backupCellularOverride"
    private static let batteryOverrideKey = "imora.backupBatteryOverride"
    static let dateOrderKey = "imora.backupDateOrder"
    static let mediaPriorityKey = "imora.backupMediaPriority"
    static let hashWorkersKey = "imora.backupHashWorkers"
    static let maxUploadSizeMBKey = "imora.backupMaxUploadSizeMB"
    static let dismissedRepeatedFailuresKey = "imora.backupRepeatedFailuresDismissed"
    static let hashWorkerOptions = [1, 3, 5, 8, 16, 32]
    static let defaultHashWorkers = 8
    private static let uploadWorkers = 3
    private nonisolated static let verificationWorkers = 8
    private nonisolated static let checkBatchSize = 100

    private(set) var phase: BackupPhase = .idle {
        didSet { onContinuedProgress?() }
    }
    private(set) var summary = BackupSummary()
    /// first per-asset failure of the current run, for display next to counts.
    private(set) var lastFailure: String?
    /// true once PhotoKit proves that this preparation pass had to fetch an
    /// original from iCloud. iOS exposes no supported global Optimize Storage
    /// flag, so the UI reports the resource-level fact instead.
    private(set) var downloadedOriginalsFromICloud = false
    /// separate from the backlog phase so a new capture never replaces its
    /// preparation counter. both paths contribute to the final run summary.
    private(set) var recentBackupStatus: String?
    private(set) var recentBackedUpMedia = MediaCounts()
    var recentBackedUpCount: Int { recentBackedUpMedia.total }
    private(set) var phaseMediaTotal = MediaCounts()
    private(set) var phaseMediaCompleted = MediaCounts()
    private(set) var libraryStatus: BackupLibraryStatus?
    @ObservationIgnored private var libraryStatusGeneration = 0
    var userId: String? {
        didSet {
            if oldValue != userId {
                activeTransfers.removeAll()
                sizeExcludedRequestBytesByLocal = [:]
                sizeExcludedLocalIdentifiers = []
                updateRepeatedFailureSummary()
            }
        }
    }

    @ObservationIgnored private var repeatedFailureLedger = RepeatedBackupFailures.load()
    /// assets with more than five consecutive failed backup attempts.
    private(set) var repeatedFailures: [RepeatedBackupFailure] = []
    /// failures the user already waved away in the gallery. a new one brings
    /// the banner back; the backup screen keeps listing all of them.
    private var dismissedRepeatedFailureIDs = Set(
        UserDefaults.standard.stringArray(forKey: BackupManager.dismissedRepeatedFailuresKey) ?? []
    ) {
        didSet {
            UserDefaults.standard.set(Array(dismissedRepeatedFailureIDs), forKey: Self.dismissedRepeatedFailuresKey)
        }
    }
    var showsRepeatedFailureBanner: Bool {
        repeatedFailures.contains { !dismissedRepeatedFailureIDs.contains($0.id) }
    }

    func dismissRepeatedFailureBanner() {
        dismissedRepeatedFailureIDs = Set(repeatedFailures.map(\.id))
    }
    @ObservationIgnored private var sizeExcludedRequestBytesByLocal: [String: Int64] = [:]
    /// Files this device will skip under the current per-request upload cap.
    private(set) var sizeExcludedLocalIdentifiers: Set<String> = []

    /// per-asset upload progress for tile overlays.
    private(set) var uploadStates: [String: LocalUploadState] = [:]
    /// Current work is independent of verified summary counts. Preparing an
    /// original never masquerades as a zero-percent network upload.
    private(set) var activeTransfers = ActiveBackupTransfers()
    /// remote ids proven to be fully backed up from this device, for the
    /// merged cloud badge on remote tiles.
    private(set) var backedUpRemoteIds: Set<String> = []
    /// synchronous remote-to-device lookup so a tile whose device photo just
    /// finished uploading keeps rendering the same local thumbnail while the
    /// server thumbnail loads - the swap never flashes.
    private(set) var localIdentifierByRemoteId: [String: String] = [:]
    /// every verified index pairing, including server assets whose pixels were
    /// edited after upload. Action availability needs presence, while rendering
    /// deliberately uses the stricter map above.
    private(set) var pairedLocalIdentifierByRemoteId: [String: String] = [:]
    /// inverse of the complete pairing map. A still-open local viewer uses this
    /// immediately after a manual upload to address its new server copy.
    private(set) var remoteIdentifierByLocalId: [String: String] = [:]
    /// wired by sessionstore to the realtime hub, which debounces.
    var onLocalChange: (() -> Void)?
    /// wired by sessionstore to raise the failure banner. a finished run stays
    /// silent, the uploads show up in the timeline on their own. not called
    /// when the server was unreachable, since every launch and foreground
    /// retries and each retry would repeat the same banner.
    var onRunFailed: ((String) -> Void)?
    /// wired by the continued-processing task, which has to keep feeding the
    /// system progress ui or the scheduler expires it.
    var onContinuedProgress: (() -> Void)?

    var autoBackup: Bool {
        didSet {
            UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey)
            if oldValue != autoBackup {
                reminderDismissed = false
                reminderHiddenThisSession = false
                conditions.cellularOverride = false
                conditions.batteryOverride = false
            }
            scheduleRecovery()
            if autoBackup {
                Task { await self.enableAndStart() }
            } else {
                recentRescanRequested = false
                recentTask?.cancel()
                updateChangeObserver()
            }
        }
    }

    /// cellular backup is opt in; a temporary override leaves this preference intact.
    var backUpOnCellular: Bool {
        didSet {
            UserDefaults.standard.set(backUpOnCellular, forKey: Self.cellularBackupKey)
            conditions.cellularOverride = false
            conditionsChanged()
        }
    }

    var excludeScreenshots: Bool {
        didSet {
            guard oldValue != excludeScreenshots else { return }
            UserDefaults.standard.set(excludeScreenshots, forKey: Self.excludeScreenshotsKey)
            libraryStatusGeneration += 1
            localChanged()
            recentAttempted = [:]
            // rebuild the run's snapshot and counters with the new selection.
            // keep the saved manual request and all existing index pairings.
            if runTask != nil {
                policyInterruptedRun = true
                // detach from transfers the system already carries, as the footer promises.
                runLifetime.expire()
                recentTask?.cancel()
                runTask?.cancel()
            } else {
                startIfIdle()
            }
        }
    }

    private func includesInBackup(_ asset: DeviceAsset) -> Bool {
        !excludeScreenshots || !asset.isScreenshot
    }

    var reminderDismissed: Bool {
        didSet { UserDefaults.standard.set(reminderDismissed, forKey: Self.reminderDismissedKey) }
    }
    var reminderHiddenThisSession = false
    /// the photos access banner goes first, backup is pointless without that access.
    var showsBackupReminder: Bool {
        !autoBackup && !reminderDismissed && !reminderHiddenThisSession && !PhotoAccess.shared.canAsk
    }

    var pauseOnLowBattery: Bool {
        didSet {
            UserDefaults.standard.set(pauseOnLowBattery, forKey: Self.lowBatteryKey)
            conditions.batteryOverride = false
            conditionsChanged()
        }
    }
    var batteryThreshold: Int {
        didSet {
            UserDefaults.standard.set(batteryThreshold, forKey: Self.batteryThresholdKey)
            conditions.updateBattery(conditions.batteryPercent, threshold: batteryThreshold)
            conditionsChanged()
        }
    }
    private var conditions = BackupConditions() {
        didSet {
            UserDefaults.standard.set(conditions.cellularOverride, forKey: Self.cellularOverrideKey)
            UserDefaults.standard.set(conditions.batteryOverride, forKey: Self.batteryOverrideKey)
        }
    }

    /// bounded PhotoKit resource streams used by the prepare phase. the value
    /// is captured when a pass begins, so changing it never reshapes a live
    /// task group. the default stays modest for older devices and icloud
    /// downloads; 32 matches the official immich ios batch limit.
    var hashWorkers: Int {
        didSet {
            UserDefaults.standard.set(hashWorkers, forKey: Self.hashWorkersKey)
        }
    }

    /// nil leaves server/proxy limits to the server. the cap applies to each
    /// multipart upload request, including a Live Photo's separate components.
    var maxUploadSizeMB: Int? {
        didSet {
            if let maxUploadSizeMB {
                UserDefaults.standard.set(maxUploadSizeMB, forKey: Self.maxUploadSizeMBKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.maxUploadSizeMBKey)
            }
            updateSizeExclusions()
            if oldValue != maxUploadSizeMB { startIfIdle() }
        }
    }

    /// imora takes uploads in chunks, so no request reaches the cap and no
    /// file is skipped for its size there.
    private var maximumRequestBytes: Int64? {
        acceptsChunkedUploads ? nil : UploadSizeLimit.bytes(forMegabytes: maxUploadSizeMB)
    }

    private var chunking: ChunkedAssetUpload.Policy? {
        guard acceptsChunkedUploads else { return nil }
        return ChunkedAssetUpload.Policy(maximumRequestBytes: UploadSizeLimit.bytes(forMegabytes: maxUploadSizeMB))
    }

    @ObservationIgnored private var acceptsChunkedUploads = false

    private func refreshUploadProtocol() async {
        let accepts = await client.acceptsChunkedUploads()
        guard accepts != acceptsChunkedUploads else { return }
        acceptsChunkedUploads = accepts
        updateSizeExclusions()
    }

    var dateOrder: BackupDateOrder = .newestFirst {
        didSet { UserDefaults.standard.set(dateOrder.rawValue, forKey: Self.dateOrderKey) }
    }
    var mediaPriority: BackupMediaPriority = .together {
        didSet { UserDefaults.standard.set(mediaPriority.rawValue, forKey: Self.mediaPriorityKey) }
    }

    var isOnCellular: Bool { conditions.cellular }
    var isOnMeteredConnection: Bool { conditions.metered }
    private var networkStatusKnown: Bool { conditions.networkKnown }

    var isRunning: Bool {
        switch phase {
        case .scanning, .hashing, .checking, .uploading: true
        default: false
        }
    }

    var isHeldForMeteredConnection: Bool {
        autoBackup && conditions.heldForCellular(allowCellular: backUpOnCellular)
    }

    var isHeldForLowBattery: Bool {
        autoBackup && batteryBlocksWork
    }

    private var batteryBlocksWork: Bool {
        conditions.heldForBattery(pauseOnLowBattery: pauseOnLowBattery, threshold: batteryThreshold)
    }

    var syncHoldMessage: String? {
        // a hold is actionable only with Photos access and work remaining.
        // unknown counts may still represent an initial backup waiting to scan.
        guard PhotoAccess.shared.status == .authorized,
              libraryStatus.map({ $0.pending > 0 }) ?? true else { return nil }
        return switch (isHeldForMeteredConnection, isHeldForLowBattery) {
        case (true, true): String(localized: "\(meteredHoldMessage) Battery is at \(batteryThreshold)% or less.")
        case (true, false): meteredHoldMessage
        case (false, true): String(localized: "Battery is at \(batteryThreshold)% or less. Waiting for more charge.")
        default: nil
        }
    }

    private var meteredHoldMessage: String {
        if conditions.wifi { return String(localized: "This Wi-Fi connection is metered. Metered backup is off.") }
        if conditions.cellular { return String(localized: "Cellular backup is off. Waiting for an unmetered connection.") }
        return String(localized: "This connection is metered. Metered backup is off.")
    }

    var manualBackupNeedsApproval: Bool { isOnMeteredConnection || batteryBlocksWork }
    var manualBackupApprovalMessage: String {
        var messages: [String] = []
        if conditions.wifi && isOnMeteredConnection {
            messages.append(String(localized: "Backing up now may use data on this metered Wi-Fi connection."))
        } else if isOnCellular {
            messages.append(String(localized: "Backing up now can use a large amount of cellular data."))
        } else if isOnMeteredConnection {
            messages.append(String(localized: "Backing up now may use data on this metered connection."))
        }
        if batteryBlocksWork { messages.append(String(localized: "Battery is at \(batteryThreshold)% or less. Allow backup this time; low-battery protection resets after the charge rises above this threshold.")) }
        return messages.joined(separator: " ")
    }

    /// explicitly continue all currently displayed holds without changing settings.
    func syncThisTime() {
        conditions.overrideCurrentHolds(allowCellular: backUpOnCellular,
            pauseOnLowBattery: pauseOnLowBattery, threshold: batteryThreshold)
        // a recovering/cancelled worker may still be draining.
        isStopping = false
        rerunRequested = runTask != nil
        if runTask != nil { policyInterruptedRun = true }
        conditionsChanged()
    }

    var canStartBackup: Bool {
        PhotoLibraryService.hasFullAccess && !isRunning
            && (requiresExplicitResume || (libraryStatus.map { $0.pending > 0 } ?? true))
    }

    private var conditionsAllowWork: Bool {
        conditions.allowsWork(allowCellular: backUpOnCellular,
            pauseOnLowBattery: pauseOnLowBattery, threshold: batteryThreshold)
    }

    /// the pipeline needs an upload request and permitted connection/battery conditions.
    private var uploadsPermitted: Bool {
        runAllowsUploads && conditionsAllowWork && !requiresExplicitResume
    }

    private let client: ImoraClient
    private let index: BackupIndex
    private var runTask: Task<Void, Never>?
    private var localChangedTask: Task<Void, Never>?
    /// one dedicated recent-asset worker, separate from the bounded backlog
    /// pool. it shares the same condition overrides as the backlog.
    private var recentTask: Task<Void, Never>?
    private var recentRescanRequested = false
    private var recentQuotaReached = false
    private var recentAttempted: [String: DeviceAsset] = [:]
    private var activeBacklogCheckpoint: Date?
    private var activeBacklogIDs: Set<String> = []
    private var backlogUploadIDs: Set<String> = []
    /// whether the current or next run may upload. false makes the run a
    /// passive reconcile - scan, hash and bulk-check only - which rebuilds
    /// the index quietly and ends back at idle.
    private var runAllowsUploads = true
    private var manualBackupRequested = false
    private var rerunRequested = false
    /// foreground/path recovery remains pending until the old run exits.
    private var recoveryRequested = false
    /// distinguishes a conditions-policy stop from an explicit user cancellation.
    private var policyInterruptedRun = false
    private var changeObserver: LibraryChangeObserver?
    private var networkWatcher: NetworkPathWatcher?
    private var batteryWatcher: BatteryLevelWatcher?
    private var isStopping = false
    private var isShutDown = false
    private var remoteReconciliationTask: Task<Void, Never>?
    private var activeCleanupReportID: UUID?
    private var recoverAfterExpiration = false
    private var explicitResumeRequired = false
    private var hashingAssetIDs: Set<String> = []
    private var runLifetime = BackgroundUploader.RunLifetime()

    /// host|userId, stamped onto every background upload so a completion can
    /// never be applied to a different account's index.
    private var accountKey: String {
        "\(client.serverKey)|\(userId ?? "")"
    }

    /// An expiration can arrive before the first current-user response. Keep
    /// that server's unresolved request paused after its identity is restored.
    private var unresolvedAccountKey: String { "\(client.serverKey)|" }

    var requiresExplicitResume: Bool {
        explicitResumeRequired || BackupIntentStore.shared.requiresExplicitResume(accountKey)
            || (userId != nil && BackupIntentStore.shared.requiresExplicitResume(unresolvedAccountKey))
    }

    private var automaticBackupMayResume: Bool {
        !requiresExplicitResume
            && BackupIntentStore.shared.canResumeAutomatically(accountKey, autoBackup: autoBackup)
    }

    nonisolated static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "backup")
    }

    init(client: ImoraClient) {
        self.client = client
        self.autoBackup = UserDefaults.standard.bool(forKey: Self.autoBackupKey)
        self.backUpOnCellular = UserDefaults.standard.bool(forKey: Self.cellularBackupKey)
        self.excludeScreenshots = UserDefaults.standard.bool(forKey: Self.excludeScreenshotsKey)
        self.reminderDismissed = UserDefaults.standard.bool(forKey: Self.reminderDismissedKey)
        self.pauseOnLowBattery = UserDefaults.standard.object(forKey: Self.lowBatteryKey) as? Bool ?? true
        let threshold = UserDefaults.standard.object(forKey: Self.batteryThresholdKey) as? Int ?? 15
        self.batteryThreshold = min(50, max(1, threshold))
        let storedHashWorkers = UserDefaults.standard.integer(forKey: Self.hashWorkersKey)
        self.hashWorkers = Self.hashWorkerOptions.contains(storedHashWorkers)
            ? storedHashWorkers
            : Self.defaultHashWorkers
        let storedMaxUploadMB = UserDefaults.standard.object(forKey: Self.maxUploadSizeMBKey) as? Int
        self.maxUploadSizeMB = UploadSizeLimit.bytes(forMegabytes: storedMaxUploadMB) == nil
            ? nil : storedMaxUploadMB
        self.index = BackupIndex()
        self.dateOrder = BackupDateOrder(rawValue: UserDefaults.standard.string(forKey: Self.dateOrderKey) ?? "") ?? .newestFirst
        self.mediaPriority = BackupMediaPriority(rawValue: UserDefaults.standard.string(forKey: Self.mediaPriorityKey) ?? "") ?? .together
        if repeatedFailureLedger.removeLegacySizeLimitFailures() {
            repeatedFailureLedger.save()
        }
        // stale exports from a killed run are useless without their request.
        let scratch = Self.scratchDirectory
        Task.detached { try? FileManager.default.removeItem(at: scratch) }
        let savedCellularOverride = UserDefaults.standard.bool(forKey: Self.cellularOverrideKey)
        let savedBatteryOverride = UserDefaults.standard.bool(forKey: Self.batteryOverrideKey)
        conditions.cellularOverride = savedCellularOverride
        conditions.batteryOverride = savedBatteryOverride
        updateChangeObserver()
        batteryWatcher = BatteryLevelWatcher { [weak self] percent in
            guard let self, !self.isShutDown else { return }
            let wasAllowed = self.conditionsAllowWork
            self.conditions.updateBattery(percent, threshold: self.batteryThreshold)
            if wasAllowed != self.conditionsAllowWork {
                self.conditionsChanged(recovered: !wasAllowed && self.conditionsAllowWork)
            }
        }
        networkWatcher = NetworkPathWatcher { [weak self] path in
            self?.networkChanged(connected: path.connected, metered: path.expensive,
                wifi: path.wifi, cellular: path.cellular)
        }
    }

    /// called by sessionstore on logout. the manager must not outlive its client.
    func shutdown() {
        isShutDown = true
        activeTransfers.removeAll()
        remoteReconciliationTask?.cancel()
        remoteReconciliationTask = nil
        BackupIntentStore.shared.set(false, account: accountKey)
        BackupProcessing.shared.schedule(needed: false)
        isStopping = true
        policyInterruptedRun = false
        rerunRequested = false
        recoveryRequested = false
        activeBacklogCheckpoint = nil
        recentRescanRequested = false
        recentTask?.cancel()
        runTask?.cancel()
        runTask = nil
        let index = index
        Task { await index.flush() }
        localChangedTask?.cancel()
        localChangedTask = nil
        BackgroundUploader.shared.setOrphanHandler(nil)
        // transfers outlive the process, so signing out has to stop them
        // explicitly or they would keep filling a stranger's library.
        BackgroundUploader.shared.cancelAll(contextID: client.context.id)
        if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
        networkWatcher?.stop()
        networkWatcher = nil
        batteryWatcher?.stop()
        batteryWatcher = nil
        conditions.cellularOverride = false
        conditions.batteryOverride = false
    }

    // MARK: - triggers

    /// the settings screen confirms the current cellular/low-battery holds first.
    func start() {
        guard !isShutDown else { return }
        manualBackupRequested = true
        if !saveUnfinishedBackup() {
            manualBackupRequested = false
            return
        }
        conditions.overrideCurrentHolds(allowCellular: backUpOnCellular,
            pauseOnLowBattery: pauseOnLowBattery, threshold: batteryThreshold)
        // A fresh action can arrive while the expired run is still draining.
        // Let that worker finish before beginning its explicit successor.
        if isStopping, runTask != nil {
            recoveryRequested = true
            return
        }
        beginRun(uploads: true)
    }

    /// automatic preparation also waits for a permitted connection because
    /// hashing may download originals from iCloud.
    private func startAutomatically() {
        // do not start an iCloud-backed hash pass before the path monitor has
        // identified the connection, or while the user's data plan is gated.
        guard networkStatusKnown, conditionsAllowWork, !requiresExplicitResume else { return }
        if runTask == nil { policyInterruptedRun = false }
        else { recentAttempted = [:] }
        beginRun(uploads: automaticBackupMayResume && conditionsAllowWork)
    }

    private func beginRun(uploads: Bool) {
        guard !isShutDown, !requiresExplicitResume else { return }
        if runTask == nil {
            isStopping = false
            recoverAfterExpiration = false
            runLifetime = BackgroundUploader.RunLifetime()
        }
        if uploads, userId != nil, manualBackupRequested || hasUnfinishedBackup {
            guard saveUnfinishedBackup() else { return }
        } else {
            scheduleRecovery()
        }
        // a run is already going: raise its upload gate instead of dropping
        // the ask. a passive reconcile reads the flag again before uploading.
        if runTask != nil {
            if uploads { runAllowsUploads = true }
            requestRecentBackup()
            return
        }
        isStopping = false
        recentAttempted = [:]
        recentQuotaReached = false
        recentBackedUpMedia = MediaCounts()
        recentBackupStatus = nil
        runAllowsUploads = uploads
        runTask = Task { await run() }
    }

    /// ensures a full upload run and suspends until the pipeline goes quiet.
    /// the continued-processing task has to outlive the whole run, so it needs
    /// something to await. escalation can chain a follow-up run, hence the loop.
    func runToCompletion() async {
        start()
        while let task = runTask {
            await task.value
        }
    }

    func cancel() {
        ContinuedProcessing.backup.withdraw(for: self)
        manualBackupRequested = false
        recoverAfterExpiration = false
        BackupIntentStore.shared.set(false, account: accountKey)
        if userId != nil { BackupIntentStore.shared.set(false, account: unresolvedAccountKey) }
        explicitResumeRequired = false
        BackupProcessing.shared.schedule(needed: false)
        stopWork()
    }

    private func stopWork(cancelTransfers: Bool = true) {
        // stopping also withdraws any upload ask that raced this cancel.
        runAllowsUploads = false
        isStopping = true
        activeTransfers.removeAll()
        policyInterruptedRun = false
        rerunRequested = false
        recoveryRequested = false
        recentRescanRequested = false
        // mark the run before cancelling its workers: their cancellation
        // handlers must detach from system-owned uploads instead of stopping them.
        if !cancelTransfers { runLifetime.expire() }
        recentTask?.cancel()
        runTask?.cancel()
        if cancelTransfers { BackgroundUploader.shared.cancelAll(contextID: client.context.id) }
        let index = index
        Task { await index.flush() }
    }

    private var hasUnfinishedBackup: Bool {
        userId != nil && BackupIntentStore.shared.contains(accountKey)
    }

    private func saveUnfinishedBackup() -> Bool {
        let stored = manualBackupRequested
            ? BackupIntentStore.shared.resume(account: accountKey)
            : BackupIntentStore.shared.set(true, account: accountKey)
        guard stored else {
            phase = .error(String(localized: "Could not save backup recovery state. Check available device storage and try again."))
            return false
        }
        if manualBackupRequested {
            if userId != nil,
               BackupIntentStore.shared.contains(unresolvedAccountKey) || BackupIntentStore.shared.requiresExplicitResume(unresolvedAccountKey),
               !BackupIntentStore.shared.set(false, account: unresolvedAccountKey) {
                phase = .error(String(localized: "Could not save backup recovery state. Check available device storage and try again."))
                return false
            }
            explicitResumeRequired = false
        }
        scheduleRecovery()
        return true
    }

    func scheduleRecovery() {
        BackupProcessing.shared.schedule(needed: !isShutDown && (!isStopping || recoverAfterExpiration) && automaticBackupMayResume)
    }

    /// A discretionary processing budget may retry later. A continued task's
    /// system stop or Cancel action instead requires a fresh foreground action.
    func pauseForBackgroundExpiration(requiresExplicitResume: Bool = false) {
        let pending = hasUnfinishedBackup
        if requiresExplicitResume {
            manualBackupRequested = false
            explicitResumeRequired = true
            if !BackupIntentStore.shared.pause(account: accountKey) {
                backupLog.error("could not persist explicit backup resume requirement")
            }
        }
        recoverAfterExpiration = true
        stopWork(cancelTransfers: false)
        // retain a retry without letting a network callback restart this run.
        BackupProcessing.shared.schedule(needed: !isShutDown && !self.requiresExplicitResume && (autoBackup || pending))
    }

    func runScheduledBackup() async -> Bool {
        guard !isShutDown, !requiresExplicitResume, PhotoLibraryService.hasFullAccess else { return false }
        if userId == nil {
            do { userId = try await client.currentUser().id }
            catch { return false }
        }
        // NetworkPathWatcher delivers asynchronously during a cold launch.
        for _ in 0..<20 where !networkStatusKnown {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, networkStatusKnown,
              conditionsAllowWork,
              automaticBackupMayResume else { return false }
        await primeLocalState()
        startAutomatically()
        while let task = runTask { await task.value }
        guard !Task.isCancelled, !hasUnfinishedBackup, case .done(let result) = phase else { return false }
        return result.failed == 0
    }

    func flushPendingIndexChanges() async {
        await index.flush()
    }

    /// starts a full run when auto backup is on, and a passive reconcile
    /// otherwise, so assets already on the server are recognized - after a
    /// reinstall or an upload from another device - without sending anything.
    func startIfIdle() {
        let runWasActive = runTask != nil
        networkWatcher?.refresh()
        guard PhotoLibraryService.hasFullAccess, !requiresExplicitResume else { return }
        localChanged()
        if runTask != nil {
            // a healthy run picks new captures up itself; only a run stopped
            // by an expired budget needs a successor once it has drained.
            if runWasActive && isStopping && recoverAfterExpiration {
                recoveryRequested = true
            }
            recentAttempted = [:]
            requestRecentBackup()
            return
        }
        startAutomatically()
    }

    private func enableAndStart() async {
        guard await PhotoLibraryService.requestFullAccess() else {
            phase = .error(String(localized: "full photo library access is required for backup."))
            updateChangeObserver()
            return
        }
        updateChangeObserver()
        // turning the switch on is a vote for automatic backup, not for
        // spending the data plan, so the cellular rule still applies.
        startAutomatically()
    }

    /// the connection changed under us. the upload loop reads the rule live,
    /// so turning metered stops an automatic run from queueing anything more
    /// on its own; only the way back needs a nudge.
    private func networkChanged(connected: Bool, metered: Bool, wifi: Bool, cellular: Bool) {
        guard !isShutDown else { return }
        let wasAllowed = conditionsAllowWork
        if !connected {
            Task { [weak self] in
                guard let self, !self.isShutDown else { return }
                await self.index.invalidateProofs()
                await self.refreshLocalSnapshots()
            }
        }
        conditions.updateNetwork(connected: connected, metered: metered, wifi: wifi, cellular: cellular)
        conditionsChanged(recovered: !wasAllowed && conditionsAllowWork)
    }

    private func conditionsChanged(recovered: Bool = false) {
        guard !isShutDown else { return }
        if recovered && runTask != nil && (!isStopping || recoverAfterExpiration) {
            recoveryRequested = true
        }
        if !automaticRecentUploadsPermitted { recentTask?.cancel() }
        if !conditionsAllowWork, !isStopping, case .hashing = phase {
            // PhotoKit may be downloading originals, not merely reading local
            // bytes. stop preparation when connection or battery rules block it.
            policyInterruptedRun = true
            runTask?.cancel()
        }
        guard !isStopping, conditionsAllowWork, PhotoLibraryService.hasFullAccess else { return }
        // the queueing loop has already walked past whatever it skipped, so
        // a run that far along needs a fresh one to pick those up. anything
        // earlier just has its gate raised.
        if case .uploading = phase { rerunRequested = true }
        startAutomatically()
    }

    /// the observer keeps the merged timeline fresh, so it registers with
    /// full access alone - auto backup only decides whether uploads start.
    private func updateChangeObserver() {
        if PhotoLibraryService.hasFullAccess {
            guard changeObserver == nil else { return }
            let observer = LibraryChangeObserver { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.libraryChanged() }
            }
            PHPhotoLibrary.shared().register(observer)
            changeObserver = observer
        } else if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    private func libraryChanged() {
        LocalImageLoader.shared.noteLibraryChange()
        localChanged()
        // keyed on the task, not the phase: a change landing while the run
        // winds down must not be lost.
        if runTask != nil {
            rerunRequested = true
            requestRecentBackup()
        } else {
            startIfIdle()
        }
    }

    // MARK: - recent captures

    private var automaticRecentUploadsPermitted: Bool {
        autoBackup && conditionsAllowWork && !requiresExplicitResume
            && !isStopping && !recentQuotaReached && PhotoLibraryService.hasFullAccess
    }

    private func requestRecentBackup() {
        guard runTask != nil, activeBacklogCheckpoint != nil,
              automaticRecentUploadsPermitted else { return }
        recentRescanRequested = true
        guard recentTask == nil else { return }
        recentTask = Task { await backUpRecentAssets() }
    }

    /// re-scan on library events, not a timer. yield to newly arrived captures
    /// after the current asset, and do not retry a failed revision in a loop.
    /// backlog IDs stay assigned to their original worker for the whole run.
    private func backUpRecentAssets() async {
        defer {
            recentBackupStatus = recentBackedUpCount > 0
                ? String(localized: "\(recentBackedUpMedia.text) backed up from recent captures") : nil
            recentTask = nil
            // Wi-Fi may return while the cancelled worker is still draining.
            // an explicit Cancel or disabled automatic backup cannot restart it.
            if recentRescanRequested { requestRecentBackup() }
        }
        await refreshUploadProtocol()
        repeat {
            recentRescanRequested = false
            guard !Task.isCancelled, automaticRecentUploadsPermitted,
                  let checkpoint = activeBacklogCheckpoint else { return }
            // Photos can send frequent changes while originals download.
            // empty checks stay silent: inserting/removing a status row for
            // each scan makes both backup screens flash and shift their layout.
            // publish status only when a candidate is actually being backed up.
            let scanned = await PhotoLibraryService.scan()
            let entries = await index.allEntries()
            let candidates = scanned.filter { asset in
                guard includesInBackup(asset), let created = asset.creationDate, created > checkpoint,
                      !activeBacklogIDs.contains(asset.localIdentifier),
                      recentAttempted[asset.localIdentifier] != asset else { return false }
                if let entry = entries[asset.localIdentifier],
                   entry.matches(modificationDate: asset.modificationDate),
                   entry.isBackedUp || entry.unsupported { return false }
                return true
            }
            for asset in candidates {
                guard !Task.isCancelled, automaticRecentUploadsPermitted,
                      activeBacklogCheckpoint != nil else { break }
                guard includesInBackup(asset) else { continue }
                // the viewer may already own this asset. its result goes to
                // the same index; a later scan can recover a failed upload.
                if case .uploading = uploadStates[asset.localIdentifier] { continue }
                recentAttempted[asset.localIdentifier] = asset
                await backUpRecentAsset(asset)
                if recentRescanRequested { break }
            }
            await index.flush()
        } while recentRescanRequested && !Task.isCancelled
    }

    private func backUpRecentAsset(_ asset: DeviceAsset) async {
        let localId = asset.localIdentifier
        let transfer = beginActiveTransfer(localIdentifier: localId)
        uploadStates[localId] = .uploading(0)
        recentBackupStatus = String(localized: "Backing up the new item. \(recentBackedUpMedia.text) saved.")
        defer {
            activeTransfers.finish(localIdentifier: localId, attempt: transfer.attempt)
            if Task.isCancelled || !automaticRecentUploadsPermitted {
                recentAttempted[localId] = nil
            }
            if case .uploading = uploadStates[localId] { uploadStates[localId] = nil }
            localChanged()
        }
        do {
            try Task.checkCancellation()
            let current = await PhotoLibraryService.assetInfo(localIdentifier: localId)
            guard let current, includesInBackup(current) else { return }
            try Task.checkCancellation()
            let entry = await index.entry(for: localId)
            if entry == nil || current.modificationDate == nil || entry?.isLivePhoto != current.isLivePhoto || entry?.matches(modificationDate: current.modificationDate) != true {
                let preparation = transfer.reporter.component()
                let hashes = try await PhotoLibraryService.hash(
                    localIdentifier: localId, includeMotion: current.isLivePhoto,
                    onResourceProgress: { preparation.resourceProgress($0) }
                )
                try Task.checkCancellation()
                await index.setHashed(
                    localId: localId, isLivePhoto: current.isLivePhoto,
                    primaryChecksum: hashes.primary, motionChecksum: hashes.motion,
                    modificationDate: current.modificationDate,
                    primaryByteCount: hashes.primaryBytes, motionByteCount: hashes.motionBytes
                )
            }
            try Task.checkCancellation()
            guard automaticRecentUploadsPermitted else { return }
            transfer.reporter.verifying()
            let pending = try await checkPhase([current], updatesPhase: false)
            try Task.checkCancellation()
            guard automaticRecentUploadsPermitted else { return }
            if pending.isEmpty {
                if await index.entry(for: localId)?.isBackedUp == true { recentBackedUpMedia.add(current) }
                return
            }
            let outcome = await Self.uploadOne(
                asset: current, client: client, index: index,
                deviceId: DeviceID.current,
                account: accountKey, maximumRequestBytes: maximumRequestBytes, chunking: chunking,
                lifetime: runLifetime,
                progressReporter: transfer.reporter
            ) { [weak self] id, fraction in
                Task { @MainActor [weak self] in self?.noteUploadProgress(id, fraction) }
            }
            switch outcome {
            case .uploaded:
                summary.uploadedMedia.add(asset)
                recentBackedUpMedia.add(current)
            case .duplicate:
                summary.duplicateMedia.add(asset)
                recentBackedUpMedia.add(current)
            case .sizeExcluded:
                summary.skippedMedia.add(asset)
            case .failed(let reason, let kind):
                guard !Task.isCancelled else { return }
                summary.failedMedia.add(asset)
                if lastFailure == nil { lastFailure = reason }
                markUploadFailed(asset, reason: reason, kind: kind)
            case .skipped:
                if !Task.isCancelled { summary.skippedMedia.add(asset) }
            case .quota(let message):
                recentQuotaReached = true
                throw ImoraError.http(400, message)
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            summary.failedMedia.add(asset)
            if lastFailure == nil { lastFailure = error.localizedDescription }
            markUploadFailed(asset, reason: error.localizedDescription, kind: .init(error: error))
        }
    }

    private func finishRecentBackups() async {
        while let task = recentTask { await task.value }
    }

    // MARK: - local timeline support

    /// refreshes the badge snapshot and tells the hub the device library or
    /// index changed. coalesced: a run completes uploads several times a
    /// second, and rebuilding four full index maps per upload starved the
    /// main actor on large libraries.
    private func localChanged() {
        guard localChangedTask == nil else { return }
        localChangedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.localChangedTask = nil
            await self.refreshLocalSnapshots()
        }
    }

    /// one hop for all four maps, built inside the actor: assembling them on
    /// the main actor was a visible hitch per upload on a large library.
    private func refreshLocalSnapshots() async {
        let snapshot = await index.localSnapshot()
        sizeExcludedRequestBytesByLocal = snapshot.sizeExcludedRequestBytesByLocal
        updateSizeExclusions()
        if userId != nil, repeatedFailureLedger.entries.contains(where: { $0.account == accountKey }) {
            let before = repeatedFailureLedger.entries.count
            repeatedFailureLedger.clearBackedUp(account: accountKey,
                revisions: snapshot.backedUpLocalRevisions)
            if repeatedFailureLedger.entries.count != before { saveRepeatedFailures() }
        }
        backedUpRemoteIds = snapshot.backedUpRemoteIds
        pairedLocalIdentifierByRemoteId = snapshot.localByRemote
        remoteIdentifierByLocalId = snapshot.remoteByLocal
        localIdentifierByRemoteId = snapshot.renderableLocalByRemote
        await refreshLibraryStatus()
        onLocalChange?()
    }

    private func updateSizeExclusions() {
        guard let maximumRequestBytes else {
            sizeExcludedLocalIdentifiers = []
            return
        }
        sizeExcludedLocalIdentifiers = Set(sizeExcludedRequestBytesByLocal.compactMap { localId, bytes in
            bytes > maximumRequestBytes ? localId : nil
        })
    }

    /// a partial Live Photo is not yet a verified backup.
    func hasVerifiedBackup(localIdentifier: String) -> Bool {
        guard let remoteId = remoteIdentifierByLocalId[localIdentifier] else { return false }
        return backedUpRemoteIds.contains(remoteId)
    }

    /// metadata only: safe even while cellular uploads are held. the Photos
    /// service reuses its scan until the library change token changes.
    func refreshLibraryStatus() async {
        libraryStatusGeneration += 1
        let generation = libraryStatusGeneration
        guard !isShutDown, PhotoLibraryService.hasFullAccess, let userId else {
            libraryStatus = nil
            return
        }
        await refreshUploadProtocol()
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else {
            libraryStatus = nil
            return
        }
        let assets = await PhotoLibraryService.scan()
        guard !isShutDown, !Task.isCancelled, PhotoLibraryService.hasFullAccess else { return }
        let status = await index.libraryStatus(for: assets, excludeScreenshots: excludeScreenshots)
        guard generation == libraryStatusGeneration, !isShutDown, PhotoLibraryService.hasFullAccess else { return }
        if repeatedFailureLedger.entries.contains(where: { $0.account == accountKey }) {
            let before = repeatedFailureLedger.entries.count
            let revisions = Dictionary(uniqueKeysWithValues: assets.map {
                ($0.localIdentifier, $0.modificationDate)
            })
            repeatedFailureLedger.reconcile(account: accountKey, currentRevisions: revisions)
            if repeatedFailureLedger.entries.count != before { saveRepeatedFailures() }
        }
        libraryStatus = status
    }

    /// the server repainted these assets, so their device twins are stale
    /// pixels. the pairing itself survives - deletes still cascade - but grids
    /// and the viewer go back to the server render for them.
    func requestRemoteReconciliation() {
        guard !isShutDown, remoteReconciliationTask == nil else { return }
        remoteReconciliationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !self.isShutDown, !Task.isCancelled else { return }
            self.remoteReconciliationTask = nil
            if self.runTask != nil { self.rerunRequested = true }
            self.startIfIdle()
        }
    }

    func noteRemoteChange(_ remoteIDs: Set<String>, change: BackupRemoteChange) {
        guard change != .hidden, !isShutDown else { return }
        Task { [weak self] in
            guard let self, !self.isShutDown else { return }
            await self.index.noteRemoteChange(ids: remoteIDs, change: change, generation: self.client.context.id)
            guard !self.isShutDown else { return }
            await self.refreshLocalSnapshots()
            self.requestRemoteReconciliation()
        }
    }

    func noteRemoteEdits(_ remoteIds: Set<String>) {
        guard !remoteIds.isEmpty else { return }
        for id in remoteIds { localIdentifierByRemoteId[id] = nil }
        Task { [weak self] in
            guard let self, await self.index.markRemoteEdited(remoteIds) else { return }
            self.localIdentifierByRemoteId = await self.index.renderableRemoteToLocalMap()
        }
    }

    /// loads the index for the signed-in account so badges and the merged
    /// timeline are right from the first frame.
    func primeLocalState() async {
        guard let userId else { return }
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else { return }
        await refreshLocalSnapshots()
        updateChangeObserver()
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()
    }

    // MARK: - background uploads

    /// transfers handed to the system finish whether or not this process is
    /// still around. anything that landed while it was not has to reach the
    /// index here, or the next run would send the same bytes again.
    private func adoptBackgroundUploads() {
        BackgroundUploader.shared.setOrphanHandler { [weak self] completions in
            guard let self else { return [] }
            return await self.applyBackgroundUploads(completions)
        }
        BackgroundUploader.shared.sweepAbandonedBodies()
    }

    private nonisolated enum ReceiptOutcome {
        /// nothing to write: the receipt can go.
        case settled
        /// applied in memory: it can go once the index is on disk.
        case applied
        /// not ours to judge yet: it stays journaled.
        case retained
    }

    /// applies a batch of journaled receipts with a single index write, and
    /// returns the ones that may be acknowledged.
    private func applyBackgroundUploads(
        _ completions: [BackgroundUploader.Completion]
    ) async -> [BackgroundUploader.Completion] {
        guard let userId, !isShutDown else { return [] }
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else { return [] }
        var settled: [BackgroundUploader.Completion] = []
        var applied: [BackgroundUploader.Completion] = []
        for completion in completions {
            switch await applyBackgroundUpload(completion) {
            case .settled: settled.append(completion)
            case .applied: applied.append(completion)
            case .retained: break
            }
        }
        guard !applied.isEmpty else { return settled }
        guard !isShutDown, await index.flush() else { return settled }
        localChanged()
        return settled + applied
    }

    private func applyBackgroundUpload(_ completion: BackgroundUploader.Completion) async -> ReceiptOutcome {
        guard !isShutDown else { return .retained }
        // another account's upload cannot be applied here. if that account
        // signs in again, its checksum pass finds the asset on the server.
        guard completion.ticket.account == accountKey else { return .settled }
        // legacy tickets lack revision proof. the ordinary checksum check will
        // rediscover their uploads; never attach them blindly to current bytes.
        if let version = completion.ticket.version, version != 1 { return .retained }
        guard let source = completion.ticket.source else { return .settled }
        guard PhotoLibraryService.hasFullAccess else { return .retained }
        guard let current = await PhotoLibraryService.assetInfo(localIdentifier: completion.ticket.localId) else {
            return .settled
        }
        guard !isShutDown, completion.ticket.account == accountKey else { return .retained }
        guard current.modificationDate == source.modificationDate,
              current.isLivePhoto == source.isLivePhoto else { return .settled }
        return await index.applyReceipt(completion, persist: false) ? .applied : .retained
    }

    /// every device asset paired with its backup status, newest first.
    func localTimelineAssets() async -> [LocalTimelineItem] {
        guard PhotoLibraryService.hasFullAccess, let userId else { return [] }
        // the library walk and the index decode are independent, and at
        // launch each is a few hundred milliseconds on a large library, so
        // they overlap instead of queueing.
        async let scanned = PhotoLibraryService.scan()
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else { return [] }
        let entries = await index.allEntries()
        return await scanned.map { asset in
            let entry = entries[asset.localIdentifier]
            return LocalTimelineItem(
                device: asset,
                remoteId: entry?.primaryRemoteId,
                backedUp: entry?.isBackedUp ?? false
            )
        }
    }

    private func beginActiveTransfer(localIdentifier: String) -> (attempt: UUID, reporter: BackupTransferProgressReporter) {
        let attempt = activeTransfers.begin(localIdentifier: localIdentifier)
        let reporter = BackupTransferProgressReporter { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutDown, self.client.context.isActive,
                      self.activeTransfers.apply(event, localIdentifier: localIdentifier, attempt: attempt) else { return }
                self.onContinuedProgress?()
            }
        }
        return (attempt, reporter)
    }

    private func noteUploadProgress(_ localId: String, _ fraction: Double) {
        guard case .uploading(let current) = uploadStates[localId] else { return }
        // quantized so progress redraws stay coarse.
        guard fraction >= 1 || fraction - current >= 0.02 else { return }
        uploadStates[localId] = .uploading(min(fraction, 1))
        // a single large video can hold the phase still for minutes, and a
        // continued-processing task that stops reporting gets expired.
        onContinuedProgress?()
    }

    /// how far the current run has come, 0...1, counting the bytes already sent
    /// for uploads still in flight. hashing takes the first fifth because it
    /// runs before a single byte leaves the device.
    var progressFraction: Double {
        switch phase {
        case .idle, .scanning, .cancelled:
            0
        case .hashing(let done, let total):
            Double(continuedPreparationProgress(completed: done, total: total).completedUnitCount) / 1_000_000
        case .checking:
            0.2
        case .uploading(let done, let total):
            total > 0 ? 0.2 + 0.8 * min(Double(done) + inFlightFraction, Double(total)) / Double(total) : 0.2
        case .done, .error:
            1
        }
    }

    private var inFlightFraction: Double {
        uploadStates.reduce(0) { total, item in
            if backlogUploadIDs.contains(item.key), case .uploading(let fraction) = item.value {
                return total + fraction
            }
            return total
        }
    }

    private func continuedPreparationProgress(completed: Int, total: Int) -> ContinuedProgress {
        let fractions = activeTransfers.items.filter {
            hashingAssetIDs.contains($0.id) && ($0.stage == .preparing || $0.stage == .downloadingOriginal)
        }.map(\.fraction)
        return ContinuedProgress.preparation(completed: completed, total: total, inFlightFractions: fractions)
    }

    // MARK: - pipeline

    private func run() async {
        let startedAt = Date()
        let dateOrder = dateOrder
        let mediaPriority = mediaPriority
        var uploadsAllowed = uploadsPermitted
        var chainFullRun = false
        var reportsOutcome = true
        summary = BackupSummary()
        lastFailure = nil
        phase = .scanning
        do {
            if uploadsAllowed {
                guard await PhotoLibraryService.requestFullAccess() else {
                    phase = .error(String(localized: "full photo library access is required for backup."))
                    runTask = nil
                    return
                }
            } else {
                // a passive reconcile never prompts. access was there at spawn
                // and this only guards against it vanishing in between.
                guard PhotoLibraryService.hasFullAccess else {
                    phase = .idle
                    runTask = nil
                    return
                }
            }
            let user = try await client.currentUser()
            userId = user.id
            await refreshUploadProtocol()
            if hasUnfinishedBackup, !isStopping { runAllowsUploads = true }
            guard await index.load(serverHost: client.serverKey, userId: user.id, generation: client.context.id) else {
                throw SingleAssetBackupError.failed(String(localized: "Backup state is unavailable. Unlock the device and try again."))
            }
            if runAllowsUploads, !isStopping, manualBackupRequested || hasUnfinishedBackup,
               !saveUnfinishedBackup() {
                throw SingleAssetBackupError.failed(String(localized: "Could not save backup recovery state."))
            }

            adoptBackgroundUploads()
            await BackgroundUploader.shared.replayReceipts()
            try Task.checkCancellation()
            let checkpoint = await index.ensureBacklogCheckpoint(at: startedAt)
            let allAssets = await PhotoLibraryService.scan()
            try Task.checkCancellation()
            // exclusion changes backup selection, never the library or index ownership.
            await index.prune(keeping: Set(allAssets.map(\.localIdentifier)))
            libraryStatus = await index.libraryStatus(for: allAssets, excludeScreenshots: excludeScreenshots)
            let scanned = allAssets.filter(includesInBackup)
            // assign the snapshot before starting the recent-capture worker.
            let backlogCandidates = automaticRecentUploadsPermitted ? scanned.filter {
                ($0.creationDate ?? .distantPast) <= checkpoint
            } : scanned
            let backlog = mediaPriority.order(backlogCandidates, by: dateOrder)
            activeBacklogIDs = Set(backlog.map(\.localIdentifier))
            activeBacklogCheckpoint = checkpoint
            requestRecentBackup()

            try await hashPhase(backlog)
            let pending = try await checkPhase(backlog)
            localChanged()
            // read again so a backup asked for during scan, hash or check
            // upgrades this run instead of waiting for the next one, and so
            // a connection that turned metered meanwhile holds it back.
            uploadsAllowed = uploadsPermitted
            if uploadsAllowed {
                try await uploadPhase(pending)
            }

            await finishRecentBackups()
            activeBacklogCheckpoint = nil
            try Task.checkCancellation()
            await stackEditedRevisions()
            if uploadsAllowed {
                let completionAccount = accountKey
                await index.advanceBacklogCheckpoint(to: startedAt, completed: scanned,
                                                     maximumRequestBytes: maximumRequestBytes)
                let entries = await index.allEntries()
                let complete = scanned.allSatisfy { asset in
                    guard let entry = entries[asset.localIdentifier],
                          entry.matches(modificationDate: asset.modificationDate) else { return false }
                    return entry.isBackedUp || entry.unsupported
                        || entry.isSizeExcluded(maximumRequestBytes: maximumRequestBytes)
                }
                if complete {
                    let flushed = await index.flush()
                    // Expiration or an account change may have happened at any
                    // index await. Only the live run can acknowledge completion.
                    try Task.checkCancellation()
                    guard !isStopping, !requiresExplicitResume, !isShutDown,
                          client.context.isActive, accountKey == completionAccount else {
                        throw CancellationError()
                    }
                    if flushed, BackupIntentStore.shared.complete(account: completionAccount) {
                        manualBackupRequested = false
                    }
                }
            }
            await index.flush()
            await refreshLibraryStatus()
            try Task.checkCancellation()
            guard !isStopping, !requiresExplicitResume, !isShutDown, client.context.isActive else {
                throw CancellationError()
            }
            if uploadsAllowed {
                phase = .done(summary)
            } else {
                // a passive reconcile ends where it began: no summary, no
                // notification, just fresh pairings for the merged timeline.
                phase = .idle
                chainFullRun = uploadsPermitted
            }
        } catch {
            activeBacklogCheckpoint = nil
            recentRescanRequested = false
            recentTask?.cancel()
            await finishRecentBackups()
            await index.flush()
            if error is CancellationError || Task.isCancelled {
                // a cancel surfaces as whatever the interrupted call threw,
                // not always as a cancellationerror.
                phase = .cancelled
                // a user cancellation drops any queued library-change rerun.
                // a policy stop restarts only if conditions permit work again
                // while its in-flight PhotoKit work drains.
                rerunRequested = !isStopping
                    && (rerunRequested || (policyInterruptedRun && conditionsAllowWork))
            } else if runAllowsUploads {
                phase = .error(error.localizedDescription)
                // the backup screen still shows the error; the banner is
                // reserved for outcomes the server took part in.
                reportsOutcome = !Self.isUnreachable(error)
            } else {
                // nobody asked for this run, so it fails silently.
                backupLog.error("passive reconcile failed: \((error as NSError).code)")
                phase = .idle
            }
        }
        if case .error(let message) = phase, reportsOutcome { onRunFailed?(message) }
        localChanged()
        activeBacklogIDs = []
        let shouldRecover = recoveryRequested && !isShutDown
        recoveryRequested = false
        if shouldRecover {
            // an expiration stops the old worker, not a later foreground ask.
            // the successor can only start once the old worker is gone.
            isStopping = false
            recoverAfterExpiration = false
        }
        runTask = nil
        scheduleRecovery()
        if chainFullRun {
            // the upload ask arrived after the gate: run again, in full,
            // carrying whatever permission that ask brought with it.
            rerunRequested = false
            beginRun(uploads: true)
            return
        }
        // condition overrides survive run completion until Wi-Fi/charge resets them.
        policyInterruptedRun = false
        if rerunRequested || shouldRecover {
            rerunRequested = false
            startIfIdle()
        }
    }

    /// transport failures that mean the server never saw the request - offline,
    /// dns, timeouts. a run ending on one of these happens on every automatic
    /// retry while the network is away, so it is not an outcome to announce.
    private nonisolated static func isUnreachable(_ error: any Error) -> Bool {
        if case ImoraError.unreachable = error { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private nonisolated enum HashOutcome: Sendable {
        case hashed(DeviceAsset, LocalResourceHashes)
        case failed(DeviceAsset, message: String, kind: RepeatedBackupFailureKind)
        case cancelled(DeviceAsset)

        var asset: DeviceAsset {
            switch self {
            case .hashed(let asset, _), .failed(let asset, _, _), .cancelled(let asset): asset
            }
        }
    }

    private func hashPhase(_ scanned: [DeviceAsset]) async throws {
        // one index snapshot rather than an actor hop per asset: on a large
        // library the hops alone kept the main actor busy for seconds on
        // every launch, under whatever the user was scrolling.
        let entries = await index.allEntries()
        var toHash: [DeviceAsset] = []
        for asset in scanned {
            let entry = entries[asset.localIdentifier]
            if entry == nil || asset.modificationDate == nil || entry?.isLivePhoto != asset.isLivePhoto || entry?.matches(modificationDate: asset.modificationDate) != true {
                toHash.append(asset)
            }
        }
        try Task.checkCancellation()
        guard conditionsAllowWork else {
            if !isStopping { policyInterruptedRun = true }
            throw CancellationError()
        }
        downloadedOriginalsFromICloud = false
        phaseMediaTotal = MediaCounts(assets: toHash)
        phaseMediaCompleted = MediaCounts()
        phase = .hashing(done: 0, total: toHash.count)
        hashingAssetIDs = Set(toHash.map(\.localIdentifier))
        let workerLimit = min(max(1, min(hashWorkers, Self.hashWorkerOptions.max() ?? 32)), toHash.count)
        var cancelled = false
        var attempts: [String: UUID] = [:]
        defer {
            hashingAssetIDs = []
            for (localId, attempt) in attempts { activeTransfers.finish(localIdentifier: localId, attempt: attempt) }
        }
        let reportICloudDownload: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.downloadedOriginalsFromICloud = true
            }
        }
        await withTaskGroup(of: HashOutcome.self) { group in
            var next = 0
            var done = 0

            @MainActor func addNext() {
                guard next < toHash.count, !cancelled, !Task.isCancelled,
                      conditionsAllowWork else { return }
                let asset = toHash[next]
                next += 1
                let transfer = beginActiveTransfer(localIdentifier: asset.localIdentifier)
                attempts[asset.localIdentifier] = transfer.attempt
                let preparation = transfer.reporter.component()
                group.addTask {
                    do {
                        let hashes = try await PhotoLibraryService.hash(
                            localIdentifier: asset.localIdentifier,
                            includeMotion: asset.isLivePhoto,
                            onICloudDownload: reportICloudDownload,
                            onResourceProgress: { preparation.resourceProgress($0) }
                        )
                        return .hashed(asset, hashes)
                    } catch is CancellationError {
                        return .cancelled(asset)
                    } catch {
                        return .failed(asset, message: error.localizedDescription, kind: .init(error: error))
                    }
                }
            }

            for _ in 0..<workerLimit { addNext() }
            while let outcome = await group.next() {
                let localId = outcome.asset.localIdentifier
                if let attempt = attempts.removeValue(forKey: localId) {
                    activeTransfers.finish(localIdentifier: localId, attempt: attempt)
                }
                if Task.isCancelled || !conditionsAllowWork {
                    cancelled = true
                    group.cancelAll()
                    continue
                }
                switch outcome {
                case .hashed(let asset, let hashes):
                    phaseMediaCompleted.add(asset)
                    guard client.context.isActive,
                          await PhotoLibraryService.assetInfo(localIdentifier: asset.localIdentifier) == asset else { addNext(); continue }
                    await index.setHashed(
                        localId: asset.localIdentifier,
                        isLivePhoto: asset.isLivePhoto,
                        primaryChecksum: hashes.primary,
                        motionChecksum: hashes.motion,
                        modificationDate: asset.modificationDate,
                        primaryByteCount: hashes.primaryBytes, motionByteCount: hashes.motionBytes
                    )
                case .failed(let asset, let message, let kind):
                    backupLog.error("hash failed category: \(kind.rawValue)")
                    if lastFailure == nil { lastFailure = message }
                    summary.failedMedia.add(asset)
                    phaseMediaCompleted.add(asset)
                    markUploadFailed(asset, reason: message, kind: kind)
                case .cancelled(_):
                    cancelled = true
                    group.cancelAll()
                    continue
                }
                done += 1
                phase = .hashing(done: done, total: toHash.count)
                addNext()
            }
        }
        if !conditionsAllowWork, !isStopping { policyInterruptedRun = true }
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard conditionsAllowWork else {
            if !isStopping { policyInterruptedRun = true }
            throw CancellationError()
        }
    }

    /// asks the server about every hashed component we cannot prove yet, then
    /// returns the assets that still need uploads.
    private func checkPhase(_ scanned: [DeviceAsset], updatesPhase: Bool = true) async throws -> [DeviceAsset] {
        if updatesPhase { phase = .checking }
        guard !isShutDown, client.context.isActive else { throw BackupVerificationError.stale }
        await index.invalidateProofs(localIds: Set(scanned.map(\.localIdentifier)))
        let sources = await index.allEntries()
        let devices = Dictionary(uniqueKeysWithValues: scanned.map { ($0.localIdentifier, $0) })
        var items: [BulkUploadCheckItem] = []
        for asset in scanned {
            guard let entry = sources[asset.localIdentifier], !entry.unsupported,
                  entry.matches(modificationDate: asset.modificationDate), entry.isLivePhoto == asset.isLivePhoto else { continue }
            items.append(BulkUploadCheckItem(id: asset.localIdentifier, checksum: entry.primaryChecksum))
            if entry.isLivePhoto, let checksum = entry.motionChecksum {
                items.append(BulkUploadCheckItem(id: asset.localIdentifier + Self.motionSuffix, checksum: checksum))
            }
        }
        let results = try await Self.bulkUploadCheck(items, client: client)
        let rows = try BackupVerifier.validatedResults(items: items, results: results)
        guard !isShutDown, client.context.isActive else { throw BackupVerificationError.stale }
        for result in rows.values {
            try Task.checkCancellation()
            let motion = result.id.hasSuffix(Self.motionSuffix)
            let localID = motion ? String(result.id.dropLast(Self.motionSuffix.count)) : result.id
            guard let source = sources[localID], let asset = devices[localID],
                  await PhotoLibraryService.assetInfo(localIdentifier: localID) == asset else { continue }
            await index.applyRemoteCheck(localId: localID, source: source, result: result, motion: motion, generation: client.context.id)
        }
        let entries = await index.allEntries()
        var queue: [DeviceAsset] = []
        var verify: [(DeviceAsset, BackupEntry)] = []
        for asset in scanned {
            guard let entry = entries[asset.localIdentifier], entry.matches(modificationDate: asset.modificationDate) else { continue }
            if entry.unsupported { summary.unsupportedMedia.add(asset) }
            else if entry.verificationState == .trashed { summary.failedMedia.add(asset) }
            else if entry.primaryRemoteId == nil || (entry.isLivePhoto && entry.motionRemoteId == nil) {
                if entry.isSizeExcluded(maximumRequestBytes: maximumRequestBytes) { summary.skippedMedia.add(asset) }
                else { queue.append(asset) }
            } else { verify.append((asset, entry)) }
        }
        let client = client, index = index, account = accountKey
        var attempts: [String: UUID] = [:]
        defer {
            for (localId, attempt) in attempts { activeTransfers.finish(localIdentifier: localId, attempt: attempt) }
        }
        await withTaskGroup(of: (DeviceAsset, BackupEntry, (any Error)?).self) { group in
            var next = 0
            @MainActor func addNext() {
                guard next < verify.count, !Task.isCancelled else { return }
                let (asset, entry) = verify[next]
                next += 1
                let transfer = updatesPhase ? beginActiveTransfer(localIdentifier: asset.localIdentifier) : nil
                if let transfer { attempts[asset.localIdentifier] = transfer.attempt }
                group.addTask {
                    if let transfer {
                        let resource = await PhotoLibraryService.primaryResourceInfo(localIdentifier: asset.localIdentifier)
                        transfer.reporter.verifying(filename: resource?.filename)
                    }
                    do {
                        try await Self.verifyBackup(asset: asset, entry: entry, client: client, index: index, account: account)
                        return (asset, entry, nil)
                    } catch { return (asset, entry, error) }
                }
            }
            for _ in 0..<min(Self.verificationWorkers, verify.count) { addNext() }
            while let (asset, source, error) = await group.next() {
                if let attempt = attempts.removeValue(forKey: asset.localIdentifier) {
                    activeTransfers.finish(localIdentifier: asset.localIdentifier, attempt: attempt)
                }
                guard !isShutDown, client.context.isActive, !Task.isCancelled else { group.cancelAll(); continue }
                if let error {
                    let state = (error as? BackupVerificationError)?.state ?? .failed
                    await index.recordVerificationFailure(localId: asset.localIdentifier, source: source, generation: client.context.id, state: state)
                    if case BackupVerificationError.component(let id, .missing) = error {
                        await index.clearMissingComponent(localId: asset.localIdentifier, source: source, remoteID: id, generation: client.context.id)
                        queue.append(asset)
                    } else {
                        summary.failedMedia.add(asset)
                        markUploadFailed(asset, reason: error.localizedDescription, kind: .init(error: error))
                        if lastFailure == nil { lastFailure = error.localizedDescription }
                    }
                } else { summary.duplicateMedia.add(asset) }
                addNext()
            }
        }
        try Task.checkCancellation()
        guard client.context.isActive else { throw BackupVerificationError.stale }
        return queue
    }

    @concurrent
    private static func verifyBackup(asset: DeviceAsset, entry: BackupEntry, client: ImoraClient, index: BackupIndex, account: String) async throws {
        guard let owner = account.split(separator: "|").last.map(String.init), !owner.isEmpty else { throw BackupVerificationError.stale }
        let proof = try await BackupVerifier.verify(asset: asset, entry: entry, ownerID: owner, account: account,
                                                   generation: client.context.id, remote: client, repairEmptyPair: entry.pairRepairDenied != true, current: {
            guard client.context.isActive, !Task.isCancelled else { return false }
            return await PhotoLibraryService.assetInfo(localIdentifier: asset.localIdentifier) == asset
        })
        guard client.context.isActive,
              await index.recordProof(localId: asset.localIdentifier, source: entry, proof: proof)
        else { throw BackupVerificationError.stale }
    }

    @concurrent
    private static func bulkUploadCheck(
        _ items: [BulkUploadCheckItem],
        client: ImoraClient
    ) async throws -> [BulkUploadCheckResult] {
        let batches = items.chunks(of: checkBatchSize)
        guard !batches.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [BulkUploadCheckResult].self) { group in
            let initialCount = min(verificationWorkers, batches.count)
            for batch in batches.prefix(initialCount) {
                group.addTask {
                    let results = try await client.bulkUploadCheck(batch)
                    _ = try BackupVerifier.validatedResults(items: batch, results: results)
                    return results
                }
            }
            var next = initialCount
            var combined: [BulkUploadCheckResult] = []
            combined.reserveCapacity(items.count)
            while let results = try await group.next() {
                combined.append(contentsOf: results)
                if next < batches.count {
                    let batch = batches[next]
                    next += 1
                    group.addTask {
                    let results = try await client.bulkUploadCheck(batch)
                    _ = try BackupVerifier.validatedResults(items: batch, results: results)
                    return results
                }
                }
            }
            return combined
        }
    }

    private func uploadPhase(_ queue: [DeviceAsset]) async throws {
        guard !queue.isEmpty else { return }
        phaseMediaTotal = MediaCounts(assets: queue)
        phaseMediaCompleted = MediaCounts()
        phase = .uploading(done: 0, total: queue.count)
        backlogUploadIDs = Set(queue.map(\.localIdentifier))
        var attempts: [String: UUID] = [:]
        defer {
            backlogUploadIDs = []
            for (localId, attempt) in attempts { activeTransfers.finish(localIdentifier: localId, attempt: attempt) }
        }
        let client = client
        let index = index
        let deviceId = DeviceID.current
        let account = accountKey
        var quotaMessage: String?
        let progress: @Sendable (String, Double) -> Void = { [weak self] localId, fraction in
            // bound once here: the nested task cannot capture the weak slot,
            // which is mutable and could be zeroed mid-flight.
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(localId, fraction) }
        }

        await withTaskGroup(of: (DeviceAsset, UploadOutcome).self) { group in
            var next = 0
            var done = 0
            @MainActor func addNext() {
                // once cancelled, queueing the rest would only race the counter
                // to the end as each new transfer dies on arrival. the network
                // rule is read here too, so walking out of wifi mid-run stops
                // the queue rather than emptying the data plan behind the user.
                guard next < queue.count, quotaMessage == nil, !Task.isCancelled,
                      conditionsAllowWork
                else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                let transfer = beginActiveTransfer(localIdentifier: asset.localIdentifier)
                attempts[asset.localIdentifier] = transfer.attempt
                let lifetime = runLifetime
                let requestLimit = maximumRequestBytes
                let chunking = chunking
                group.addTask {
                    let outcome = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, account: account,
                        maximumRequestBytes: requestLimit,
                        chunking: chunking,
                        lifetime: lifetime,
                        progressReporter: transfer.reporter,
                        onProgress: progress
                    )
                    return (asset, outcome)
                }
            }
            for _ in 0..<Self.uploadWorkers { addNext() }
            while let (asset, outcome) = await group.next() {
                let localId = asset.localIdentifier
                if let attempt = attempts.removeValue(forKey: localId) {
                    activeTransfers.finish(localIdentifier: localId, attempt: attempt)
                }
                done += 1
                phaseMediaCompleted.add(asset)
                switch outcome {
                case .uploaded:
                    summary.uploadedMedia.add(asset)
                    uploadStates[localId] = nil
                case .duplicate:
                    summary.duplicateMedia.add(asset)
                    uploadStates[localId] = nil
                case .sizeExcluded:
                    summary.skippedMedia.add(asset)
                    uploadStates[localId] = nil
                case .failed(let reason, let kind):
                    if lastFailure == nil { lastFailure = reason }
                    summary.failedMedia.add(asset)
                    markUploadFailed(asset, reason: reason, kind: kind)
                case .skipped:
                    summary.skippedMedia.add(asset)
                    uploadStates[localId] = nil
                case .quota(let message):
                    // nothing else can succeed once the account is full.
                    quotaMessage = message
                    uploadStates[localId] = nil
                    group.cancelAll()
                }
                localChanged()
                // the in-flight leftovers of a cancelled run are not progress.
                if !Task.isCancelled {
                    phase = .uploading(done: done, total: queue.count)
                }
                addNext()
            }
        }
        try Task.checkCancellation()
        if let quotaMessage {
            throw ImoraError.http(400, quotaMessage)
        }
    }

    private func updateRepeatedFailureSummary() {
        repeatedFailures = userId == nil ? [] : repeatedFailureLedger.needingAttention(account: accountKey)
    }

    private func saveRepeatedFailures() {
        repeatedFailureLedger.save()
        updateRepeatedFailureSummary()
    }

    /// the short tile overlay remains transient; the gallery banner and
    /// Backup screen retain repeated failures until the asset is verified.
    private func markUploadFailed(_ asset: DeviceAsset, reason: String, kind: RepeatedBackupFailureKind = .other) {
        let localId = asset.localIdentifier
        if !isShutDown, userId != nil, repeatedFailureLedger.recordFailure(
                account: accountKey,
                localIdentifier: localId,
                modificationDate: asset.modificationDate,
                isVideo: asset.isVideo,
                kind: kind,
                capturedAt: asset.creationDate
            ) {
            saveRepeatedFailures()
        }
        uploadStates[localId] = .failed
        localChanged()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.uploadStates[localId] == .failed else { return }
            self.uploadStates[localId] = nil
        }
    }

    private nonisolated static let motionSuffix = "#motion"

    private nonisolated enum UploadOutcome: Sendable {
        case uploaded
        case duplicate
        case sizeExcluded(actualBytes: Int64, maximumBytes: Int64)
        case failed(String, kind: RepeatedBackupFailureKind = .other)
        case skipped
        case quota(String)
    }

    /// uploads every missing component of one asset. motion first for live
    /// photos so the still can link it via livePhotoVideoId.
    @concurrent
    private static func uploadOne(
        asset: DeviceAsset,
        client: ImoraClient,
        index: BackupIndex,
        deviceId: String,
        account: String,
        maximumRequestBytes: Int64?,
        chunking: ChunkedAssetUpload.Policy?,
        lifetime: BackgroundUploader.RunLifetime? = nil,
        progressReporter: BackupTransferProgressReporter? = nil,
        onProgress: @escaping @Sendable (String, Double) -> Void
    ) async -> UploadOutcome {
        // everything up to the hand-off, the export and the request body, has
        // to reach the system before the app is suspended. the lease keeps a
        // backgrounded app running that long, and the uploader lets go of it
        // once the transfer is the system's.
        do {
            try await BackgroundUploader.shared.waitForExisting(account: account, localId: asset.localIdentifier)
        } catch { return .skipped }
        var lease = await ProcessLease.take("backup export")
        defer { lease.release() }
        // the asset may have changed or vanished since the scan.
        guard let current = await PhotoLibraryService.assetInfo(localIdentifier: asset.localIdentifier) else {
            return .skipped
        }
        var entry = await index.entry(for: asset.localIdentifier)
        if entry == nil || current.modificationDate == nil || entry?.isLivePhoto != current.isLivePhoto || entry?.matches(modificationDate: current.modificationDate) != true {
            do {
                let preparation = progressReporter?.component()
                let hashes = try await PhotoLibraryService.hash(
                    localIdentifier: current.localIdentifier,
                    includeMotion: current.isLivePhoto,
                    onResourceProgress: { preparation?.resourceProgress($0) }
                )
                await index.setHashed(
                    localId: current.localIdentifier,
                    isLivePhoto: current.isLivePhoto,
                    primaryChecksum: hashes.primary,
                    motionChecksum: hashes.motion,
                    modificationDate: current.modificationDate,
                    primaryByteCount: hashes.primaryBytes, motionByteCount: hashes.motionBytes
                )
                entry = await index.entry(for: current.localIdentifier)
            } catch is CancellationError {
                return .skipped
            } catch {
                return .failed(error.localizedDescription, kind: .init(error: error))
            }
        }
        guard let entry else { return .failed(String(localized: "no index entry")) }
        if entry.unsupported { return .failed(String(localized: "this file format is not supported by the server.")) }
        if entry.isBackedUp { return .duplicate }
        if entry.isSizeExcluded(maximumRequestBytes: maximumRequestBytes),
           let size = entry.sizeExcludedRequestBytes, let maximumRequestBytes {
            return .sizeExcluded(actualBytes: size, maximumBytes: maximumRequestBytes)
        }

        let createdAt = current.creationDate ?? current.modificationDate ?? Date()
        let modifiedAt = current.modificationDate ?? createdAt
        var uploadedSomething = false

        do {
            var motionRemoteId = entry.motionRemoteId
            if current.isLivePhoto, motionRemoteId == nil {
                guard let motionChecksum = entry.motionChecksum else { return .failed(String(localized: "missing motion checksum")) }
                let upload = AssetUploadRequest(
                    checksum: motionChecksum,
                    deviceAssetId: current.localIdentifier,
                    deviceId: deviceId,
                    fileCreatedAt: createdAt,
                    fileModifiedAt: modifiedAt,
                    isFavorite: false,
                    durationMs: 0,
                    hidden: true,
                    isMotion: true
                )
                let result = try await send(
                    upload, motion: true, client: client, chunking: chunking, account: account,
                    source: entry, maximumRequestBytes: maximumRequestBytes, lease: lease, lifetime: lifetime,
                    progressReporter: progressReporter
                ) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                // recorded in memory at once and made durable by its journaled
                // receipt, so a failed still upload resumes here.
                _ = await index.applyReceipt(.init(ticket: .init(account: account, localId: current.localIdentifier, isMotion: true, bodyPath: "", source: entry), remoteId: result.id), persist: false)
                motionRemoteId = result.id
                if !result.isDuplicate { uploadedSomething = true }
                // the still is exported on whatever wake delivered the motion.
                lease = await ProcessLease.take("backup export")
            }

            if entry.primaryRemoteId == nil {
                let upload = AssetUploadRequest(
                    checksum: entry.primaryChecksum,
                    deviceAssetId: current.localIdentifier,
                    deviceId: deviceId,
                    fileCreatedAt: createdAt,
                    fileModifiedAt: modifiedAt,
                    isFavorite: current.isFavorite,
                    durationMs: current.isVideo ? current.durationMs : 0,
                    livePhotoVideoId: motionRemoteId
                )
                let result = try await send(
                    upload, motion: false, client: client, chunking: chunking, account: account,
                    source: entry, maximumRequestBytes: maximumRequestBytes, lease: lease, lifetime: lifetime,
                    progressReporter: progressReporter
                ) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                _ = await index.applyReceipt(.init(ticket: .init(account: account, localId: current.localIdentifier, isMotion: false, bodyPath: "", source: entry), remoteId: result.id), persist: false)
                if !result.isDuplicate { uploadedSomething = true }
            }
            guard let candidate = await index.entry(for: current.localIdentifier) else { throw BackupVerificationError.stale }
            if let progressReporter {
                let resource = await PhotoLibraryService.primaryResourceInfo(localIdentifier: current.localIdentifier)
                progressReporter.verifying(filename: resource?.filename)
            }
            try await verifyBackup(asset: current, entry: candidate, client: client, index: index, account: account)
            return uploadedSomething ? .uploaded : .duplicate
        } catch is CancellationError {
            return .skipped
        } catch UploadSizeLimit.exceeded(let actualBytes, let maximumBytes) {
            await index.markSizeExcluded(localId: current.localIdentifier,
                                         revision: current.modificationDate,
                                         requestBytes: actualBytes)
            return .sizeExcluded(actualBytes: actualBytes, maximumBytes: maximumBytes)
        } catch let error as ImoraError {
            // Immich 3.4.1's HTTP 400 has no machine-readable quota code.
            // Confirm exhaustion from typed account fields, never English prose.
            if case .http(400, _) = error,
               let user = try? await client.currentUser(),
               let limit = user.quotaSizeInBytes, limit > 0,
               let usage = user.quotaUsageInBytes, usage >= limit {
                return .quota(String(localized: "The server account's storage quota is full."))
            }
            return .failed(error.localizedDescription, kind: .init(error: error))
        } catch let error as PhotoLibraryError {
            backupLog.error("export failed for \(asset.localIdentifier): \((error as NSError).code)")
            return .failed(error.localizedDescription, kind: .init(error: error))
        } catch {
            // a cancelled transfer comes back as a url error, not a cancellationerror.
            if Task.isCancelled { return .skipped }
            backupLog.error("upload failed for \(asset.localIdentifier): \((error as NSError).code)")
            return .failed(error.localizedDescription, kind: .init(error: error))
        }
    }

    /// one component of an asset: in chunks when the server takes them, else
    /// as a multipart body exported straight from photokit.
    private static func send(
        _ upload: AssetUploadRequest,
        motion: Bool,
        client: ImoraClient,
        chunking: ChunkedAssetUpload.Policy?,
        account: String,
        source: BackupEntry,
        maximumRequestBytes: Int64?,
        lease: ProcessLease,
        lifetime: BackgroundUploader.RunLifetime?,
        progressReporter: BackupTransferProgressReporter?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AssetUploadResult {
        let transfer = progressReporter?.component()
        let resourceProgress: @Sendable (BackupResourceProgress) -> Void = { transfer?.resourceProgress($0) }
        let byteProgress: @Sendable (UploadByteProgress) -> Void = { transfer?.uploadByteProgress($0) }
        let uploadProgress: @Sendable (Double) -> Void = { fraction in
            transfer?.uploadProgress(fraction)
            onProgress(fraction)
        }
        if let chunking {
            do {
                return try await ChunkedAssetUpload.send(
                    upload, motion: motion, policy: chunking, client: client, account: account,
                    source: source, lease: lease, lifetime: lifetime, onResourceProgress: resourceProgress,
                    onByteProgress: byteProgress, onProgress: uploadProgress
                )
            } catch is ChunkedAssetUpload.Unavailable {
                backupLog.info("sending \(upload.deviceAssetId) in one request, its size is not known")
            }
        }
        // the body outlives this process when the app is suspended
        // mid-transfer, so it cannot live where the system may reclaim it.
        let body = motion
            ? try await PhotoLibraryService.exportMotion(
                localIdentifier: upload.deviceAssetId, to: BackgroundUploader.bodyDirectory, form: upload.form,
                onResourceProgress: resourceProgress
            )
            : try await PhotoLibraryService.exportPrimary(
                localIdentifier: upload.deviceAssetId, to: BackgroundUploader.bodyDirectory, form: upload.form,
                onResourceProgress: resourceProgress
            )
        transfer?.uploading()
        return try await client.uploadAsset(
            upload, bodyURL: body.fileURL, account: account, source: source,
            maximumRequestBytes: maximumRequestBytes, lease: lease, lifetime: lifetime,
            onByteProgress: byteProgress, onProgress: uploadProgress
        )
    }

    /// a photo edited in place on the device uploads as a new asset. stacking
    /// it over the previous upload keeps the server from showing the picture
    /// twice, as the official app does since 3.3. stacks exist on every 3.x
    /// server, and a failed request is retried on the next run.
    private func stackEditedRevisions() async {
        for stack in await index.pendingStacks() {
            guard !Task.isCancelled else { return }
            do {
                try await client.createStack(assetIDs: [stack.primaryRemoteId, stack.previousRemoteId])
            } catch ImoraError.http(let status, _) where status == 400 || status == 404 {
                // the previous revision was deleted or is no longer ours.
                backupLog.info("skipping stack for \(stack.localId): \(status)")
            } catch {
                continue
            }
            await index.settleStack(stack)
        }
    }

    // MARK: - viewer support

    /// Backs up exactly one device asset. This is intentionally independent of
    /// automatic-backup preferences: tapping Back Up is an explicit user action.
    /// The existing per-item pipeline retains checksum deduplication, Live Photo
    /// ordering, background transfer support, and progress reporting.
    func backUp(localIdentifier: String) async throws -> String {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImoraError.http(0, String(localized: "full photo library access is required for backup."))
        }
        let user = try await client.currentUser()
        userId = user.id
        await refreshUploadProtocol()
        guard await index.load(serverHost: client.serverKey, userId: user.id, generation: client.context.id) else {
            throw SingleAssetBackupError.failed(String(localized: "Backup state is unavailable. Unlock the device and try again."))
        }
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()

        if case .uploading = uploadStates[localIdentifier] {
            try await waitForUpload(localIdentifier: localIdentifier)
        }
        if let entry = await index.entry(for: localIdentifier),
           entry.isBackedUp,
           let remoteID = entry.primaryRemoteId {
            await refreshLocalSnapshots()
            return remoteID
        }
        guard let asset = await PhotoLibraryService.assetInfo(localIdentifier: localIdentifier) else {
            throw SingleAssetBackupError.missing
        }

        let transfer = beginActiveTransfer(localIdentifier: localIdentifier)
        defer { activeTransfers.finish(localIdentifier: localIdentifier, attempt: transfer.attempt) }
        uploadStates[localIdentifier] = .uploading(0)
        let progress: @Sendable (String, Double) -> Void = { [weak self] id, fraction in
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(id, fraction) }
        }
        let outcome = await Self.uploadOne(
            asset: asset,
            client: client,
            index: index,
            deviceId: DeviceID.current,
            account: accountKey,
            maximumRequestBytes: maximumRequestBytes,
            chunking: chunking,
            progressReporter: transfer.reporter,
            onProgress: progress
        )

        switch outcome {
        case .uploaded, .duplicate:
            uploadStates[localIdentifier] = nil
        case .sizeExcluded(let actualBytes, let maximumBytes):
            uploadStates[localIdentifier] = nil
            localChanged()
            throw SingleAssetBackupError.failed(UploadSizeLimit.exceeded(
                actualBytes: actualBytes, maximumBytes: maximumBytes).localizedDescription)
        case .failed(let reason, let kind):
            markUploadFailed(asset, reason: reason, kind: kind)
            throw SingleAssetBackupError.failed(reason)
        case .skipped:
            uploadStates[localIdentifier] = nil
            throw SingleAssetBackupError.missing
        case .quota(let message):
            uploadStates[localIdentifier] = nil
            throw ImoraError.http(400, message)
        }

        await stackEditedRevisions()
        await index.flush()
        await refreshLocalSnapshots()
        guard let remoteID = await index.entry(for: localIdentifier)?.primaryRemoteId else {
            throw SingleAssetBackupError.failed(String(localized: "the server did not return a backup identifier."))
        }
        return remoteID
    }

    /// backs up several device assets picked in the grid. setup runs once and
    /// uploads share the worker pool of a full run, so every tile keeps its
    /// own progress overlay. like the single-asset path, this ignores the
    /// automatic-backup preference: the selection is an explicit ask.
    func backUp(localIdentifiers: [String]) async throws -> BulkBackupOutcome {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImoraError.http(0, String(localized: "full photo library access is required for backup."))
        }
        let user = try await client.currentUser()
        userId = user.id
        await refreshUploadProtocol()
        guard await index.load(serverHost: client.serverKey, userId: user.id, generation: client.context.id) else {
            throw SingleAssetBackupError.failed(String(localized: "Backup state is unavailable. Unlock the device and try again."))
        }
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()

        var outcome = BulkBackupOutcome()
        var queue: [DeviceAsset] = []
        for localId in localIdentifiers {
            // an upload already in flight from another trigger covers this one.
            if case .uploading = uploadStates[localId] {
                outcome.skipped += 1
                continue
            }
            if let entry = await index.entry(for: localId), entry.isBackedUp {
                outcome.alreadyBackedUp += 1
                continue
            }
            guard let asset = await PhotoLibraryService.assetInfo(localIdentifier: localId) else {
                outcome.skipped += 1
                continue
            }
            queue.append(asset)
        }
        guard !queue.isEmpty else {
            await refreshLocalSnapshots()
            return outcome
        }

        let client = client
        let index = index
        let deviceId = DeviceID.current
        let account = accountKey
        var quotaMessage: String?
        var attempts: [String: UUID] = [:]
        defer {
            for (localId, attempt) in attempts { activeTransfers.finish(localIdentifier: localId, attempt: attempt) }
        }
        let progress: @Sendable (String, Double) -> Void = { [weak self] localId, fraction in
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(localId, fraction) }
        }

        await withTaskGroup(of: (DeviceAsset, UploadOutcome).self) { group in
            var next = 0
            @MainActor func addNext() {
                guard next < queue.count, quotaMessage == nil, !Task.isCancelled else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                let transfer = beginActiveTransfer(localIdentifier: asset.localIdentifier)
                attempts[asset.localIdentifier] = transfer.attempt
                let requestLimit = maximumRequestBytes
                let chunking = chunking
                group.addTask {
                    let result = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, account: account,
                        maximumRequestBytes: requestLimit,
                        chunking: chunking,
                        progressReporter: transfer.reporter,
                        onProgress: progress
                    )
                    return (asset, result)
                }
            }
            for _ in 0..<Self.uploadWorkers { addNext() }
            while let (asset, result) = await group.next() {
                let localId = asset.localIdentifier
                if let attempt = attempts.removeValue(forKey: localId) {
                    activeTransfers.finish(localIdentifier: localId, attempt: attempt)
                }
                switch result {
                case .uploaded:
                    outcome.uploaded += 1
                    uploadStates[localId] = nil
                case .duplicate:
                    outcome.alreadyBackedUp += 1
                    uploadStates[localId] = nil
                case .sizeExcluded:
                    outcome.skipped += 1
                    uploadStates[localId] = nil
                case .failed(let reason, let kind):
                    outcome.failed += 1
                    if outcome.firstFailure == nil { outcome.firstFailure = reason }
                    markUploadFailed(asset, reason: reason, kind: kind)
                case .skipped:
                    outcome.skipped += 1
                    uploadStates[localId] = nil
                case .quota(let message):
                    // nothing else can succeed once the account is full.
                    quotaMessage = message
                    uploadStates[localId] = nil
                    group.cancelAll()
                }
                localChanged()
                addNext()
            }
        }
        await stackEditedRevisions()
        await index.flush()
        await refreshLocalSnapshots()
        if let quotaMessage {
            throw ImoraError.http(400, quotaMessage)
        }
        return outcome
    }

    private func waitForUpload(localIdentifier: String) async throws {
        while case .uploading = uploadStates[localIdentifier] {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func remoteIdentifier(forLocal localIdentifier: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else { return nil }
        guard await PhotoLibraryService.assetExists(localIdentifier: localIdentifier) else { return nil }
        return await index.entry(for: localIdentifier)?.primaryRemoteId
    }

    /// resolves a remote asset to a device asset when the index proves the
    /// pairing and the phasset still exists. never prompts for access.
    func localIdentifier(forRemote remoteId: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        guard await index.load(serverHost: client.serverKey, userId: userId, generation: client.context.id) else { return nil }
        guard let localId = await index.localId(forRemote: remoteId) else { return nil }
        return await PhotoLibraryService.assetExists(localIdentifier: localId) ? localId : nil
    }

    func noteLocalDeletion(_ localIds: [String]) {
        Task {
            await index.remove(ids: localIds)
            await index.flush()
            localChanged()
        }
    }

    // MARK: - download

    /// downloads a server asset into the photo library, verifying the bytes
    /// against the server checksum, and records the pairing in the index.
    /// returns the new local identifier.
    func download(asset: Asset) async throws -> String {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImoraError.http(0, String(localized: "full photo library access is required to download."))
        }
        let user = try await client.currentUser()
        userId = user.id
        guard await index.load(serverHost: client.serverKey, userId: user.id, generation: client.context.id) else {
            throw SingleAssetBackupError.failed(String(localized: "Backup state is unavailable. Unlock the device and try again."))
        }

        let detail = try await client.assetDetail(id: asset.id)
        let scratch = Self.scratchDirectory
        let primaryExtension = URL(fileURLWithPath: detail.originalFileName).pathExtension
        let primaryURL = try await client.downloadOriginal(assetID: asset.id, to: scratch, fileExtension: primaryExtension)
        var motionURL: URL?
        do {
            let primaryChecksum = try await PhotoLibraryService.sha1Base64(ofFile: primaryURL)
            if let expected = detail.checksum, expected != primaryChecksum {
                throw ImoraError.decoding(String(localized: "downloaded bytes do not match the server checksum"))
            }
            var motionChecksum: String?
            if let motionId = detail.livePhotoVideoId {
                let url = try await client.downloadOriginal(assetID: motionId, to: scratch, fileExtension: "mov")
                motionURL = url
                motionChecksum = try await PhotoLibraryService.sha1Base64(ofFile: url)
            }

            let localId = try await PhotoLibraryService.importAsset(
                primaryURL: primaryURL,
                isVideo: detail.type == .video,
                filename: detail.originalFileName,
                motionURL: motionURL
            )
            let info = await PhotoLibraryService.assetInfo(localIdentifier: localId)
            await index.setHashed(
                localId: localId,
                isLivePhoto: motionURL != nil,
                primaryChecksum: primaryChecksum,
                motionChecksum: motionChecksum,
                modificationDate: info?.modificationDate
            )
            await index.setPrimaryRemoteId(localId: localId, asset.id)
            if let motionId = detail.livePhotoVideoId {
                await index.setMotionRemoteId(localId: localId, motionId)
            }
            if detail.isEdited == true {
                _ = await index.markRemoteEdited([asset.id])
            }
            await index.flush()
            localChanged()
            return localId
        } catch {
            // on success the files were moved into the library; on any failure
            // whatever remains in scratch is ours to clean.
            try? FileManager.default.removeItem(at: primaryURL)
            if let motionURL { try? FileManager.default.removeItem(at: motionURL) }
            throw error
        }
    }

    // MARK: - cleanup

    func cleanUpCandidates(selectedLocalIDs: Set<String>? = nil) async throws -> CleanupReport {
        activeCleanupReportID = nil
        if let selectedLocalIDs, selectedLocalIDs.isEmpty { throw CleanupVerificationError.invalidReport }
        guard PhotoLibraryService.hasFullAccess else { throw CleanupVerificationError.permission }
        let user = try await client.currentUser()
        guard !isShutDown, client.context.isActive else { throw CleanupVerificationError.changed }
        userId = user.id
        guard await index.load(serverHost: client.serverKey, userId: user.id, generation: client.context.id) else { throw CleanupVerificationError.changed }
        let scanned: [DeviceAsset]
        if let selectedLocalIDs {
            // A scoped request never scans or uploads unrelated library items.
            scanned = try await PhotosCleanupLibrary().assets(ids: selectedLocalIDs.sorted())
            guard scanned.count == selectedLocalIDs.count,
                  Set(scanned.map(\.localIdentifier)) == selectedLocalIDs else { throw CleanupVerificationError.changed }
        } else {
            scanned = await PhotoLibraryService.scan()
        }
        try Task.checkCancellation()
        guard !isShutDown, client.context.isActive else { throw CleanupVerificationError.changed }
        let entries = await index.allEntries()
        let candidates = scanned.filter { asset in
            guard let entry = entries[asset.localIdentifier], !entry.unsupported,
                  entry.matches(modificationDate: asset.modificationDate), entry.isLivePhoto == asset.isLivePhoto,
                  entry.primaryRemoteId != nil, !asset.isLivePhoto || entry.motionRemoteId != nil else { return false }
            return true
        }
        if let selectedLocalIDs, Set(candidates.map(\.localIdentifier)) != selectedLocalIDs {
            throw CleanupVerificationError.invalidReport
        }
        _ = try await checkPhase(candidates, updatesPhase: false)
        let current = await index.allEntries()
        var evidence: [CleanupCandidate] = []
        for asset in candidates {
            guard let entry = current[asset.localIdentifier], entry.isBackedUp,
                  let proof = entry.proof, proof.localRevision == asset,
                  proof.account == accountKey, proof.generation == client.context.id else { continue }
            evidence.append(CleanupCandidate(source: entry, proof: proof))
        }
        try Task.checkCancellation()
        guard !isShutDown, client.context.isActive else { throw CleanupVerificationError.changed }
        let eligible = Set(evidence.map { $0.asset.localIdentifier })
        if let selectedLocalIDs {
            // Never silently delete a smaller subset of the confirmed selection.
            guard eligible == selectedLocalIDs else { throw CleanupVerificationError.invalidReport }
            let latest = try await PhotosCleanupLibrary().assets(ids: selectedLocalIDs.sorted())
            guard latest.count == scanned.count,
                  Dictionary(uniqueKeysWithValues: latest.map { ($0.localIdentifier, $0) }) ==
                    Dictionary(uniqueKeysWithValues: scanned.map { ($0.localIdentifier, $0) }) else { throw CleanupVerificationError.changed }
        }
        let report = CleanupReport(account: accountKey, generation: client.context.id, candidates: evidence,
                                   keptMedia: MediaCounts(assets: scanned.filter { !eligible.contains($0.localIdentifier) }),
                                   route: ServerRoute.resolve(client.apiURL))
        activeCleanupReportID = report.id
        await refreshLocalSnapshots()
        try Task.checkCancellation()
        guard !isShutDown, client.context.isActive else { throw CleanupVerificationError.changed }
        return report
    }

    func performCleanup(report: CleanupReport) async throws -> CleanupOutcome {
        guard activeCleanupReportID == report.id, report.account == accountKey,
              report.generation == client.context.id, !isShutDown else { throw CleanupVerificationError.changed }
        activeCleanupReportID = nil // confirmation is single-use, including cancellation
        let client = client, index = index
        let evidenceVersion = index.evidenceVersion
        let result = try await CleanupVerifier.perform(report: report, account: accountKey, generation: client.context.id,
            library: PhotosCleanupLibrary(), remote: client, isCurrent: {
                client.context.isActive && ServerRoute.resolve(client.apiURL) == report.route && index.evidenceVersion == evidenceVersion
            }, canCommit: {
                client.context.isActive && ServerRoute.resolve(client.apiURL) == report.route && index.evidenceVersion == evidenceVersion
            }, evidenceCurrent: { candidate in
                guard client.context.isActive, let entry = await index.entry(for: candidate.asset.localIdentifier) else { return false }
                return entry.hasSameResources(as: candidate.source) && entry.verificationRevision == candidate.source.verificationRevision
            })
        await index.remove(ids: result.deletedIDs)
        _ = await index.flush()
        if !isShutDown { localChanged() }
        return result
    }

}

// MARK: - continued processing

extension BackupManager: ContinuedWorkload {
    var continuedOwnerID: UUID { client.context.id }

    var continuedTitle: String {
        switch phase {
        // a run with nothing to send is not an achievement to announce.
        case .scanning, .hashing, .checking: String(localized: "Indexing library")
        case .done where libraryStatus?.isUpToDate == true && summary.uploaded == 0 && summary.failed == 0:
            String(localized: "Up to date")
        case .done where (libraryStatus?.pending ?? 0) > 0 || (libraryStatus?.unsupported ?? 0) > 0 || summary.failed > 0:
            String(localized: "Backup incomplete")
        case .done: String(localized: "Backup complete")
        case .error: String(localized: "Backup stopped")
        case .cancelled: String(localized: "Backup cancelled")
        default: String(localized: "Backing up")
        }
    }

    var continuedSubtitle: String {
        switch phase {
        case .idle, .scanning: String(localized: "Scanning library...")
        case .hashing: String(localized: "Indexing \(phaseMediaCompleted.progressText(of: phaseMediaTotal))")
        case .checking: String(localized: "Checking with your server...")
        case .uploading: String(localized: "Uploading \(phaseMediaCompleted.progressText(of: phaseMediaTotal))")
        case .done(let summary):
            libraryStatus?.completionText(summary) ?? String(localized: "Backup check complete")
        case .error(let message): message
        case .cancelled where summary.uploaded > 0: String(localized: "\(summary.uploadedMedia.text) uploaded before stopping")
        case .cancelled: String(localized: "Nothing was sent")
        }
    }

    var continuedProgress: ContinuedProgress? {
        // a cancelled run leaves the system bar where it stopped instead of
        // snapping it empty or full on the way out.
        if case .cancelled = phase { return nil }
        return ContinuedProgress(fraction: progressFraction)
    }

    var continuedFailed: Bool {
        if case .error = phase { return true }
        return false
    }
}

/// forwards photokit change notifications; registration is managed by backupmanager.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

private extension Array {
    nonisolated func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
