import Foundation
import Synchronization

/// The share sheet waits for guarded transfers. If iOS terminates it, protected
/// descriptors can resume in Imora with the same authority after unlock.
nonisolated final class ShareUploadActivity: Sendable {
    static let shared = ShareUploadActivity()
    private let pending = Mutex<[ShareQueueRecord]>([])

    func run(_ records: [ShareQueueRecord], credentials: ShareTransfer.Credentials) async -> ShareQueueResult {
        guard let store = ShareTransfer.queueStore else { return ShareQueueResult(failed: records.count) }
        pending.withLock { $0 = records }
        let result = await ShareQueueRunner.run(records, store: store, credentials: credentials, startAuthorized: { resume in
            try ShareTransfer.withCurrent(credentials) { try resume() }
        })
        pending.withLock { $0 = [] }
        return result
    }

    func cancelPending() {
        let records = pending.withLock { value in let records = value; value = []; return records }
        guard let store = ShareTransfer.queueStore else { return }
        for record in records { try? store.cancel(record) }
    }
}
