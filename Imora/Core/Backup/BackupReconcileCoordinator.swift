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
    private var isRunning = false
    private var isShutDown = false

    init(reconcile: @escaping @MainActor (BackupReconcileRequest) async -> Void) {
        self.reconcile = reconcile
    }

    func request(_ reason: ReconcileReason, localIDs: Set<String> = [], remoteIDs: Set<String> = []) {
        guard !isShutDown else { return }
        // A routine wake already covered by the running catch-up is redundant.
        // Real changes and explicit full checks always survive that boundary.
        if isRunning, localIDs.isEmpty, remoteIDs.isEmpty,
           reason == .foreground || reason == .reconnect || reason == .recovery { return }
        pending.reasons.insert(reason)
        pending.localIDs.formUnion(localIDs)
        pending.remoteIDs.formUnion(remoteIDs)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            while !self.isShutDown, !Task.isCancelled, !self.pending.reasons.isEmpty {
                let request = self.pending
                self.pending = BackupReconcileRequest()
                self.isRunning = true
                await self.reconcile(request)
                self.isRunning = false
            }
            self.worker = nil
        }
    }

    func waitUntilIdle() async { while let worker { await worker.value } }
    func shutdown() {
        isShutDown = true
        pending = BackupReconcileRequest()
        worker?.cancel()
    }
}
