import Foundation

/// PhotoKit requests are asynchronous, so a dispatch queue alone does not
/// bound how many renders it starts. A cancelled queued tile never starts.
actor ThumbnailLoadLimiter {
    static let shared = ThumbnailLoadLimiter(limit: 4)
    private let limit: Int
    private var active: Set<UUID> = []
    private var waiting: [(UUID, CheckedContinuation<UUID, any Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if active.count < limit {
                    active.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiting.isEmpty {
            let (next, continuation) = waiting.removeFirst()
            active.insert(next)
            continuation.resume(returning: next)
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).1.resume(throwing: CancellationError())
        }
        // Active permits remain owned by the caller until its request ends.
    }
}
