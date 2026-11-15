import Foundation
import Synchronization

/// One local-only preparation shared by session construction and its exact
/// first gallery. This retains the existing prepared result, not another cache.
@MainActor
final class CachedLaunchHandle {
    let client: ImoraClient
    let source: String
    let filter: String
    private let access: MediaAccessGeneration
    private var task: Task<PreparedViewport?, Never>?
    private nonisolated let resultState = CachedLaunchResult()
    private(set) var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(client: ImoraClient, source: String, filter: String,
         prepare: @escaping @Sendable () async -> PreparedViewport?) {
        self.client = client; self.source = source; self.filter = filter
        access = MediaPresentationCoordinator.access(for: client)
        let resultState = resultState
        let capturedAccess = access
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await prepare()
            guard !Task.isCancelled, client.context.isActive,
                  capturedAccess == MediaPresentationCoordinator.access(for: client),
                  let result, result.access == capturedAccess,
                  result.snapshot.scope == client.mediaDisplayScope,
                  result.snapshot.source == source, result.snapshot.filter == filter,
                  !result.checkpointMiss, result.missingKeys.isEmpty, result.localEvidenceIsCurrent(),
                  result.snapshot.visibleKeys.allSatisfy({ $0.isCurrentContent && result.images[$0] != nil }) else {
                await self?.finish()
                return nil
            }
            let accepted = resultState.value.withLock { state in
                guard state.active else { return false }
                state.ready = result
                return true
            }
            return accepted ? result : nil
        }
    }

    isolated deinit { task?.cancel(); waiters.values.forEach { $0.resume() } }

    func matches(client: ImoraClient, source: String, filter: String) -> Bool {
        !isReleased && self.client === client && self.source == source && self.filter == filter
            && client.context.isActive && access == MediaPresentationCoordinator.access(for: client)
    }

    private func accepts(_ prepared: PreparedViewport, layout: LaunchViewportSnapshot.Layout? = nil) -> Bool {
        prepared.localEvidenceIsCurrent()
            && prepared.localProvenanceByKey.values.allSatisfy { LocalImageLoader.currentModificationRevision($0.localIdentifier) == $0.modificationRevision }
            && prepared.access == access && prepared.snapshot.scope == client.mediaDisplayScope
            && prepared.snapshot.source == source && prepared.snapshot.filter == filter
            && !prepared.checkpointMiss && prepared.missingKeys.isEmpty
            && prepared.snapshot.visibleKeys.allSatisfy { $0.isCurrentContent && prepared.images[$0] != nil }
            && (layout == nil || prepared.snapshot.layout == layout)
    }

    func preparedIfReady(client: ImoraClient, source: String, filter: String,
                         layout: LaunchViewportSnapshot.Layout? = nil) -> PreparedViewport? {
        guard matches(client: client, source: source, filter: filter), let ready = resultState.value.withLock({ $0.ready }), accepts(ready, layout: layout) else { return nil }
        return ready
    }

    func value(client: ImoraClient, source: String, filter: String) async -> PreparedViewport? {
        guard matches(client: client, source: source, filter: filter), let task else { return nil }
        let result = await task.value
        guard !Task.isCancelled, matches(client: client, source: source, filter: filter),
              let result, accepts(result) else { return nil }
        return result
    }

    func finish() {
        guard !isReleased else { return }
        isReleased = true; resultState.value.withLock { $0 = (false, nil) }; task = nil
        let pending = waiters.values; waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func cancel() { task?.cancel(); finish() }

    /// Cancellation only releases this waiter; it cannot hold startup work.
    func waitUntilReleased() async {
        guard !isReleased, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isReleased || Task.isCancelled { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}

/// The same parameters construct both the session's request and the gallery.
/// Unsupported/non-default selections never borrow a different selection's pack.
enum PhotosLaunchSelection {
    static func cloudFilter(mergesSharedSpaces: Bool, favorites: Bool = false, sortByAdded: Bool = false) -> TimelineFilter {
        TimelineFilter(withPartners: true, withSharedSpaces: mergesSharedSpaces, withStacked: true,
            isFavorite: favorites ? true : nil, order: "asc", orderBy: sortByAdded ? "createdAt" : nil)
    }
}

private nonisolated final class CachedLaunchResult: Sendable {
    let value = Mutex<(active: Bool, ready: PreparedViewport?)>((true, nil))
}
