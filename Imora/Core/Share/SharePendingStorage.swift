import Foundation

/// Only validated queue descriptors can be discarded. Untracked bodies may
/// belong to a legacy session or an extension that is still staging a share.
nonisolated enum SharePendingStorage {
    struct Snapshot: Sendable {
        let records: [ShareQueueRecord]
        let knownBytes: Int64
        let totalBytes: Int64
        var untrackedBytes: Int64 { max(0, totalBytes - knownBytes) }
    }

    static func snapshot(store: ShareQueueStore) throws -> Snapshot {
        let records = try store.pending(includeAttention: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var total: Int64 = 0
        if FileManager.default.fileExists(atPath: store.bodyDirectory.path) {
            guard let files = FileManager.default.enumerator(at: store.bodyDirectory,
                includingPropertiesForKeys: Array(keys)) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: keys)
                if values.isRegularFile == true && values.isSymbolicLink != true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        let known = records.reduce(Int64(0)) { total, record in
            // Measure the current file, rather than promising to reclaim the
            // descriptor's original size after an interrupted or partial write.
            guard let file = ProtectedTemporaryFiles.ownedFile(record.bodyPath, in: store.bodyDirectory),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return total }
            return total + Int64(size)
        }
        return Snapshot(records: records, knownBytes: known, totalBytes: total)
    }

    /// The caller cancels its coordinator before discarding the exact records
    /// the user reviewed. Store cancellation serializes with request starts and
    /// leaves tombstones so another process cannot revive these transfers.
    static func discard(_ records: [ShareQueueRecord], store: ShareQueueStore) -> Int {
        var failures = 0
        for record in records {
            do { try store.cancel(record) }
            catch { failures += 1 }
        }
        return failures
    }
}
