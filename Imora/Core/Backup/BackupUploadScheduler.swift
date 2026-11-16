import Foundation

/// A catch-up failure pauses scheduling; it is not a completed/skipped asset.
nonisolated struct BackupUploadAuthorityPause: Error, LocalizedError {
    let underlying: any Error
    var errorDescription: String? { String(localized: "Cloud verification is paused. Reconnect and try again.") }
}

/// The same bounded scheduler serves automatic and explicitly selected uploads.
/// Pausing preserves unstarted items and lets healthy in-flight operations settle.
nonisolated enum BackupUploadScheduler {
    enum Disposition: Sendable { case proceed, pause, cancel }

    @MainActor
    static func run<Item: Sendable, Outcome: Sendable>(
        _ items: [Item], workers: Int,
        workerLimit: @MainActor () -> Int = { Int.max },
        canSchedule: @MainActor () -> Bool = { true },
        operation: @MainActor (Item) -> @Sendable () async -> Outcome,
        didFinish: @MainActor (Item, Outcome) -> Disposition
    ) async {
        await withTaskGroup(of: (Item, Outcome).self) { group in
            var next = 0
            var stopped = false
            var active = 0
            @MainActor func addNext() {
                guard !stopped, !Task.isCancelled, canSchedule(), next < items.count,
                      active < min(max(1, workers), max(0, workerLimit())) else { return }
                let item = items[next]
                next += 1
                active += 1
                let execute = operation(item)
                group.addTask { (item, await execute()) }
            }
            for _ in 0..<max(1, workers) { addNext() }
            while let (item, outcome) = await group.next() {
                active -= 1
                switch didFinish(item, outcome) {
                case .proceed: break
                case .pause: stopped = true
                case .cancel: stopped = true; group.cancelAll()
                }
                for _ in 0..<max(1, workers) { addNext() }
            }
        }
    }
}
