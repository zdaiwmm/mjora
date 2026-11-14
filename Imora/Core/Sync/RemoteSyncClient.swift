import Foundation

nonisolated enum RemoteSyncError: Error, Equatable {
    case invalidRecord, recordTooLarge, incompleteStream, indexFlushFailed, compatibilityRequired
    case foreignAsset, overlappingCatchUp, unsafeHistory
}

/// Stable server identity survives LAN/WAN routing changes; session key survives launches only.
nonisolated struct SyncScope: Codable, Hashable, Sendable {
    let serverIdentity: String
    let accountID: String
    let loginSessionKey: String
    var accountKey: String { Self.key([serverIdentity, accountID]) }
    var sessionKey: String { Self.key([serverIdentity, accountID, loginSessionKey]) }
    private static func key(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
}

nonisolated struct RemoteSyncSummary: Sendable {
    var changedIDs: Set<String> = []
    var deletedIDs: Set<String> = []
    var resetOccurred = false
    var completed = false
}

/// Only fields used by the backup projection. Other metadata remains encoded in the original record.
nonisolated struct RemoteSyncRecord: Codable, Sendable {
    let type: String
    let ack: String
    let data: Payload
    nonisolated struct Payload: Codable, Sendable {
        var id: String?
        var assetId: String?
        var ownerId: String?
        var checksum: String?
        var deletedAt: String?
        var livePhotoVideoId: String?
        var albumId: String?
    }
    static let supported: Set<String> = ["AssetV2", "AssetDeleteV1", "AlbumV2", "AlbumDeleteV1", "AlbumToAssetV1", "AlbumToAssetBackfillV1", "AlbumToAssetDeleteV1", "SyncAckV1", "SyncResetV1", "SyncCompleteV1"]
    func validate() throws {
        guard Self.supported.contains(type), !ack.isEmpty else { throw RemoteSyncError.invalidRecord }
        switch type {
        case "AssetV2":
            guard let id = data.id, !id.isEmpty, let owner = data.ownerId, !owner.isEmpty,
                  let checksum = data.checksum, !checksum.isEmpty else { throw RemoteSyncError.invalidRecord }
        case "AssetDeleteV1": guard data.assetId != nil else { throw RemoteSyncError.invalidRecord }
        case "AlbumV2": guard data.id != nil else { throw RemoteSyncError.invalidRecord }
        case "AlbumDeleteV1": guard data.albumId != nil else { throw RemoteSyncError.invalidRecord }
        case "AlbumToAssetV1", "AlbumToAssetBackfillV1", "AlbumToAssetDeleteV1":
            guard data.albumId != nil, data.assetId != nil else { throw RemoteSyncError.invalidRecord }
        default: break
        }
    }
}

/// Holds at most one partial record. The cap applies before parsing, including malformed JSON.
nonisolated struct RemoteSyncJSONLines {
    static let maximumRecordBytes = 256 * 1024
    private var partial = Data()
    mutating func append(_ chunk: Data) throws -> [RemoteSyncRecord] {
        var records: [RemoteSyncRecord] = []
        for byte in chunk {
            if byte == 10 {
                guard !partial.isEmpty else { throw RemoteSyncError.invalidRecord }
                let record = try JSONDecoder().decode(RemoteSyncRecord.self, from: partial)
                try record.validate()
                records.append(record)
                partial.removeAll(keepingCapacity: true)
            } else {
                guard partial.count < Self.maximumRecordBytes else { throw RemoteSyncError.recordTooLarge }
                partial.append(byte)
            }
        }
        return records
    }
    func finish() throws {
        guard partial.isEmpty else { throw RemoteSyncError.incompleteStream }
    }
}

nonisolated struct RemoteSyncBatch: Sendable { let records: [RemoteSyncRecord] }
nonisolated enum RemoteIndexOperation: Codable, Equatable, Sendable {
    case invalidate(String), removed(String), protectLocal(String), restoreLocal(SyncHistoricalPairing)
}
nonisolated struct SyncHistoricalPairing: Codable, Equatable, Sendable {
    let localID: String
    let primaryRemoteID: String?
    let motionRemoteID: String?
    let primaryChecksum: String
    let motionChecksum: String?
    let isLivePhoto: Bool
    let remoteDeleted: Bool
}
nonisolated protocol RemoteSyncTransport: Sendable {
    func stream(types: [String], reset: Bool) async throws -> AsyncThrowingStream<Data, Error>
    func acknowledge(_ acks: [String]) async throws
}
nonisolated protocol RemoteSyncIndexBridge: Sendable {
    /// Throw if legacy history could not be safely loaded; absence cannot be inferred from corruption.
    func history(scope: SyncScope) async throws -> [SyncHistoricalPairing]
    /// Must be idempotent, invalidate strict proof, and return only after durable JSON flush.
    func applyAndFlush(_ operations: [RemoteIndexOperation], scope: SyncScope) async throws
}

actor RemoteSyncClient {
    nonisolated enum Credential: Sendable { case session, apiKey }
    static let subscriptions = ["AssetsV2", "AlbumsV2", "AlbumToAssetsV1"]
    private let store: SyncStateStore
    private let transport: any RemoteSyncTransport
    private let indexBridge: any RemoteSyncIndexBridge
    private let credential: Credential
    private var running = false

    init(store: SyncStateStore, transport: any RemoteSyncTransport, indexBridge: any RemoteSyncIndexBridge, credential: Credential = .session) {
        self.store = store; self.transport = transport; self.indexBridge = indexBridge; self.credential = credential
    }

    func recoverPending(scope: SyncScope) async throws {
        for pending in try await store.pendingIndexWork(scope: scope) {
            try await indexBridge.applyAndFlush(pending.operations, scope: scope)
            try await store.completeIndexWork(pending, scope: scope)
        }
        guard credential == .session else { return }
        for pending in try await store.pending(scope: scope) {
            try await transport.acknowledge(pending.acks)
            try await store.markAcknowledged(pending.id, scope: scope)
        }
    }

    func catchUp(scope: SyncScope) async throws -> RemoteSyncSummary {
        guard credential == .session else { throw RemoteSyncError.compatibilityRequired }
        guard !running else { throw RemoteSyncError.overlappingCatchUp }
        running = true
        defer { running = false }
        try await store.importHistory(indexBridge.history(scope: scope), scope: scope)
        try await recoverPending(scope: scope)
        try await store.markIncomplete(scope: scope)
        var summary = RemoteSyncSummary()
        let needsBaseline = try await store.prepareRound(scope: scope)
        // A reset handshake must be followed by another stream; repeated resets fail closed.
        for attempt in 0..<3 {
            let stream = try await transport.stream(types: Self.subscriptions, reset: needsBaseline && attempt == 0)
            var parser = RemoteSyncJSONLines()
            var completion: RemoteSyncRecord?
            var sawReset = false
            var buffered: [RemoteSyncRecord] = []
            for try await chunk in stream {
                try Task.checkCancellation()
                for record in try parser.append(chunk) {
                    guard completion == nil, !sawReset else { throw RemoteSyncError.invalidRecord }
                    if record.type == "SyncResetV1" {
                        guard buffered.isEmpty else { throw RemoteSyncError.invalidRecord }
                        try await store.beginBaseline(scope: scope)
                        try await store.apply(batch: RemoteSyncBatch(records: [record]), scope: scope)
                        try await recoverPending(scope: scope)
                        sawReset = true; summary.resetOccurred = true
                    } else if record.type == "SyncCompleteV1" {
                        // Do not commit a complete baseline before clean EOF.
                        completion = record
                    } else {
                        buffered.append(record)
                        if buffered.count >= 100 || record.type == "SyncAckV1" {
                            try await store.apply(batch: RemoteSyncBatch(records: buffered), scope: scope)
                            try await recoverPending(scope: scope)
                            buffered.removeAll(keepingCapacity: true)
                        }
                        if record.type == "AssetV2", let id = record.data.id {
                            if record.data.deletedAt == nil { summary.changedIDs.insert(id) }
                            else { summary.deletedIDs.insert(id) }
                        }
                        if record.type == "AssetDeleteV1", let id = record.data.assetId { summary.deletedIDs.insert(id) }
                    }
                }
            }
            try parser.finish()
            if sawReset { continue }
            guard let completion else { throw RemoteSyncError.incompleteStream }
            if !buffered.isEmpty {
                try await store.apply(batch: RemoteSyncBatch(records: buffered), scope: scope)
                try await recoverPending(scope: scope)
            }
            try await store.apply(batch: RemoteSyncBatch(records: [completion]), scope: scope)
            for pending in try await store.pending(scope: scope) {
                for operation in pending.operations {
                    if case .removed(let id) = operation { summary.deletedIDs.insert(id) }
                }
            }
            try await recoverPending(scope: scope)
            summary.completed = try await store.isCaughtUp(scope: scope)
            return summary
        }
        throw RemoteSyncError.incompleteStream
    }
}
