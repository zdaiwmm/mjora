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
        var isSealed: Bool? = nil
        var transportIdentity: LocalServerIdentity? = nil
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
    static let sealedSessionID = "\(Bundle.main.bundleIdentifier ?? "app.imora").backup.sealed.v1"
    /// application support rather than tmp or caches: the body has to outlive
    /// the app process, and neither of those is promised to.
    static let bodyDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/uploads")

    private var session: URLSession!
    private var sealedSession: URLSession!
    private var sealedCompletion: LaunchCompletion?
    private var sealedEventsDelivered = false
    private var sealedEventGeneration = UUID()
    private struct Followup: Hashable { let account: String; let localId: String }
    private var pendingFollowups: Set<Followup> = []
    private var systemTransfers: [UUID: Followup] = [:]
    private var systemHandoffHandler: (@Sendable (String) -> Void)?
    private var pinnedSessions: [String: URLSession] = [:]
    private let lock = NSLock()
    private var continuations: [ObjectIdentifier: CheckedContinuation<Data, any Error>] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var progressHandlers: [ObjectIdentifier: @Sendable (Double) -> Void] = [:]
    private var byteProgressHandlers: [ObjectIdentifier: (id: UUID, callback: @Sendable (UploadByteProgress) -> Void)] = [:]
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
        let background = URLSessionConfiguration.background(withIdentifier: Self.sealedSessionID)
        background.httpCookieStorage = nil
        background.urlCredentialStorage = nil
        background.urlCache = nil
        background.httpMaximumConnectionsPerHost = 1
        background.isDiscretionary = false
        background.sessionSendsLaunchEvents = true
        background.timeoutIntervalForResource = 7 * 24 * 60 * 60
        sealedSession = URLSession(configuration: background, delegate: self, delegateQueue: nil)
    }

    private func session(for request: URLRequest, context: AccountRequestContext) throws -> URLSession {
        guard let url = request.url else { throw ServerTrustError.untrustedTarget }
        guard let identity = try ServerRoute.transportIdentity(to: url, for: context.apiURL) else { return session }
        return lock.withLock {
            if let value = pinnedSessions[identity.sessionKey] { return value }
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 3
            let value = URLSession(configuration: config,
                delegate: PinnedBackupDelegate(owner: self, identity: identity), delegateQueue: nil)
            pinnedSessions[identity.sessionKey] = value
            return value
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        let values = lock.withLock { [session!, sealedSession!] + Array(pinnedSessions.values) }
        var tasks: [URLSessionTask] = []
        for value in values { tasks += await value.allTasks }
        return tasks
    }

    /// Retire legacy daemon-owned transfers before beginning guarded work.
    func attach() { LegacyTransferCanceller.shared.cancel(identifier: Self.sessionID) }

    /// Relaunched daemon tasks belong to the newly authenticated context only
    /// after its stable server/user account has been confirmed.
    func adopt(account: String, context: AccountRequestContext) {
        Task {
            for task in await allTasks() {
                guard var ticket = Self.decode(task.taskDescription), ticket.isSealed == true,
                      ticket.account == account else { continue }
                try? context.startWhileActive {
                    ticket.contextID = context.id
                    task.taskDescription = Self.encode(ticket)
                }
            }
        }
    }

    func setSystemHandoffHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { systemHandoffHandler = handler }
    }

    func hasSystemTransfer(account: String, localIds: Set<String>) -> Bool {
        lock.withLock { systemTransfers.values.contains { $0.account == account && localIds.contains($0.localId) } }
    }

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
            let tasks = await allTasks()
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
    func setBackgroundCompletionHandler(_ handler: LaunchCompletion, identifier: String? = nil) {
        if identifier == Self.sealedSessionID {
            lock.withLock {
                sealedCompletion = handler
                sealedEventsDelivered = false
                sealedEventGeneration = UUID()
            }
            return
        }
        LegacyTransferCanceller.shared.cancel(identifier: Self.sessionID,
            completion: .init(run: handler.run))
    }

    /// Keep the system event window through the authenticated offset check and
    /// next handoff, or through terminal handling when no next part is needed.
    func finishedPreparing(account: String, localId: String) {
        lock.withLock { _ = pendingFollowups.remove(Followup(account: account, localId: localId)) }
        finishSealedEventsIfReady()
    }

    private func finishSealedEventsIfReady(forceGeneration: UUID? = nil) {
        let completion = lock.withLock { () -> LaunchCompletion? in
            guard sealedEventsDelivered,
                  forceGeneration == nil || forceGeneration == sealedEventGeneration,
                  forceGeneration != nil || pendingFollowups.isEmpty else { return nil }
            if forceGeneration != nil { pendingFollowups.removeAll() }
            defer { sealedCompletion = nil; sealedEventsDelivered = false }
            return sealedCompletion
        }
        if let completion { Task { @MainActor in completion.run() } }
    }

    // MARK: - uploading

    /// Retain the process execution lease through transfer completion.
    func upload(
        _ initialRequest: URLRequest,
        fromFile bodyURL: URL,
        ticket: Ticket,
        context: AccountRequestContext,
        lease: ProcessLease? = nil,
        lifetime: RunLifetime? = nil,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        defer { lease?.release() }
        var ticket = ticket
        let request: URLRequest
        if ticket.isSealed == true {
            guard let url = initialRequest.url,
                  context.policy(for: url, localAPIURL: ServerRoute.configuredLocal(for: context.apiURL)) != nil,
                  initialRequest.value(forHTTPHeaderField: "Authorization") == nil else { throw ServerTrustError.untrustedTarget }
            ticket.transportIdentity = try ServerRoute.transportIdentity(to: url, for: context.apiURL)
            request = initialRequest
        } else {
            request = try context.authorize(initialRequest, localAPIURL: ServerRoute.configuredLocal(for: context.apiURL))
        }
        ticket.contextID = context.id
        try ProtectedTemporaryFiles.protect(bodyURL)
        // Persist a source candidate, not a completion proof, before sending.
        try journal.prepare(ticket)
        let target = ticket.isSealed == true ? sealedSession! : try session(for: request, context: context)
        let task = target.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = Self.encode(ticket)
        let id = ObjectIdentifier(task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // registered before the task runs, or a fast failure would find
                // nothing to resume and be replayed as an orphan instead.
                let started = lock.withLock {
                    guard !Task.isCancelled, lifetime?.hasExpired != true else { return false }
                    continuations[id] = continuation
                    progressHandlers[id] = onProgress
                    if let onByteProgress { byteProgressHandlers[id] = (UUID(), onByteProgress) }
                    do { try context.startWhileActive(for: request) { task.resume() } }
                    catch {
                        continuations[id] = nil
                        progressHandlers[id] = nil
                        byteProgressHandlers[id] = nil
                        return false
                    }
                    if ticket.isSealed == true, let transfer = ticket.id {
                        systemTransfers[transfer] = Followup(account: ticket.account, localId: ticket.localId)
                    }
                    return true
                }
                if !started {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                } else if ticket.isSealed == true {
                    lock.withLock { systemHandoffHandler }?(ticket.account)
                    finishedPreparing(account: ticket.account, localId: ticket.localId)
                }
            }
        } onCancel: { [weak self] in
            // release the Swift worker promptly even if iOS continues sending
            // the file. completion still reaches the durable receipt journal.
            let continuation = self?.lock.withLock {
                self?.progressHandlers[id] = nil
                self?.byteProgressHandlers[id] = nil
                return self?.continuations.removeValue(forKey: id)
            }
            if lifetime?.hasExpired != true { task.cancel() }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func cancelAll(contextID: UUID) {
        Task {
            let tasks = await allTasks()
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
        Task {
            let tasks = await allTasks()
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @Sendable @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let identity = Self.decode(task.taskDescription)?.transportIdentity
        LocalServerIdentity.answer(challenge, requestURL: task.currentRequest?.url, identity: identity, completion: completionHandler)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session.configuration.identifier == Self.sealedSessionID else { return }
        receivedSealedEvents()
    }

    func receivedSealedEvents() {
        let generation = lock.withLock { () -> UUID in
            sealedEventsDelivered = true
            return sealedEventGeneration
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            finishSealedEventsIfReady(forceGeneration: generation)
        }
        Task {
            await replayReceipts()
            finishSealedEventsIfReady()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @Sendable @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }


    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Responses may have been redirected and have no authority. Do not
        // buffer or persist an untrusted daemon response body.
        if Self.decode(dataTask.taskDescription)?.isSealed == true { return }
        lock.withLock { buffers[ObjectIdentifier(dataTask), default: Data()].append(data) }
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
        let byteHandler = lock.withLock { byteProgressHandlers[ObjectIdentifier(task)] }
        if let byteHandler {
            byteHandler.callback(UploadByteProgress(transferID: byteHandler.id, bytesSent: bytesSent,
                totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend,
                timestamp: ProcessInfo.processInfo.systemUptime))
        }
        guard totalBytesExpectedToSend > 0 else { return }
        let handler = lock.withLock { progressHandlers[ObjectIdentifier(task)] }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = ObjectIdentifier(task)
        let ticket = Self.decode(task.taskDescription)
        if let transfer = ticket?.id { lock.withLock { _ = systemTransfers.removeValue(forKey: transfer) } }
        let (continuation, data) = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Data) in
            let continuation = continuations.removeValue(forKey: id)
            let buffered = buffers.removeValue(forKey: id) ?? Data()
            let persisted = ticket.flatMap { journal.response(for: $0) }
            let data = (persisted?.count ?? 0) >= buffered.count ? (persisted ?? buffered) : buffered
            progressHandlers[id] = nil
            byteProgressHandlers[id] = nil
            return (continuation, data)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var deliveryError = error
        if let ticket {
            if ticket.isSealed == true {
                lock.withLock { _ = pendingFollowups.insert(Followup(account: ticket.account, localId: ticket.localId)) }
            }
            do {
                if ticket.isSealed == true, error == nil, (200..<300).contains(status) {
                    journal.settle(ticket)
                } else if error == nil, (200..<300).contains(status),
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

/// A distinct delegate/connection pool for each enrolled private CA. Task
/// object keys in the owner avoid collisions between session-local task IDs.
private nonisolated final class PinnedBackupDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let owner: BackgroundUploader
    private let identity: LocalServerIdentity
    init(owner: BackgroundUploader, identity: LocalServerIdentity) { self.owner = owner; self.identity = identity }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @Sendable @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        LocalServerIdentity.answer(challenge, requestURL: task.currentRequest?.url, identity: identity, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @Sendable @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        owner.urlSession(session, task: task, didSendBodyData: bytesSent,
            totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        owner.urlSession(session, task: task, didCompleteWithError: error)
    }
}
