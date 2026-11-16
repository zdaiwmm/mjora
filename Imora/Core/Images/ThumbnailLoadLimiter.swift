import Foundation

/// Demand is relative to the current viewport, not the age of a queued job.
nonisolated enum ThumbnailDemandPriority: Int, Sendable {
    case visible = 0
    case adjacent = 1
    case background = 2
}

/// PhotoKit and remote work share bounded admission. A queued producer uses
/// the highest priority of its current consumers, so a visible subscriber can
/// promote work that was originally started as a prefetch.
actor ThumbnailDemandScheduler {
    static let shared = ThumbnailDemandScheduler(limit: 4)
    private struct Waiting {
        let id: UUID
        let key: String?
        let priority: ThumbnailDemandPriority
        let continuation: CheckedContinuation<UUID, any Error>
    }
    private let limit: Int
    private var active: Set<UUID> = []
    private var waiting: [Waiting] = []
    private var demands: [String: [UUID: ThumbnailDemandPriority]] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire(priority: ThumbnailDemandPriority = .visible, key: String? = nil) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if active.count < limit {
                    active.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiting.append(.init(id: id, key: key, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Each consumer owns only its own demand. Nuke continues to coalesce the
    /// underlying request and cancels it when its final subscriber releases.
    func addDemand(key: String, priority: ThumbnailDemandPriority) -> UUID {
        let id = UUID()
        demands[key, default: [:]][id] = priority
        return id
    }

    func releaseDemand(key: String, id: UUID) {
        demands[key]?[id] = nil
        if demands[key]?.isEmpty == true { demands[key] = nil }
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        guard !waiting.isEmpty else { return }
        let index = waiting.indices.min { lhs, rhs in
            effectivePriority(waiting[lhs]).rawValue < effectivePriority(waiting[rhs]).rawValue
        }!
        let next = waiting.remove(at: index)
        active.insert(next.id)
        next.continuation.resume(returning: next.id)
    }

    private func effectivePriority(_ item: Waiting) -> ThumbnailDemandPriority {
        guard let key = item.key, let consumers = demands[key]?.values,
              let highest = consumers.min(by: { $0.rawValue < $1.rawValue }),
              highest.rawValue < item.priority.rawValue else { return item.priority }
        return highest
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // Active permits remain owned by the caller until its request ends.
    }
}

// Existing callers continue to use the same four-slot admission lane.
typealias ThumbnailLoadLimiter = ThumbnailDemandScheduler
