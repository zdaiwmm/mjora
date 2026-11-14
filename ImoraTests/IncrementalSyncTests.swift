import XCTest
@testable import Imora

private let syncScope = SyncScope(serverIdentity: "fixed-server", accountID: "owner", loginSessionKey: "session-a")

private func syncRecord(_ type: String, _ id: String = "1", _ data: [String: String] = [:]) throws -> RemoteSyncRecord {
    try JSONDecoder().decode(RemoteSyncRecord.self, from: JSONSerialization.data(withJSONObject: ["type": type, "ack": "\(type)|\(id)", "data": data]))
}
private func syncLine(_ record: RemoteSyncRecord) throws -> Data { var data = try JSONEncoder().encode(record); data.append(10); return data }
private func syncAsset(_ id: String, deleted: Bool = false) throws -> RemoteSyncRecord {
    var data = ["id": id, "ownerId": "owner", "checksum": "c3ludGhldGlj"]
    if deleted { data["deletedAt"] = "2026-11-14T00:00:00Z" }
    return try syncRecord("AssetV2", id, data)
}
private func syncStore(_ url: URL? = nil) throws -> SyncStateStore {
    try SyncStateStore(fileURL: url ?? FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
}

actor SyncFixtureTransport: RemoteSyncTransport {
    var streams: [[Data]]
    var acknowledgements: [String] = []
    var resets: [Bool] = []
    var ackFails = false
    init(_ streams: [[Data]]) { self.streams = streams }
    func stream(types: [String], reset: Bool) async throws -> AsyncThrowingStream<Data, Error> {
        resets.append(reset)
        guard !streams.isEmpty else { throw RemoteSyncError.incompleteStream }
        let chunks = streams.removeFirst()
        return AsyncThrowingStream { continuation in
            chunks.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
    func acknowledge(_ acks: [String]) async throws {
        if ackFails { throw RemoteSyncError.incompleteStream }
        acknowledgements += acks
    }
    func failAck(_ fail: Bool) { ackFails = fail }
}
actor SyncFixtureBridge: RemoteSyncIndexBridge {
    var operations: [RemoteIndexOperation] = []
    var pairings: [SyncHistoricalPairing] = []
    var flushFails = false
    func history(scope: SyncScope) async throws -> [SyncHistoricalPairing] { pairings }
    func applyAndFlush(_ operations: [RemoteIndexOperation], scope: SyncScope) async throws {
        if flushFails { throw RemoteSyncError.indexFlushFailed }
        self.operations += operations
    }
    func failFlush(_ fail: Bool) { flushFails = fail }
    func seed(_ pairings: [SyncHistoricalPairing]) { self.pairings = pairings }
}

final class IncrementalSyncTests: XCTestCase, @unchecked Sendable {
    func testFirstEmptyAndDeletionCatchUpFixture() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge()
        let transport = SyncFixtureTransport([
            [try syncLine(syncAsset("a")), try syncLine(syncRecord("SyncCompleteV1", "2"))],
            [try syncLine(syncRecord("SyncCompleteV1", "3"))],
            [try syncLine(syncRecord("AssetDeleteV1", "4", ["assetId": "a"])), try syncLine(syncRecord("SyncCompleteV1", "5"))]
        ])
        let client = RemoteSyncClient(store: store, transport: transport, indexBridge: bridge)
        let first = try await client.catchUp(scope: syncScope)
        XCTAssertTrue(first.completed); XCTAssertEqual(first.changedIDs, ["a"])
        let empty = try await client.catchUp(scope: syncScope)
        XCTAssertTrue(empty.completed); XCTAssertTrue(empty.changedIDs.isEmpty)
        let deleted = try await client.catchUp(scope: syncScope)
        XCTAssertEqual(deleted.deletedIDs, ["a"])
        let removed = try await store.isRemoteDeleted("a", scope: syncScope)
        XCTAssertTrue(removed)
        let resets = await transport.resets
        XCTAssertEqual(resets, [true, false, false])
    }

    func testSQLiteCommitBeforeJSONFlushNeverAcknowledgesAndReplaysAfterRestart() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite")
        let store = try syncStore(file), bridge = SyncFixtureBridge()
        let transport = SyncFixtureTransport([[try syncLine(syncAsset("a")), try syncLine(syncRecord("SyncCompleteV1"))]])
        await bridge.failFlush(true)
        do { _ = try await RemoteSyncClient(store: store, transport: transport, indexBridge: bridge).catchUp(scope: syncScope); XCTFail() } catch {}
        let acknowledgements = await transport.acknowledgements
        XCTAssertTrue(acknowledgements.isEmpty)
        let reopened = try syncStore(file)
        let pending = try await reopened.pending(scope: syncScope)
        XCTAssertFalse(pending.isEmpty)
        await bridge.failFlush(false)
        try await RemoteSyncClient(store: reopened, transport: transport, indexBridge: bridge).recoverPending(scope: syncScope)
        let finalPending = try await reopened.pending(scope: syncScope)
        XCTAssertTrue(finalPending.isEmpty)
    }

    func testAckFailureRetainsReplayAndDoesNotComplete() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge()
        let transport = SyncFixtureTransport([[try syncLine(syncAsset("a")), try syncLine(syncRecord("SyncCompleteV1"))]])
        await transport.failAck(true)
        let client = RemoteSyncClient(store: store, transport: transport, indexBridge: bridge)
        do { _ = try await client.catchUp(scope: syncScope); XCTFail() } catch {}
        let complete = try await store.isCaughtUp(scope: syncScope)
        XCTAssertFalse(complete)
        let pending = try await store.pending(scope: syncScope)
        XCTAssertFalse(pending.isEmpty)
        await transport.failAck(false)
        try await client.recoverPending(scope: syncScope)
        let acks = await transport.acknowledgements
        XCTAssertEqual(acks, ["AssetV2|a"])
    }

    func testResetHandshakeProtectsHistoricalMissingLivePhotoComponent() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge()
        await bridge.seed([SyncHistoricalPairing(localID: "local", primaryRemoteID: "still", motionRemoteID: "motion", primaryChecksum: "c3ludGhldGlj", motionChecksum: "bW90aW9u", isLivePhoto: true, remoteDeleted: false)])
        let transport = SyncFixtureTransport([
            [try syncLine(syncRecord("SyncResetV1", "reset"))],
            [try syncLine(syncAsset("still")), try syncLine(syncRecord("SyncCompleteV1"))]
        ])
        let result = try await RemoteSyncClient(store: store, transport: transport, indexBridge: bridge).catchUp(scope: syncScope)
        XCTAssertTrue(result.resetOccurred); XCTAssertTrue(result.completed)
        let operations = await bridge.operations
        XCTAssertTrue(operations.contains(.protectLocal("local")))
        let acks = await transport.acknowledgements
        XCTAssertEqual(acks.first, "SyncResetV1|reset")
    }

    func testIncompleteBaselineKeepsPreviousSnapshotAndDoesNotComplete() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge()
        let transport = SyncFixtureTransport([
            [try syncLine(syncAsset("old")), try syncLine(syncRecord("SyncCompleteV1"))],
            [try syncLine(syncRecord("SyncResetV1", "reset"))],
            [try syncLine(syncAsset("new")), Data("{\"type\":".utf8)]
        ])
        let client = RemoteSyncClient(store: store, transport: transport, indexBridge: bridge)
        _ = try await client.catchUp(scope: syncScope)
        do { _ = try await client.catchUp(scope: syncScope); XCTFail() } catch {}
        let old = try await store.remoteAsset("old", scope: syncScope)
        let new = try await store.remoteAsset("new", scope: syncScope)
        XCTAssertNotNil(old); XCTAssertNil(new)
        let complete = try await store.isCaughtUp(scope: syncScope)
        XCTAssertFalse(complete)
    }

    func testSessionCheckpointIsolationRetainsAccountDeletionHistory() async throws {
        let store = try syncStore()
        try await store.apply(batch: RemoteSyncBatch(records: [try syncRecord("AssetDeleteV1", "1", ["assetId": "a"])]), scope: syncScope)
        let relogin = SyncScope(serverIdentity: "fixed-server", accountID: "owner", loginSessionKey: "session-b")
        let removed = try await store.isRemoteDeleted("a", scope: relogin)
        let pending = try await store.pending(scope: relogin)
        XCTAssertTrue(removed); XCTAssertTrue(pending.isEmpty)
        let other = SyncScope(serverIdentity: "fixed-server", accountID: "other", loginSessionKey: "session-b")
        let isolated = try await store.isRemoteDeleted("a", scope: other)
        XCTAssertFalse(isolated)
    }

    func testDuplicateEventsHaveSameDurableResult() async throws {
        let store = try syncStore()
        let batch = RemoteSyncBatch(records: [try syncAsset("a", deleted: true)])
        try await store.apply(batch: batch, scope: syncScope)
        try await store.apply(batch: batch, scope: syncScope)
        let removed = try await store.isRemoteDeleted("a", scope: syncScope)
        XCTAssertTrue(removed)
    }

    func testAPIKeySelectsCompatibilityWithoutSessionEndpoint() async throws {
        let transport = SyncFixtureTransport([])
        let client = RemoteSyncClient(store: try syncStore(), transport: transport, indexBridge: SyncFixtureBridge(), credential: .apiKey)
        do { _ = try await client.catchUp(scope: syncScope); XCTFail() } catch {
            XCTAssertEqual(error as? RemoteSyncError, .compatibilityRequired)
        }
        let resets = await transport.resets
        XCTAssertTrue(resets.isEmpty)
    }
}

