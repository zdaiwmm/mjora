import Foundation
import os

/// Runs guarded transfers while iOS gives this process execution time.
/// Protected journals retain candidates/recovery state across termination;
/// server reconciliation determines completion and retries on the next run.
/// Daemon-owned background sessions cannot veto redirects and are retired.
nonisolated final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()

    /// Identifies a transfer and its durable reconciliation journal.
    struct Ticket: Codable, Sendable {
        /// Canonical API root plus user ID.
        let account: String
        let localId: String
        let isMotion: Bool
        let bodyPath: String
        var version: Int? = 1
        var id: UUID? = UUID()
        var source: BackupEntry? = nil
        /// one chunk of imora's resumable upload. only the last answers with
        /// the asset.
        var isChunk: Bool? = nil
        var contextID: UUID? = nil
    }

    struct Completion: Codable, Sendable {
        let ticket: Ticket
        let remoteId: String
    }

    /// one library run owns this policy. expiring its processing budget stops
    /// new transfers, but cancellation only detaches callers from existing ones.
    /// viewer uploads and later runs use independent cancellation policies.
    final class RunLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        var hasExpired: Bool { lock.withLock { expired } }

        func expire() { lock.withLock { expired = true } }
    }

    /// uikit hands the relaunch completion over as a plain closure. it only
    /// ever runs on the main thread, which is the guarantee this box stands on.
    struct LaunchCompletion: @unchecked Sendable {
        let run: () -> Void
    }

    private static let sessionID = "app.imora.backup.uploads"
    /// application support rather than tmp or caches: the body has to outlive
    /// the app process, and neither of those is promised to.
    static let bodyDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/uploads")

    private var session: URLSession!
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]
    private var orphanHandler: (@Sendable ([Completion]) async -> [Completion])?
    private var replayScheduled = false
    private let journal = UploadJournal()

    private override init() {
        super.init()
        Self.prepareBodyDirectory()
        let config = URLSessionConfiguration.default
        // the user asked for this backup, so it should not wait for a charger.
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Retire legacy daemon-owned transfers before beginning guarded work.
    func attach() { LegacyTransferCanceller.shared.cancel(identifier: Self.sessionID) }

    /// request bodies are large and regenerable, so they have no business in
    /// the user's icloud backup even though application support is.
    private static func prepareBodyDirectory() {
        try? ProtectedTemporaryFiles.prepareDirectory(bodyDirectory)
    }

    // MARK: - handlers

    /// the handler gets every pending receipt at once and returns the ones it
    /// made durable, so a batch costs one index write rather than one each.
    func setOrphanHandler(_ handler: (@Sendable ([Completion]) async -> [Completion])?) {
        lock.withLock { orphanHandler = handler }
        Task { await replayReceipts() }
    }

    /// deletion is an acknowledgement: the consumer has committed the index,
    /// or verified that this receipt belongs to an obsolete asset revision.
    @concurrent
    func replayReceipts() async {
        guard let handler = lock.withLock({ orphanHandler }) else { return }
        let receipts = journal.receipts()
        guard !receipts.isEmpty else { return }
        for completion in await handler(receipts) { journal.acknowledge(completion.ticket) }
    }

    /// completions arrive one per transfer. a receipt stays journaled until it
    /// is acknowledged, so waiting a little to replay a batch loses nothing.
    private func scheduleReplay() {
        let first = lock.withLock {
            defer { replayScheduled = true }
            return !replayScheduled
        }
        guard first else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            lock.withLock { replayScheduled = false }
            await replayReceipts()
        }
    }

    /// Wait for an active process-owned transfer before preparing another copy. This wait is
    /// cancellable; cancelling a waiter does not cancel somebody else's task.
    @concurrent
    func waitForExisting(account: String, localId: String) async throws {
        var waited = false
        while true {
            try Task.checkCancellation()
            let tasks = await session.allTasks
            let exists = tasks.contains {
                guard let ticket = Self.decode($0.taskDescription) else { return false }
                return ticket.account == account && ticket.localId == localId
            }
            if !exists { break }
            waited = true
            try await Task.sleep(for: .milliseconds(250))
        }
        // only a transfer that was still going can have left a receipt the
        // caller needs applied before it looks at the index.
        if waited { await replayReceipts() }
        try Task.checkCancellation()
    }

    /// stored by the app delegate when the system relaunches us to deliver
    /// finished transfers; calling it is what lets the app suspend again.
    func setBackgroundCompletionHandler(_ handler: LaunchCompletion) {
        LegacyTransferCanceller.shared.cancel(identifier: Self.sessionID,
            completion: .init(run: handler.run))
    }

    // MARK: - uploading

    /// Retain the process execution lease through transfer completion.
    func upload(
        _ request: URLRequest,
        fromFile bodyURL: URL,
        ticket: Ticket,
        context: AccountRequestContext,
        lease: ProcessLease? = nil,
        lifetime: RunLifetime? = nil,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        defer { lease?.release() }
        let request = try context.authorize(request, localAPIURL: ServerRoute.configuredLocal(for: context.apiURL))
        var ticket = ticket
        ticket.contextID = context.id
        try ProtectedTemporaryFiles.protect(bodyURL)
        // Persist a source candidate, not a completion proof, before sending.
        try journal.prepare(ticket)
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = Self.encode(ticket)
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // registered before the task runs, or a fast failure would find
                // nothing to resume and be replayed as an orphan instead.
                let started = lock.withLock {
                    guard !Task.isCancelled, lifetime?.hasExpired != true else { return false }
                    continuations[id] = continuation
                    progressHandlers[id] = onProgress
                    do { try context.startWhileActive { task.resume() } }
                    catch {
                        continuations[id] = nil
                        progressHandlers[id] = nil
                        return false
                    }
                    return true
                }
                if !started {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: { [weak self] in
            // release the Swift worker promptly even if iOS continues sending
            // the file. completion still reaches the durable receipt journal.
            let continuation = self?.lock.withLock {
                self?.progressHandlers[id] = nil
                return self?.continuations.removeValue(forKey: id)
            }
            if lifetime?.hasExpired != true { task.cancel() }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func cancelAll(contextID: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let ticket = Self.decode(task.taskDescription), ticket.contextID == contextID else { continue }
                task.cancel()
            }
        }
    }

    /// removes body files no live task still refers to. a killed run leaves
    /// them behind and nothing else ever will. anything recent is spared: a
    /// body is on disk for a moment before its task exists.
    func sweepAbandonedBodies() {
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { Self.decode($0.taskDescription)?.bodyPath })
            let manager = FileManager.default
            let contents = (try? manager.contentsOfDirectory(
                at: Self.bodyDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let cutoff = Date().addingTimeInterval(-3600)
            for url in contents where !live.contains(url.path) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: - delegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @Sendable @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }


    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { buffers[dataTask.taskIdentifier, default: Data()].append(data) }
        if let ticket = Self.decode(dataTask.taskDescription) {
            do { try journal.appendResponse(data, ticket: ticket) }
            catch { backupLog.error("upload response could not be saved: \((error as NSError).code)") }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let ticket = Self.decode(task.taskDescription)
        let (continuation, data) = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Data) in
            let continuation = continuations.removeValue(forKey: id)
            let buffered = buffers.removeValue(forKey: id) ?? Data()
            let persisted = ticket.flatMap { journal.response(for: $0) }
            let data = (persisted?.count ?? 0) >= buffered.count ? (persisted ?? buffered) : buffered
            progressHandlers[id] = nil
            return (continuation, data)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var deliveryError = error
        if let ticket {
            do {
                if error == nil, (200..<300).contains(status),
                   let result = try? JSONDecoder().decode(AssetUploadResult.self, from: data) {
                    // the delegate queue writes this before acknowledging events
                    // to UIKit, even if the account/index is not ready yet.
                    try journal.complete(Completion(ticket: ticket, remoteId: result.id))
                } else if error == nil, (200..<300).contains(status), ticket.isChunk == true {
                    // the server kept the chunk. a resumed upload asks it for
                    // the offset, so there is nothing to replay.
                    journal.settle(ticket)
                } else {
                    try journal.recordFailure(ticket, status: status, error: error)
                }
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: ticket.bodyPath))
            } catch {
                // keep the prepared ticket and body for checksum reconciliation.
                // never pretend a failed durable commit succeeded locally.
                deliveryError = error
                backupLog.error("upload receipt could not be saved: \((error as NSError).code)")
            }
        }
        if let continuation {
            if let deliveryError {
                continuation.resume(throwing: deliveryError)
            } else if (200..<300).contains(status) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: ImoraError.http(status, Self.message(from: data)))
            }
        }
        scheduleReplay()
    }

    // MARK: - helpers

    private static func encode(_ ticket: Ticket) -> String? {
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ description: String?) -> Ticket? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(Ticket.self, from: Data(description.utf8))
    }

    private static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let messages = object["message"] as? [String] { return messages.joined(separator: "\n") }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
