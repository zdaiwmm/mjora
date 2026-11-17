import Photos
import SQLite3
import XCTest
@testable import Imora

@MainActor
final class BackupRetryRecoveryTests: XCTestCase {
    func testLocalSnapshotPublishesRemovalProtectionWithThePairingMaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let generation = UUID()
        _ = await index.load(serverHost: "https://fixture.invalid", userId: "owner", generation: generation)
        for id in ["kept", "removed"] {
            await index.setHashed(localId: id, isLivePhoto: false, primaryChecksum: id, motionChecksum: nil, modificationDate: .now)
            await index.setPrimaryRemoteId(localId: id, "remote-" + id)
        }
        await index.noteRemoteChange(ids: ["remote-removed"], change: .deleted, generation: generation)
        let snapshot = await index.localSnapshot()
        XCTAssertEqual(snapshot.remoteRemovedLocalIDs, ["removed"])
        XCTAssertNil(snapshot.localByRemote["remote-removed"])
        XCTAssertEqual(snapshot.localByRemote["remote-kept"], "kept")
        XCTAssertNil(snapshot.remoteByLocal["removed"])
    }

    func testExplicitRetryRechecksCloudAfterALocalAuthorizationFailureIsRepaired() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Grant Photos access to the synthetic unit-test app to exercise explicit backup retry")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let server = try LocalHTTPServer { request in
            switch request.path {
            case "/api/users/me":
                return .init(body: Data(#"{"id":"retry-owner","email":"fixture@example.invalid","name":"Fixture","isAdmin":false}"#.utf8))
            case "/api/sync/stream":
                return .init(body: Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|ready\",\"data\":{}}\n".utf8))
            case "/api/sync/ack": return .init(status: 204, body: Data())
            default: return .init(status: 404)
            }
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-retry")
        defer { client.invalidate() }
        let databaseURL = directory.appending(path: "sync.sqlite")
        let store = try SyncStateStore(fileURL: databaseURL)
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        _ = await index.load(serverHost: client.serverKey, userId: "retry-owner", generation: client.context.id)
        #if DEBUG && targetEnvironment(simulator)
        let fixtureMode = ProcessInfo.processInfo.environment["IMORA_PHASE4_OWNED_FIXTURE"]
        setenv("IMORA_PHASE4_OWNED_FIXTURE", "benchmark", 1)
        #endif
        let manager = BackupManager(client: client, index: index, syncStore: store, incrementalSyncEnabled: true)
        #if DEBUG && targetEnvironment(simulator)
        if let fixtureMode { setenv("IMORA_PHASE4_OWNED_FIXTURE", fixtureMode, 1) }
        else { unsetenv("IMORA_PHASE4_OWNED_FIXTURE") }
        #endif
        defer { manager.shutdown() }
        manager.userId = "retry-owner"; manager.loginSessionKey = "synthetic-session"
        do { try await manager.uploadAuthorization(localID: "synthetic-local")() }
        catch { return XCTFail("Initial healthy authorization failed: \(error)") }

        // A storage fault after catch-up must stop new photo bytes. Repairing
        // storage alone does not grant upload authority; explicit retry rechecks it.
        try execute("ALTER TABLE sync_state RENAME TO sync_state_unavailable", at: databaseURL)
        do {
            try await manager.uploadAuthorization(localID: "synthetic-local")()
            XCTFail("Unavailable local authority storage must pause upload")
        } catch is BackupUploadAuthorityPause { }
        try execute("ALTER TABLE sync_state_unavailable RENAME TO sync_state", at: databaseURL)
        let roundsBeforeRetry = server.received.filter { $0.path == "/api/sync/stream" }.count
        let outcome: BulkBackupOutcome
        do { outcome = try await manager.backUp(localIdentifiers: []) }
        catch { return XCTFail("Explicit empty retry failed: \(error)") }
        XCTAssertEqual(outcome, BulkBackupOutcome())
        do { try await manager.uploadAuthorization(localID: "synthetic-local")() }
        catch { return XCTFail("Repaired authority stayed paused after explicit retry: \(error)") }
        XCTAssertGreaterThan(server.received.filter { $0.path == "/api/sync/stream" }.count, roundsBeforeRetry)
        XCTAssertFalse(server.received.contains { $0.path == "/api/assets" }, "An empty retry must never read or send originals")
    }

    private func execute(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            throw RemoteSyncError.unsafeHistory
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncError.unsafeHistory
        }
    }
}
