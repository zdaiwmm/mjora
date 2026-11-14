import Foundation

nonisolated enum ReconcileReason: Hashable, Sendable {
    case foreground, localChange, remoteChange, reconnect, manualFullCheck, recovery
}

nonisolated struct BackupReconcileRequest: Sendable {
    var reasons: Set<ReconcileReason> = []
    var localIDs: Set<String> = []
    var remoteIDs: Set<String> = []
    var requiresFullCheck: Bool { reasons.contains(.manualFullCheck) }
}

/// One coordinator belongs to one account manager. A running worker owns its lifetime.
@MainActor
final class BackupReconcileCoordinator {
    private let reconcile: @MainActor (BackupReconcileRequest) async -> Void
    private var pending = BackupReconcileRequest()
    private var worker: Task<Void, Never>?
    private var lastGenerations: [ReconcileReason: UUID] = [:]
    private var isShutDown = false

    init(reconcile: @escaping @MainActor (BackupReconcileRequest) async -> Void) {
        self.reconcile = reconcile
    }

    @discardableResult
    func request(_ reason: ReconcileReason, localIDs: Set<String> = [], remoteIDs: Set<String> = [], generation: UUID? = nil) -> Bool {
        guard !isShutDown else { return false }
        if let generation {
            guard lastGenerations[reason] != generation else { return false }
            lastGenerations[reason] = generation
        }
        // A newer connection may have missed events even while a catch-up is finishing.
        // Keep one pending round; generation-tagged duplicate callbacks coalesce.
        pending.reasons.insert(reason)
        pending.localIDs.formUnion(localIDs)
        pending.remoteIDs.formUnion(remoteIDs)
        guard worker == nil else { return true }
        worker = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            while !self.isShutDown, !Task.isCancelled, !self.pending.reasons.isEmpty {
                let request = self.pending
                self.pending = BackupReconcileRequest()
                await self.reconcile(request)
            }
            self.worker = nil
        }
        return true
    }

    func waitUntilIdle() async { while let worker { await worker.value } }
    func shutdown() {
        isShutDown = true
        pending = BackupReconcileRequest()
        worker?.cancel()
    }
}

/// Routine scheduling may use metadata/history; cleanup always obtains fresh BackupProof.
nonisolated enum BackupRoutineRecheckPolicy {
    static func requiresHash(asset: DeviceAsset, entry: BackupEntry?) -> Bool {
        if entry?.isUploadBlockedByRemoteRemoval == true { return false }
        return entry == nil || asset.modificationDate == nil || entry?.isLivePhoto != asset.isLivePhoto
            || entry?.matches(modificationDate: asset.modificationDate) != true
    }

    static func recheckCandidates(assets: [DeviceAsset], entries: [String: BackupEntry],
                                  skippable: Set<String>, requiresFreshProof: Bool) -> [DeviceAsset] {
        assets.filter {
            (requiresFreshProof || !skippable.contains($0.localIdentifier))
                && (requiresFreshProof || entries[$0.localIdentifier]?.isUploadBlockedByRemoteRemoval != true)
        }
    }

    static func hasUnchangedRevision(asset: DeviceAsset, entry: BackupEntry) -> Bool {
        asset.modificationDate != nil && entry.matches(modificationDate: asset.modificationDate)
            && entry.isLivePhoto == asset.isLivePhoto && !entry.isUploadBlockedByRemoteRemoval
            && entry.verificationState != .verifying && entry.verificationState != .offline
            && entry.verificationState != .failed && entry.verificationState != .pairPending
            && entry.verificationState != .pairConflict && entry.verificationState != .pairPermissionDenied
    }
}
