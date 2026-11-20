import Foundation
import Observation
import os

nonisolated let realtimeLog = Logger(subsystem: "app.imora", category: "realtime")

/// changes broadcast to listeners. instant patches carry data; resync asks
/// models to diff their buckets against the server.
@MainActor
protocol RealtimeListener: AnyObject {
    func realtimeAssetsRemoved(_ ids: Set<String>)
    func realtimeAssetUpdated(_ detail: AssetDetail)
    func realtimeResync()
    func realtimeCatchUp()
    func realtimeAlbumsChanged()
    func realtimeLocalChanged()
    func realtimeNotification(_ notification: ServerNotification)
}

extension RealtimeListener {
    func realtimeAssetsRemoved(_ ids: Set<String>) {}
    func realtimeAssetUpdated(_ detail: AssetDetail) {}
    func realtimeResync() {}
    func realtimeCatchUp() { realtimeResync() }
    func realtimeAlbumsChanged() {}
    func realtimeLocalChanged() {}
    func realtimeNotification(_ notification: ServerNotification) {}
}

/// keeps the app in sync with the server over the immich socket.io channel,
/// so grids update live and pull-to-refresh is never needed. models register
/// as weak listeners; screens can also observe the generation counters.
@Observable
final class RealtimeHub {
    private struct WeakListener {
        weak var value: (any RealtimeListener)?
    }

    /// bumped after album events so album lists reload without a listener.
    private(set) var albumsGeneration = 0
    private(set) var localGeneration = 0
    /// cache-buster per person, set once the server has re-rendered their
    /// portrait. it outranks the person's updatedAt because a re-render can
    /// land after the row was already read back, and it is persisted because
    /// the image cache those stale bytes sit in outlives the launch.
    private(set) var personThumbnailKeys: [String: String] = UserDefaults.standard
        .dictionary(forKey: RealtimeHub.personThumbnailKeysDefaultsKey) as? [String: String] ?? [:]
    private(set) var isConnected = false
    /// set when a connection drops or fails so the next successful connect
    /// broadcasts a catch-up resync.
    private var resyncOnConnect = false
    /// wired by sessionstore to the backup manager, which retires the device
    /// twins of assets the server has repainted.
    @ObservationIgnored var onBackupReconciliationNeeded: ((UUID?) -> Void)?
    @ObservationIgnored var onBackupConnectionGap: (() -> Void)?
    @ObservationIgnored var onRemoteBackupChange: ((Set<String>, BackupRemoteChange) -> Void)?
    @ObservationIgnored var onRemoteEdit: ((Set<String>) -> Void)?
    /// the server version sent on every connect, so api shapes can follow an
    /// upgrade without a relaunch.
    @ObservationIgnored var onServerVersion: ((ServerVersion) -> Void)?

    private struct EventWaiter {
        let names: Set<String>
        let assetID: String?
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let client: ImoraClient
    private var listeners: [WeakListener] = []
    private var active = false
    private var connectionTask: Task<Void, Never>?
    private var resyncDebounce: Task<Void, Never>?
    private var lastResyncFlush: Date = .distantPast
    private var localDebounce: Task<Void, Never>?
    private var albumsDebounce: Task<Void, Never>?
    private var personKeysPersist: Task<Void, Never>?
    private var safetyTick: Task<Void, Never>?
    private var waiters: [UUID: EventWaiter] = [:]

    /// coalescing window for bursts of server events.
    private static let resyncDelay: Duration = .milliseconds(1_500)
    /// a first event after this much quiet flushes immediately.
    private static let resyncMaxWait: TimeInterval = 5
    /// background diff while connected, catching events the server never
    /// sends. one cheap buckets request per live grid when nothing changed.
    private static let safetyInterval: Duration = .seconds(120)
    fileprivate static let personThumbnailKeysDefaultsKey = "imora.personThumbnailKeys"

    init(client: ImoraClient) {
        self.client = client
    }

    func addListener(_ listener: any RealtimeListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakListener(value: listener))
    }

    // MARK: - lifecycle

