import Foundation

/// The caller loads the account index first. Every operation rejects a stale account generation.
nonisolated struct BackupIndexSyncBridge: RemoteSyncIndexBridge {
    let index: BackupIndex
    let generation: UUID
    func history(scope: SyncScope) async throws -> [SyncHistoricalPairing] {
        try await index.syncHistory(scope: scope, generation: generation)
    }
    func applyAndFlush(_ operations: [RemoteIndexOperation], scope: SyncScope) async throws {
        try await index.applySyncOperations(operations, scope: scope, generation: generation)
    }
}
