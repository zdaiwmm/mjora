import Foundation
import Synchronization

/// Resumes protected descriptors with the same persisted account authority.
/// Old background sessions are cancelled; their unverified bodies are retained.
nonisolated final class ShareUploadCoordinator: Sendable {
    static let shared = ShareUploadCoordinator()
    struct LaunchCompletion: @unchecked Sendable { let run: () -> Void }
    private struct Run { let id: UUID; let task: Task<Void, Never> }
    private let current = Mutex<Run?>(nil)
    private let credentials: @Sendable () -> ShareTransfer.Credentials?
    private let queueStore: @Sendable () -> ShareQueueStore?
    private let startAuthorized: @Sendable (ShareTransfer.Credentials, @Sendable () throws -> Void) throws -> Void
    private let report: @MainActor @Sendable (ShareQueueResult) -> Void

    init(
        credentials: @escaping @Sendable () -> ShareTransfer.Credentials? = { ShareTransfer.credentials() },
        queueStore: @escaping @Sendable () -> ShareQueueStore? = { ShareTransfer.queueStore },
        startAuthorized: @escaping @Sendable (ShareTransfer.Credentials, @Sendable () throws -> Void) throws -> Void = { captured, resume in
            try ShareTransfer.withCurrent(captured) { try resume() }
        },
        report: @escaping @MainActor @Sendable (ShareQueueResult) -> Void = { result in
            LocalNotifications.shared.deliverShareResult(uploaded: result.uploaded, failed: result.failed)
        }
    ) {
        self.credentials = credentials
        self.queueStore = queueStore
        self.startAuthorized = startAuthorized
        self.report = report
    }

    func attach() {
        if let directory = ShareTransfer.sessionDirectory,
           let markers = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for marker in markers where marker.lastPathComponent.hasPrefix(ShareTransfer.sessionPrefix) {
                let identifier = marker.lastPathComponent
                LegacyTransferCanceller.shared.cancel(identifier: identifier, appGroup: ShareTransfer.appGroup,
                    completion: .init(run: { ShareTransfer.unmarkSession(identifier) }))
            }
            if !markers.isEmpty {
                Task { @MainActor in
                    ErrorToastCenter.shared.show(String(localized: "Previous sharing tasks were stopped to protect their destination. Share those items again; their temporary copies were kept."))
                }
            }
        }
        resumePending()
    }

    @discardableResult
    func resumePending() -> Task<Void, Never>? {
        #if DEBUG && targetEnvironment(simulator)
        if Phase4OwnedFixture.automaticPreparationName != nil { return nil }
        #endif
        guard let credentials = credentials(), let store = queueStore(),
              let records = try? store.pending().filter({ $0.identity == credentials.identity }), !records.isEmpty else { return nil }
        return current.withLock { value in
            if let value { return value.task }
            let id = UUID()
            let startAuthorized = startAuthorized
            let task = Task.detached { [weak self] in
                defer { self?.current.withLock { current in if current?.id == id { current = nil } } }
                let result = await ShareQueueRunner.run(records, store: store, credentials: credentials, startAuthorized: { resume in
                    try startAuthorized(credentials, resume)
                })
                guard let self, !Task.isCancelled, self.credentials()?.identity == credentials.identity else { return }
                if result.uploaded > 0 || result.failed > 0 {
                    await MainActor.run {
                        guard !Task.isCancelled, self.credentials()?.identity == credentials.identity else { return }
                        self.report(result)
                    }
                }
            }
            value = Run(id: id, task: task)
            return task
        }
    }

    func cancelAll() { current.withLock { value in value?.task.cancel(); value = nil } }

    func handleEvents(identifier: String, completion: LaunchCompletion) {
        LegacyTransferCanceller.shared.cancel(identifier: identifier, appGroup: ShareTransfer.appGroup,
            completion: .init(run: { ShareTransfer.unmarkSession(identifier); completion.run() }))
    }
}