    /// foreground drives connection: connect and resync on activation, tear
    /// down when the app leaves the foreground.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            // the network can still be waking up, so the first connect diffs
            // again in case the immediate pass below failed.
            resyncOnConnect = true
            startConnection()
            // the resync doubles as the missed-while-backgrounded catch-up.
            broadcast { $0.realtimeCatchUp() }
            onBackupReconciliationNeeded?(nil)
            startSafetyTick()
        } else {
            connectionTask?.cancel()
            connectionTask = nil
            safetyTick?.cancel()
            safetyTick = nil
            resyncDebounce?.cancel()
            resyncDebounce = nil
            isConnected = false
            // Deliberate background suspension is not a transport failure.
            // Foreground activation already requests catch-up; uploads keep
            // their existing authority while the socket is intentionally off.
        }
    }

    func shutdown() {
        setActive(false)
        localDebounce?.cancel()
        albumsDebounce?.cancel()
        personKeysPersist?.cancel()
        listeners.removeAll()
    }

    /// called by the backup manager whenever device assets or the backup
    /// index changed. debounced so upload bursts coalesce.
    func notifyLocalChange() {
        guard localDebounce == nil else { return }
        localDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            self.localDebounce = nil
            self.localGeneration &+= 1
            self.broadcast { $0.realtimeLocalChanged() }
        }
    }

    /// suspends until one of `names` arrives for `assetID` - any asset when
    /// nil - or the timeout passes; returns whether the event was seen. used
    /// to hold the editor spinner until the server re-rendered derivatives.
    func waitForAssetEvent(named names: Set<String>, assetID: String?, timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = EventWaiter(names: names, assetID: assetID, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveWaiter(id, with: false)
            }
        }
    }

    private func resolveWaiter(_ id: UUID, with result: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: result)
    }

    // MARK: - broadcasting

    private func broadcast(_ action: (any RealtimeListener) -> Void) {
        listeners.removeAll { $0.value == nil }
        for listener in listeners {
            if let value = listener.value { action(value) }
        }
    }

    private func scheduleResync() {
        if Date().timeIntervalSince(lastResyncFlush) > Self.resyncMaxWait {
            broadcastResyncNow()
            return
        }
        guard resyncDebounce == nil else { return }
        resyncDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.resyncDelay)
            guard let self, !Task.isCancelled else { return }
            self.resyncDebounce = nil
            self.broadcastResyncNow()
        }
    }

    private func broadcastResyncNow() {
        lastResyncFlush = Date()
        broadcast { $0.realtimeResync() }
    }

    private func startSafetyTick() {
        safetyTick?.cancel()
        safetyTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.safetyInterval)
                guard let self, !Task.isCancelled else { return }
                self.broadcastResyncNow()
            }
        }
    }

    // MARK: - socket connection

    private func startConnection() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            var backoff: Double = 1
            while let self, self.active, !Task.isCancelled {
                do {
                    try await self.connectOnce()
                    backoff = 1
                } catch is CancellationError {
                    return
                } catch {
                    realtimeLog.info("socket dropped: \((error as NSError).code)")
                }
                // URLSession can report deliberate cancellation as URLError,
                // not CancellationError. Do not turn background teardown into
                // a transport gap after the owner has stopped this socket.
                guard self.active, !Task.isCancelled else { return }
                // a dropped or refused socket means missed events; the next
                // successful connect catches up immediately instead of
                // waiting out the safety tick. this is also what turns an
                // offline launch into a live grid the moment the network
                // returns.
                self.resyncOnConnect = true
                self.isConnected = false
                self.onBackupConnectionGap?()
                let jitter = Double.random(in: 0...0.4) * backoff
                try? await Task.sleep(for: .seconds(backoff + jitter))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// one engine.io v4 + socket.io v4 session over a websocket. returns only
    /// when the socket closes or errors.
    private func connectOnce() async throws {
        let request = try client.authorizedRequest(url: ServerRoute.resolve(client.apiURL))
        try await receiveLoop(request: request, token: client.accessToken, context: client.context,
            session: client.transportSession(for: request, redirectsAllowed: false))
    }

    /// concurrent so frame parsing and event decoding stay off the main
    /// thread - a bulk server job floods thousands of frames, and each used
    /// to cost json work on main. only the typed results hop back.
    @concurrent
    private func receiveLoop(request: URLRequest, token: String, context: AccountRequestContext, session: URLSession) async throws {
        let task = SocketConnection.makeTask(request: request, token: token, session: session)
        try context.startWhileActive(for: request) {
            try Task.checkCancellation()
            task.resume()
        }
        defer { task.cancel(with: .goingAway, reason: nil) }

        // grace before the first server frame, then a rolling deadline based
        // on the server ping cadence so half-open sockets get torn down.
        var deadline: Duration = .seconds(15)
        let connectionGeneration = UUID()

        while !Task.isCancelled {
            let message = try await SocketConnection.receive(from: task, timeout: deadline)
            try Task.checkCancellation()
            guard context.isActive else { throw ServerTrustError.sessionExpired }
            guard case .string(let text) = message else { continue }
            switch SocketConnection.parse(text) {
            case .open(let pingInterval, let pingTimeout):
                deadline = .milliseconds(pingInterval + pingTimeout + 5_000)
                try await task.send(.string("40"))
            case .ping:
                try await task.send(.string("3"))
            case .connected:
                await noteConnected(generation: connectionGeneration)
            case .connectError(let detail):
                throw ImoraError.http(401, detail)
            case .event(let event):
                await handleEvent(event)
            case .close:
                return
            case .ignored:
                break
            }
        }
    }

    private func noteConnected(generation: UUID) {
        guard client.context.isActive, active else { return }
        realtimeLog.info("socket connected")
        isConnected = true
        if resyncOnConnect {
            onBackupReconciliationNeeded?(generation)
            resyncOnConnect = false
            broadcast { $0.realtimeCatchUp() }
        }
    }

    // MARK: - events

    /// both the modern sync events and the legacy per-asset events are
    /// registered; servers emit whichever set their version supports. the
    /// payload arrives fully decoded from the receive loop.
    private func handleEvent(_ event: RealtimeEventPayload) async {
        guard active, client.context.isActive else { return }
        let name = event.name
        if !waiters.isEmpty {
            for (id, waiter) in waiters where waiter.names.contains(name) {
                if waiter.assetID == nil || event.assetIDs.contains(waiter.assetID!) {
                    resolveWaiter(id, with: true)
                }
            }
        }

        switch name {
        case "AssetEditReadyV1", "AssetEditReadyV2":
            await client.invalidateMediaCache(assetIDs: Array(event.assetIDs))
            guard active, client.context.isActive else { return }
            // an edit anywhere - web, another phone - repaints the server copy,
            // so any device twin stops being a valid stand-in for it.
            onRemoteEdit?(event.assetIDs)
            scheduleResync()

        case "on_asset_restore":
            onRemoteBackupChange?(event.assetIDs, .restored)
            scheduleResync()

        case "AssetUploadReadyV1", "AssetUploadReadyV2", "on_upload_success", "on_asset_stack_update":
            onBackupReconciliationNeeded?(nil)
            scheduleResync()

        case "on_asset_delete", "on_asset_trash", "on_asset_hidden":
            await client.revokeMediaAccess(assetIDs: event.assetIDs)
            try? await OfflineAlbumStore.shared.invalidate(scope: client.mediaDisplayScope, ids: event.assetIDs, remove: true)
            await OfflineAlbumDownloads.shared.reload()
            let change: BackupRemoteChange = name == "on_asset_delete" ? .deleted : (name == "on_asset_trash" ? .trashed : .hidden)
            onRemoteBackupChange?(event.assetIDs, change)
            if !event.assetIDs.isEmpty {
                broadcast { $0.realtimeAssetsRemoved(event.assetIDs) }
            }
            scheduleResync()

        case "on_asset_update":
            if let detail = event.detail {
                try? await OfflineAlbumStore.shared.observe(detail.asAsset(), scope: client.mediaDisplayScope)
                await OfflineAlbumDownloads.shared.reload()
                broadcast { $0.realtimeAssetUpdated(detail) }
            }
            scheduleResync()

        case "on_album_update":
            // coalesced like resyncs: a bulk add emits one event per album
            // touched, and each generation bump costs a full albums refetch.
            if albumsDebounce == nil {
                albumsDebounce = Task { [weak self] in
                    try? await Task.sleep(for: Self.resyncDelay)
                    guard let self, !Task.isCancelled else { return }
                    self.albumsDebounce = nil
                    self.albumsGeneration += 1
                    self.broadcast { $0.realtimeAlbumsChanged() }
                }
            }

        case "on_person_thumbnail":
            // the payload is the bare person id.
            guard let personID = event.personID else { break }
            personThumbnailKeys[personID] = String(Int(Date().timeIntervalSince1970 * 1000))
            // persisted after the burst settles - a face job emits thousands
            // of these, and each write serializes the whole dictionary.
            if personKeysPersist == nil {
                personKeysPersist = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.personKeysPersist = nil
                    UserDefaults.standard.set(
                        self.personThumbnailKeys,
                        forKey: Self.personThumbnailKeysDefaultsKey
                    )
                }
            }

        case "on_notification":
            // the payload is the whole entry, so the inbox never has to refetch.
            if let notification = event.notification {
                broadcast { $0.realtimeNotification(notification) }
            }

        case "on_server_version":
            if let version = event.serverVersion {
                onServerVersion?(version)
            }

        default:
            break
        }
    }
}

