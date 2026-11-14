import Foundation

/// Waiting for a render permit is not a stalled provider. All provider
/// deadlines are armed only after the request has actually been started.
nonisolated enum ThumbnailProviderStart {
    static func run(
        acquireCapacity: @Sendable () async throws -> Void,
        startProvider: @Sendable () -> Void,
        armDeadline: @Sendable () -> Void
    ) async throws {
        try await acquireCapacity()
        try Task.checkCancellation()
        startProvider()
        armDeadline()
    }
}
