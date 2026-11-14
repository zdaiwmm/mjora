import Foundation
import SQLite3

private nonisolated final class SyncSQLite: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw RemoteSyncError.unsafeHistory
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS sync_state (namespace TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(namespace,kind,id))")
        guard try rows("PRAGMA quick_check").first?.first == Data("ok".utf8) else { throw RemoteSyncError.unsafeHistory }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [Data] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [Data] = []) throws -> [[Data]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RemoteSyncError.unsafeHistory }
        defer { sqlite3_finalize(statement) }
        for (index, data) in values.enumerated() {
            let status = data.withUnsafeBytes { pointer in
                sqlite3_bind_text(statement, Int32(index + 1), pointer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else { throw RemoteSyncError.unsafeHistory }
        }
        var result: [[Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw RemoteSyncError.unsafeHistory }
            var row: [Data] = []
            for column in 0..<sqlite3_column_count(statement) {
                let count = Int(sqlite3_column_bytes(statement, column))
                if let pointer = sqlite3_column_blob(statement, column) { row.append(Data(bytes: pointer, count: count)) }
                else { row.append(Data()) }
            }
            result.append(row)
        }
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

nonisolated struct SyncPendingBatch: Codable, Sendable {
    let id: String
    let accountKey: String
    let originSessionKey: String
    let operations: [RemoteIndexOperation]
    let acks: [String]
    var indexFlushed: Bool
    let completes: Bool
}
nonisolated struct SyncRemoteAsset: Codable, Equatable, Sendable {
    let id: String
    let ownerID: String
    let checksum: String
    let livePhotoVideoID: String?
    let deleted: Bool
}
private nonisolated struct SyncSessionState: Codable {
    var baseline = false
    var rebuilding = false
    var caughtUp = false
}
nonisolated struct LocalLibraryStoredSnapshot: Codable, Sendable {
    let assets: [DeviceAsset]
    let token: Data
    let permission: String
}

/// Account history is independent of derived snapshots and login-session checkpoints.
actor SyncStateStore {
    private let database: SyncSQLite
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(fileURL: URL) throws { database = try SyncSQLite(url: fileURL) }
    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "imora/incremental-sync.sqlite")
    }
    private func values(_ parts: String...) -> [Data] { parts.map { Data($0.utf8) } }
    private func get<T: Decodable>(_ type: T.Type, _ namespace: String, _ kind: String, _ id: String) throws -> T? {
        guard let data = try database.rows("SELECT value FROM sync_state WHERE namespace=? AND kind=? AND id=?", values(namespace, kind, id)).first?.first else { return nil }
        return try decoder.decode(type, from: data)
    }
    private func put<T: Encodable>(_ value: T, _ namespace: String, _ kind: String, _ id: String) throws {
        try database.execute("INSERT OR REPLACE INTO sync_state(namespace,kind,id,value) VALUES(?,?,?,?)", values(namespace, kind, id) + [try encoder.encode(value)])
    }
    private func all<T: Decodable>(_ type: T.Type, _ namespace: String, _ kind: String) throws -> [T] {
        try database.rows("SELECT value FROM sync_state WHERE namespace=? AND kind=? ORDER BY rowid", values(namespace, kind)).map { try decoder.decode(type, from: $0[0]) }
    }
    private func remove(_ namespace: String, _ kind: String, _ id: String? = nil) throws {
        if let id { try database.execute("DELETE FROM sync_state WHERE namespace=? AND kind=? AND id=?", values(namespace, kind, id)) }
        else { try database.execute("DELETE FROM sync_state WHERE namespace=? AND kind=?", values(namespace, kind)) }
    }
    private func session(_ scope: SyncScope) throws -> SyncSessionState {
        do { return try get(SyncSessionState.self, scope.sessionKey, "session", "state") ?? SyncSessionState() }
        catch is DecodingError { return SyncSessionState() }
    }
    func hasBaseline(scope: SyncScope) throws -> Bool { try session(scope).baseline }
    func isCaughtUp(scope: SyncScope) throws -> Bool { let state = try session(scope); return state.baseline && state.caughtUp && !state.rebuilding }
    func markIncomplete(scope: SyncScope) throws {
        var state = try session(scope); state.caughtUp = false
        try put(state, scope.sessionKey, "session", "state")
    }
    /// A sparse delta is staged too: malformed later records cannot replace the last complete snapshot.
    func prepareRound(scope: SyncScope) throws -> Bool {
        var state = try session(scope)
        if state.baseline {
            let expected = try get(Int.self, scope.accountKey, "derivedIntegrity", "assetCount")
            let actual = try? all(SyncRemoteAsset.self, scope.accountKey, "assets").count
            let stageValid = !state.rebuilding || (try? all(SyncRemoteAsset.self, scope.sessionKey, "stagedAssets")) != nil
            if expected == nil || actual != expected || !stageValid {
                state.baseline = false; state.rebuilding = false
                try put(state, scope.sessionKey, "session", "state")
            }
        }
        if !state.baseline { try beginBaseline(scope: scope); return true }
        if state.rebuilding { return false }
        try database.transaction {
            for (active, staged) in [("assets", "stagedAssets"), ("albums", "stagedAlbums"), ("memberships", "stagedMemberships")] {
                try remove(scope.sessionKey, staged)
                try database.execute("INSERT INTO sync_state(namespace,kind,id,value) SELECT ?,?,id,value FROM sync_state WHERE namespace=? AND kind=?", values(scope.sessionKey, staged, scope.accountKey, active))
            }
            state.rebuilding = true; state.caughtUp = false
            try put(state, scope.sessionKey, "session", "state")
        }
        return false
    }
    func beginBaseline(scope: SyncScope) throws {
        try database.transaction {
            try remove(scope.sessionKey, "stagedAssets")
            try remove(scope.sessionKey, "stagedAlbums")
            try remove(scope.sessionKey, "stagedMemberships")
            var state = try session(scope); state.rebuilding = true; state.caughtUp = false
            try put(state, scope.sessionKey, "session", "state")
        }
    }
    func importHistory(_ pairings: [SyncHistoricalPairing], scope: SyncScope) throws {
        try database.transaction {
            for pairing in pairings {
                // A deleted component may already have had its JSON remote ID cleared.
                let old = try get(SyncHistoricalPairing.self, scope.accountKey, "history", pairing.localID)
                let merged = SyncHistoricalPairing(localID: pairing.localID,
                    primaryRemoteID: pairing.primaryRemoteID ?? old?.primaryRemoteID,
                    motionRemoteID: pairing.motionRemoteID ?? old?.motionRemoteID,
                    primaryChecksum: pairing.primaryChecksum, motionChecksum: pairing.motionChecksum,
                    isLivePhoto: pairing.isLivePhoto, remoteDeleted: pairing.remoteDeleted || old?.remoteDeleted == true)
                try put(merged, scope.accountKey, "history", pairing.localID)
            }
        }
    }
    func historicalPairing(localID: String, scope: SyncScope) throws -> SyncHistoricalPairing? {
        try get(SyncHistoricalPairing.self, scope.accountKey, "history", localID)
    }
    func skippableLocalIDs(pairings: [SyncHistoricalPairing], scope: SyncScope) throws -> Set<String> {
        guard try isCaughtUp(scope: scope) else { return [] }
        return try Set(pairings.filter { try canSkipRoutineBackupRecheck(pairing: $0, scope: scope) }.map(\.localID))
    }
    func canSkipRoutineBackupRecheck(pairing: SyncHistoricalPairing, scope: SyncScope) throws -> Bool {
        guard try isCaughtUp(scope: scope), !pairing.remoteDeleted,
              try !isLocalDeletionProtected(pairing.localID, scope: scope),
              let primaryID = pairing.primaryRemoteID,
              let primary = try remoteAsset(primaryID, scope: scope), primary.ownerID == scope.accountID,
              !primary.deleted, primary.checksum == pairing.primaryChecksum,
              try !isRemoteDeleted(primaryID, scope: scope) else { return false }
        if pairing.isLivePhoto {
            guard let motionID = pairing.motionRemoteID, let checksum = pairing.motionChecksum,
                  primary.livePhotoVideoID == motionID,
                  let motion = try remoteAsset(motionID, scope: scope), motion.ownerID == scope.accountID,
                  !motion.deleted, motion.checksum == checksum,
                  try !isRemoteDeleted(motionID, scope: scope) else { return false }
        }
        return true
    }
    func remoteAsset(_ id: String, scope: SyncScope) throws -> SyncRemoteAsset? {
        try get(SyncRemoteAsset.self, scope.accountKey, "assets", id)
    }
    func isRemoteDeleted(_ id: String, scope: SyncScope) throws -> Bool {
        try get(Bool.self, scope.accountKey, "deleted", id) == true
    }
    func isLocalDeletionProtected(_ id: String, scope: SyncScope) throws -> Bool {
        if try get(Bool.self, scope.accountKey, "protectedLocal", id) == true { return true }
        guard let history = try historicalPairing(localID: id, scope: scope) else { return false }
        let primaryDeleted = try history.primaryRemoteID.map { try isRemoteDeleted($0, scope: scope) } ?? false
        let motionDeleted = try history.motionRemoteID.map { try isRemoteDeleted($0, scope: scope) } ?? false
        return history.remoteDeleted || primaryDeleted || motionDeleted
    }
    /// Events, pending JSON operations, and exact server acknowledgement strings share one transaction.
    func apply(batch: RemoteSyncBatch, scope: SyncScope) throws {
        guard batch.records.count <= 128 else { throw RemoteSyncError.invalidRecord }
        try database.transaction {
            var state = try session(scope)
            var operations: [RemoteIndexOperation] = []
            var completes = false
            for record in batch.records {
                try record.validate()
                switch record.type {
                case "AssetV2":
                    guard record.data.ownerId == scope.accountID else { throw RemoteSyncError.foreignAsset }
                    let asset = SyncRemoteAsset(id: record.data.id!, ownerID: record.data.ownerId!, checksum: record.data.checksum!, livePhotoVideoID: record.data.livePhotoVideoId, deleted: record.data.deletedAt != nil)
                    try put(asset, state.rebuilding ? scope.sessionKey : scope.accountKey, state.rebuilding ? "stagedAssets" : "assets", asset.id)
                    operations.append(asset.deleted ? .removed(asset.id) : .invalidate(asset.id))
                    if asset.deleted { try put(true, scope.accountKey, "deleted", asset.id) }
                case "AssetDeleteV1":
                    let id = record.data.assetId!
                    try remove(state.rebuilding ? scope.sessionKey : scope.accountKey, state.rebuilding ? "stagedAssets" : "assets", id)
                    try put(true, scope.accountKey, "deleted", id)
                    operations.append(.removed(id))
                case "AlbumV2", "AlbumDeleteV1":
                    let namespace = state.rebuilding ? scope.sessionKey : scope.accountKey
                    let kind = state.rebuilding ? "stagedAlbums" : "albums"
                    if record.type == "AlbumV2" { try put(record, namespace, kind, record.data.id!) }
                    else { try remove(namespace, kind, record.data.albumId!) }
                case "AlbumToAssetV1", "AlbumToAssetBackfillV1", "AlbumToAssetDeleteV1":
                    let namespace = state.rebuilding ? scope.sessionKey : scope.accountKey
                    let kind = state.rebuilding ? "stagedMemberships" : "memberships"
                    let id = record.data.albumId! + "|" + record.data.assetId!
                    if record.type == "AlbumToAssetDeleteV1" { try remove(namespace, kind, id) }
                    else { try put(record, namespace, kind, id) }
                case "SyncCompleteV1":
                    if state.rebuilding {
                        for history in try all(SyncHistoricalPairing.self, scope.accountKey, "history") {
                            func missing(_ id: String?) throws -> Bool {
                                guard let id, let asset = try get(SyncRemoteAsset.self, scope.sessionKey, "stagedAssets", id) else { return true }
                                return asset.deleted
                            }
                            let primaryMissing = try missing(history.primaryRemoteID)
                            let motionMissing = try history.isLivePhoto && missing(history.motionRemoteID)
                            let primary = try history.primaryRemoteID.flatMap { try get(SyncRemoteAsset.self, scope.sessionKey, "stagedAssets", $0) }
                            let wrongPair = history.isLivePhoto && primary?.livePhotoVideoID != history.motionRemoteID
                            for (id, missing) in [(history.primaryRemoteID, primaryMissing), (history.motionRemoteID, motionMissing)] {
                                if let id, missing { try put(true, scope.accountKey, "deleted", id); operations.append(.removed(id)) }
                            }
                            if history.remoteDeleted || primaryMissing || motionMissing || wrongPair {
                                try put(true, scope.accountKey, "protectedLocal", history.localID)
                                operations.append(.protectLocal(history.localID))
                            }
                        }
                        for (staged, active) in [("stagedAssets", "assets"), ("stagedAlbums", "albums"), ("stagedMemberships", "memberships")] {
                            try remove(scope.accountKey, active)
                            try database.execute("INSERT INTO sync_state(namespace,kind,id,value) SELECT ?,?,id,value FROM sync_state WHERE namespace=? AND kind=?", values(scope.accountKey, active, scope.sessionKey, staged))
                            try remove(scope.sessionKey, staged)
                        }
                        try put(try all(SyncRemoteAsset.self, scope.accountKey, "assets").count, scope.accountKey, "derivedIntegrity", "assetCount")
                        state.baseline = true; state.rebuilding = false
                    }
                    completes = true
                default: break
                }
            }
            if !batch.records.isEmpty {
                let id = UUID().uuidString
                try put(SyncPendingBatch(id: id, accountKey: scope.accountKey, originSessionKey: scope.sessionKey, operations: operations, acks: batch.records.map(\.ack), indexFlushed: false, completes: completes), scope.sessionKey, "pending", id)
            }
            state.caughtUp = false
            try put(state, scope.sessionKey, "session", "state")
        }
    }
    func pending(scope: SyncScope) throws -> [SyncPendingBatch] { try all(SyncPendingBatch.self, scope.sessionKey, "pending") }
    func pendingIndexWork(scope: SyncScope) throws -> [SyncPendingBatch] {
        try database.rows("SELECT value FROM sync_state WHERE kind='pending' ORDER BY rowid").map {
            try decoder.decode(SyncPendingBatch.self, from: $0[0])
        }.filter { $0.accountKey == scope.accountKey && (!$0.indexFlushed || $0.originSessionKey != scope.sessionKey) }
    }
    func completeIndexWork(_ pending: SyncPendingBatch, scope: SyncScope) throws {
        guard pending.accountKey == scope.accountKey else { throw RemoteSyncError.unsafeHistory }
        if pending.originSessionKey == scope.sessionKey { try markIndexFlushed(pending.id, scope: scope) }
        else {
            // The old credential cannot receive HTTP acknowledgements. Only retire its JSON work.
            try remove(pending.originSessionKey, "pending", pending.id)
        }
    }
    func markIndexFlushed(_ id: String, scope: SyncScope) throws {
        guard var pending = try get(SyncPendingBatch.self, scope.sessionKey, "pending", id) else { return }
        pending.indexFlushed = true; try put(pending, scope.sessionKey, "pending", id)
    }
    func markAcknowledged(_ id: String, scope: SyncScope) throws {
        try database.transaction {
            guard let pending = try get(SyncPendingBatch.self, scope.sessionKey, "pending", id), pending.indexFlushed else { throw RemoteSyncError.indexFlushFailed }
            if pending.completes { var state = try session(scope); state.caughtUp = true; try put(state, scope.sessionKey, "session", "state") }
            try remove(scope.sessionKey, "pending", id)
        }
    }
    func localSnapshot() throws -> LocalLibraryStoredSnapshot? {
        do { return try get(LocalLibraryStoredSnapshot.self, "device", "local", "snapshot") }
        catch is DecodingError { try remove("device", "local", "snapshot"); return nil }
    }
    func commitLocalSnapshot(_ snapshot: LocalLibraryStoredSnapshot) throws {
        try database.transaction { try put(snapshot, "device", "local", "snapshot") }
    }
}
