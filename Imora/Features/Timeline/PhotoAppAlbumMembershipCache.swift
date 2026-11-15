import Foundation
import Observation

/// Cached metadata only. Verification evidence is supplied by BackupManager.
/// Each account has its own keys, and realtime album/resync events invalidate it.
@MainActor @Observable
final class PhotoAppAlbumMembershipCache {
    static let shared = PhotoAppAlbumMembershipCache()
    private(set) var generation = 0
    @ObservationIgnored private var values: [String: [String: Bool]] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]

    func invalidate(account: String?) {
        guard let account else { return }
        values[account] = nil
        revisions[account, default: 0] += 1
        generation += 1
    }

    func unfiledIDs(account: String?, remoteIDs: Set<String>,
                    lookup: @escaping @Sendable (String) async throws -> Bool) async throws -> Set<String> {
        let revision = account.map { key in
            let value = revisions[key, default: 0]
            revisions[key] = value
            return value
        }
        let cached = account.flatMap { values[$0] } ?? [:]
        let missing = remoteIDs.filter { cached[$0] == nil }
        let fetched = try await PhotoFilterMetadata.albumMembership(remoteIDs: missing, lookup: lookup)
        try Task.checkCancellation()
        if let account {
            guard revisions[account, default: 0] == revision else { throw CancellationError() }
            values[account, default: [:]].merge(fetched) { _, new in new }
        }
        let resolved = cached.merging(fetched) { _, new in new }
        return Set(remoteIDs.filter { resolved[$0] == false })
    }

    private func invalidateAll() {
        for account in Set(values.keys).union(revisions.keys) { invalidate(account: account) }
    }
}

extension PhotoAppAlbumMembershipCache: RealtimeListener {
    func realtimeAlbumsChanged() { invalidateAll() }
    func realtimeResync() { invalidateAll() }
}