extension IncrementalSyncTests {
    func testMoreThanOneHundredChangesUseBoundedAcknowledgementBatches() async throws {
        let records = try (0..<205).map { try syncLine(syncAsset("asset-\($0)")) }
        let transport = SyncFixtureTransport([records + [try syncLine(syncRecord("SyncCompleteV1"))]])
        let bridge = SyncFixtureBridge(), store = try syncStore()
        let result = try await RemoteSyncClient(store: store, transport: transport, indexBridge: bridge).catchUp(scope: syncScope)
        XCTAssertEqual(result.changedIDs.count, 205)
        let operations = await bridge.operations
        XCTAssertEqual(operations.count, 205)
    }
    func testUnknownLaterDeltaPreservesPreviousCommittedSnapshot() async throws {
        let transport = SyncFixtureTransport([
            [try syncLine(syncAsset("old")), try syncLine(syncRecord("SyncCompleteV1"))],
            try (0..<100).map { try syncLine(syncAsset("new-\($0)")) } + [Data("{\"type\":\"CriticalV99\",\"ack\":\"unknown\",\"data\":{}}\n".utf8)]
        ])
        let store = try syncStore(), bridge = SyncFixtureBridge()
        let client = RemoteSyncClient(store: store, transport: transport, indexBridge: bridge)
        _ = try await client.catchUp(scope: syncScope)
        do { _ = try await client.catchUp(scope: syncScope); XCTFail() } catch {}
        let new = try await store.remoteAsset("new-0", scope: syncScope)
        XCTAssertNil(new)
    }
    func testSkipRequiresCurrentOwnedChecksumAndNoRemoval() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge()
        let transport = SyncFixtureTransport([[try syncLine(syncAsset("a")), try syncLine(syncRecord("SyncCompleteV1"))]])
        _ = try await RemoteSyncClient(store: store, transport: transport, indexBridge: bridge).catchUp(scope: syncScope)
        let paired = SyncHistoricalPairing(localID: "local", primaryRemoteID: "a", motionRemoteID: nil, primaryChecksum: "c3ludGhldGlj", motionChecksum: nil, isLivePhoto: false, remoteDeleted: false)
        let skip = try await store.canSkipRoutineBackupRecheck(pairing: paired, scope: syncScope)
        XCTAssertTrue(skip)
        try await store.apply(batch: RemoteSyncBatch(records: [try syncRecord("AssetDeleteV1", "3", ["assetId": "a"])]), scope: syncScope)
        let after = try await store.canSkipRoutineBackupRecheck(pairing: paired, scope: syncScope)
        XCTAssertFalse(after)
    }
}