/// one server event, decoded into sendable pieces off the main thread. only
/// the fields the handler for that event name reads are populated.
nonisolated struct RealtimeEventPayload: Sendable {
    let name: String
    var assetIDs: Set<String> = []
    var detail: AssetDetail?
    var notification: ServerNotification?
    var personID: String?
    var serverVersion: ServerVersion?
}

// MARK: - wire protocol

/// minimal engine.io v4 framing over urlsession websockets. only what the
/// immich server actually uses: text frames, websocket transport, default
/// namespace.
private nonisolated enum SocketConnection {
    enum Packet: Sendable {
        case open(pingInterval: Int, pingTimeout: Int)
        case ping
        case connected
        case connectError(String)
        case event(RealtimeEventPayload)
        case close
        case ignored
    }

    static func makeTask(request authorized: URLRequest, token: String, session: URLSession) -> URLSessionWebSocketTask {
        let apiURL = authorized.url!
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.scheme = apiURL.scheme == "http" ? "ws" : "wss"
        components.path = apiURL.path() + "/socket.io/"
        components.query = "EIO=4&transport=websocket"
        var request = authorized
        request.url = components.url!
        // the server authenticates the handshake from the session cookie.
        request.setValue("imora_access_token=\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 60
        return session.webSocketTask(with: request)
    }

    /// receive with a deadline: a healthy server pings every pinginterval, so
    /// prolonged silence means the connection is dead even if tcp disagrees.
    static func receive(
        from task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    task.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let message = try await group.next() else {
                    throw URLError(.networkConnectionLost)
                }
                return message
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    static func parse(_ text: String) -> Packet {
        guard let first = text.first else { return .ignored }
        let rest = String(text.dropFirst())
        switch first {
        case "0":
            let object = (try? JSONSerialization.jsonObject(with: Data(rest.utf8))) as? [String: Any]
            return .open(
                pingInterval: object?["pingInterval"] as? Int ?? 25_000,
                pingTimeout: object?["pingTimeout"] as? Int ?? 20_000
            )
        case "1":
            return .close
        case "2":
            return .ping
        case "4":
            return parseSocketIO(rest)
        default:
            return .ignored
        }
    }

    private static func parseSocketIO(_ body: String) -> Packet {
        guard let type = body.first else { return .ignored }
        switch type {
        case "0":
            return .connected
        case "4":
            return .connectError(String(body.dropFirst()))
        case "2":
            // event: optional namespace and ack id precede the json array.
            guard let start = body.firstIndex(of: "["),
                  let array = (try? JSONSerialization.jsonObject(with: Data(body[start...].utf8))) as? [Any],
                  let name = array.first as? String
            else { return .ignored }
            return .event(decodeEvent(name, payload: array.count > 1 ? array[1] : nil))
        default:
            return .ignored
        }
    }

    /// all json work happens here, on whatever executor runs the receive
    /// loop; the handler on the main actor only reads typed fields.
    private static func decodeEvent(_ name: String, payload: Any?) -> RealtimeEventPayload {
        var event = RealtimeEventPayload(name: name, assetIDs: assetIDs(from: payload))
        switch name {
        case "on_asset_update":
            if let payload,
               let data = try? JSONSerialization.data(withJSONObject: payload) {
                event.detail = try? JSONDecoder().decode(AssetDetail.self, from: data)
            }
        case "on_notification":
            if let payload,
               let data = try? JSONSerialization.data(withJSONObject: payload) {
                event.notification = try? JSONDecoder().decode(ServerNotification.self, from: data)
            }
        case "on_person_thumbnail":
            event.personID = payload as? String
        case "on_server_version":
            if let payload,
               let data = try? JSONSerialization.data(withJSONObject: payload) {
                event.serverVersion = try? JSONDecoder().decode(ServerVersion.self, from: data)
            }
        default:
            break
        }
        return event
    }

    /// legacy events carry a bare id, an id array, or a wrapping object.
    private static func assetIDs(from payload: Any?) -> Set<String> {
        switch payload {
        case let id as String:
            return [id]
        case let ids as [String]:
            return Set(ids)
        case let object as [String: Any]:
            for key in ["assetIds", "ids", "assetId", "id", "asset"] {
                if let ids = assetIDs(from: object[key]) as Set<String>?, !ids.isEmpty {
                    return ids
                }
            }
            return []
        default:
            return []
        }
    }
}
