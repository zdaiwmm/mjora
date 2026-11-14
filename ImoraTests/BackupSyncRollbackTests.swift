import XCTest
import Synchronization
@testable import Imora

@MainActor
final class BackupSyncRollbackTests: XCTestCase {
    private func compatibilitySelected(_ manager: BackupManager) -> Bool {
        Mirror(reflecting: manager).children.first {
            $0.label?.hasSuffix("usesCompatibilityReconciliation") == true
        }?.value as? Bool ?? false
    }

    private func deletion() throws -> RemoteSyncRecord {
        try JSONDecoder().decode(RemoteSyncRecord.self,
            from: Data(#"{"type":"AssetDeleteV1","ack":"AssetDeleteV1|retired","data":{"assetId":"retired"}}"#.utf8))
    }

    func testDisabledFlushesPendingDeletionBeforeEnteringCompatibility() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json")
        let protectedBeforeAck = Mutex(false)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/sync/ack" {
                let root = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let entries = root?["entries"] as? [String: [String: Any]]
                protectedBeforeAck.withLock { $0 = entries?["local"]?["remoteDeletionDetected"] as? Bool == true }
                return .init(status: 204, body: Data())
            }
            if request.path == "/api/sync/stream" {
                return .init(body: Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|ready\",\"data\":{}}\n".utf8))
            }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-rollback")
        defer { client.invalidate() }
        let index = BackupIndex(fileURL: file)
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        let scope = SyncScope(serverIdentity: client.serverKey, accountID: "owner", loginSessionKey: "session")
        _ = await index.load(serverHost: client.serverKey, userId: "owner", generation: client.context.id)
        await index.setHashed(localId: "local", isLivePhoto: false, primaryChecksum: "checksum", motionChecksum: nil, modificationDate: nil)
        await index.setPrimaryRemoteId(localId: "local", "retired")
        try await store.importHistory(index.syncHistory(scope: scope, generation: client.context.id), scope: scope)
        try await store.apply(batch: .init(records: [deletion()]), scope: scope)
        let manager = BackupManager(client: client, index: index, syncStore: store, incrementalSyncEnabled: false)
        defer { manager.shutdown() }
        manager.userId = "owner"; manager.loginSessionKey = "session"
        // Compatibility's existing Photos/connection gates may stop here in a permission-denied
        // simulator. The assertion concerns the production boundary before those operations.
        do { try await manager.uploadAuthorization(localID: "local")() } catch {}
        XCTAssertTrue(protectedBeforeAck.withLock { $0 }, "The old JSON index must carry the deletion before ACK/fallback")
        XCTAssertTrue(compatibilitySelected(manager))
        XCTAssertFalse(server.received.contains { $0.path == "/api/sync/stream" })
        let protected = try await store.isLocalDeletionProtected("local", scope: scope)
        let entry = await index.entry(for: "local")
        XCTAssertTrue(protected)
        XCTAssertEqual(entry?.isUploadBlockedByRemoteRemoval, true)
        XCTAssertFalse(server.received.contains { $0.method == "POST" && $0.path == "/api/assets" })
    }

    func testDisabledFlushOrAcknowledgementFailureNeverEntersCompatibility() async throws {
        for failFlush in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appending(path: "index.json")
            let server = try LocalHTTPServer { _ in .init(status: 503) }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-rollback")
            defer { client.invalidate() }
            let index = BackupIndex(fileURL: file)
            let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
            let scope = SyncScope(serverIdentity: client.serverKey, accountID: "owner", loginSessionKey: "session")
            _ = await index.load(serverHost: client.serverKey, userId: "owner", generation: client.context.id)
            await index.setHashed(localId: "local", isLivePhoto: false, primaryChecksum: "checksum", motionChecksum: nil, modificationDate: nil)
            await index.setPrimaryRemoteId(localId: "local", "retired")
            try await store.importHistory(index.syncHistory(scope: scope, generation: client.context.id), scope: scope)
            try await store.apply(batch: .init(records: [deletion()]), scope: scope)
            if failFlush {
                let flushed = await index.flush(); XCTAssertTrue(flushed)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
            let manager = BackupManager(client: client, index: index, syncStore: store, incrementalSyncEnabled: false)
            defer { manager.shutdown() }
            manager.userId = "owner"; manager.loginSessionKey = "session"
            do { try await manager.uploadAuthorization(localID: "local")(); XCTFail("Rollback must remain paused") }
            catch is BackupUploadAuthorityPause {}
            catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertFalse(compatibilitySelected(manager))
            XCTAssertTrue(server.received.allSatisfy { $0.path == "/api/sync/ack" })
            if failFlush { XCTAssertTrue(server.received.isEmpty) }
            let pending = try await store.pending(scope: scope)
            XCTAssertFalse(pending.isEmpty)
        }
    }

    func testEnabledAuthenticationFailureDoesNotSelectCompatibility() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 403) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-rollback")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        _ = await index.load(serverHost: client.serverKey, userId: "owner", generation: client.context.id)
        let manager = BackupManager(client: client, index: index, syncStore: store, incrementalSyncEnabled: true)
        defer { manager.shutdown() }
        manager.userId = "owner"; manager.loginSessionKey = "session"
        do { try await manager.uploadAuthorization(localID: "local")(); XCTFail() }
        catch let pause as BackupUploadAuthorityPause {
            guard case ImoraError.http(403, _) = pause.underlying else { return XCTFail("Lost authentication failure") }
        } catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertFalse(compatibilitySelected(manager))
        XCTAssertTrue(server.received.allSatisfy { $0.path == "/api/sync/stream" })
    }
}