extension IncrementalSyncTests {
    func testLostDerivedSnapshotAfterAckForcesResetAndKeepsHistoricalDeletionProtection() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite")
        let store = try syncStore(file), bridge = SyncFixtureBridge()
        await bridge.seed([SyncHistoricalPairing(localID: "local", primaryRemoteID: "a", motionRemoteID: nil, primaryChecksum: "c3ludGhldGlj", motionChecksum: nil, isLivePhoto: false, remoteDeleted: false)])
        let transport = SyncFixtureTransport([
            [try syncLine(syncAsset("a")), try syncLine(syncRecord("SyncCompleteV1"))],
            [try syncLine(syncRecord("SyncCompleteV1", "2"))]
        ])
        let client = RemoteSyncClient(store: store, transport: transport, indexBridge: bridge)
        _ = try await client.catchUp(scope: syncScope)
        try corruptSyncFixtureDatabase(file, sql: "DELETE FROM sync_state WHERE kind='assets'")
        _ = try await client.catchUp(scope: syncScope)
        let resets = await transport.resets
        XCTAssertEqual(resets, [true, true])
        let protected = try await store.isLocalDeletionProtected("local", scope: syncScope)
        XCTAssertTrue(protected)
    }
}

extension IncrementalSyncTests {
    func testReloginRecoversAccountIndexWorkWithoutAcknowledgingOldSession() async throws {
        let store = try syncStore(), bridge = SyncFixtureBridge(), transport = SyncFixtureTransport([])
        try await store.apply(batch: RemoteSyncBatch(records: [try syncRecord("AssetDeleteV1", "old-session", ["assetId": "gone"])]), scope: syncScope)
        let relogin = SyncScope(serverIdentity: syncScope.serverIdentity, accountID: syncScope.accountID, loginSessionKey: "new-session")
        try await RemoteSyncClient(store: store, transport: transport, indexBridge: bridge).recoverPending(scope: relogin)
        let operations = await bridge.operations
        let acks = await transport.acknowledgements
        XCTAssertTrue(operations.contains(.removed("gone")))
        XCTAssertTrue(acks.isEmpty)
    }
}
