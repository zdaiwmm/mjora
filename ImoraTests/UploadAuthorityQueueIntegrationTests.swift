import XCTest
import Synchronization
@testable import Imora

@MainActor
final class UploadAuthorityQueueIntegrationTests: XCTestCase {
    private enum Outcome: Sendable { case uploaded, removed, paused, failed(String) }

    func testActualMultipartQueueWaitsForReconnectAndUploadsEveryEligibleItem() async throws {
        let entered = expectation(description: "reconnect catchup reached server")
        let release = DispatchSemaphore(value: 0)
        let streams = Mutex(0)
        let recovery = Mutex(false)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/sync/ack" { return .init(status: 204, body: Data()) }
            if request.path == "/api/sync/stream" {
                let round = streams.withLock { $0 += 1; return $0 }
                let recovering = recovery.withLock { $0 }
                if recovering { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
                let asset = recovering
                    ? "{\"type\":\"AssetDeleteV1\",\"ack\":\"AssetDeleteV1|delete\",\"data\":{\"assetId\":\"removed-remote\"}}\n"
                    : "{\"type\":\"AssetV2\",\"ack\":\"AssetV2|initial\",\"data\":{\"id\":\"removed-remote\",\"ownerId\":\"synthetic-owner\",\"checksum\":\"synthetic\"}}\n"
                return .init(body: Data((asset + "{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|\(round)\",\"data\":{}}\n").utf8))
            }
            if request.path == "/api/assets", request.method == "POST" {
                return .init(body: Data(#"{"id":"synthetic-uploaded","status":"created"}"#.utf8))
            }
            return .init(status: 404)
        }
        try await server.start(); defer { release.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        let manager = BackupManager(client: client, index: index, syncStore: store)
        defer { manager.shutdown() }
        manager.userId = "synthetic-owner"; manager.loginSessionKey = "synthetic-login"
        _ = await index.load(serverHost: client.serverKey, userId: "synthetic-owner", generation: client.context.id)
        await index.setHashed(localId: "removed", isLivePhoto: false, primaryChecksum: "synthetic", motionChecksum: nil, modificationDate: nil)
        await index.setPrimaryRemoteId(localId: "removed", "removed-remote")
        try await manager.uploadAuthorization(localID: "initial")()
        let initialRounds = streams.withLock { $0 }
        recovery.withLock { $0 = true }
        manager.noteRemoteConnectionGap()
        var completed: [String] = []
        var removed: [String] = []
        var started: [String] = []
        let ids = ["one", "removed", "three", "four"]
        let queue = Task { @MainActor in
            await BackupUploadScheduler.run(ids, workers: 2, operation: { id in
                started.append(id)
                let authorization = manager.uploadAuthorization(localID: id)
                return {
                    do {
                        let source = BackupEntry(modificationDate: nil, isLivePhoto: false, primaryChecksum: "synthetic")
                        let body = directory.appending(path: id)
                        try Data("synthetic-multipart-body".utf8).write(to: body)
                        let request = AssetUploadRequest(checksum: "synthetic", deviceAssetId: id, deviceId: "synthetic-device",
                            fileCreatedAt: Date(), fileModifiedAt: Date(), isFavorite: false, durationMs: 0)
                        _ = try await client.uploadAsset(request, bodyURL: body, account: client.serverKey + "|synthetic-owner", source: source,
                            beforeUpload: authorization)
                        return Outcome.uploaded
                    } catch is BackupUploadAuthorityPause { return Outcome.paused }
                    catch BackupVerificationError.stale { return Outcome.removed }
                    catch { return Outcome.failed(error.localizedDescription) }
                }
            }, didFinish: { id, outcome in
                switch outcome {
                case .uploaded: completed.append(id); return .proceed
                case .removed: removed.append(id); return .proceed
                case .paused: XCTFail("A healthy pending catchup must wait, not pause"); return .pause
                case .failed(let error): XCTFail(error); return .pause
                }
            })
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(server.received.filter { $0.path == "/api/assets" }.isEmpty,
                      "No multipart bytes may cross the actual beforeUpload barrier while sync is incomplete")
        XCTAssertEqual(started.count, 2)
        release.signal()
        await queue.value
        XCTAssertEqual(Set(completed), Set(ids).subtracting(["removed"]))
        XCTAssertEqual(removed, ["removed"])
        XCTAssertEqual(server.received.filter { $0.path == "/api/assets" }.count, ids.count - 1)
        XCTAssertEqual(streams.withLock { $0 }, initialRounds + 1, "Concurrent handoffs must share one incremental catchup")
        let scope = SyncScope(serverIdentity: client.serverKey, accountID: "synthetic-owner", loginSessionKey: "synthetic-login")
        let protected = try await store.isLocalDeletionProtected("removed", scope: scope)
        let projected = await index.entry(for: "removed")
        XCTAssertTrue(protected)
        XCTAssertEqual(projected?.isUploadBlockedByRemoteRemoval, true)
    }

    func testActualManagerFailurePausesQueueWithoutCountingUnsentAssetsOrRetryStorm() async throws {
        let streams = Mutex(0)
        let fail = Mutex(false)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/sync/ack" { return .init(status: 204, body: Data()) }
            if request.path == "/api/sync/stream" {
                streams.withLock { $0 += 1 }
                if fail.withLock({ $0 }) { return .init(status: 503) }
                return .init(body: Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|ready\",\"data\":{}}\n".utf8))
            }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json")
        let index = BackupIndex(fileURL: file)
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        let manager = BackupManager(client: client, index: index, syncStore: store)
        defer { manager.shutdown() }
        manager.userId = "synthetic-owner"; manager.loginSessionKey = "synthetic-login"
        _ = await index.load(serverHost: client.serverKey, userId: "synthetic-owner", generation: client.context.id)
        let ids = (0..<12).map { "unsent-\($0)" }
        for id in ids {
            await index.setHashed(localId: id, isLivePhoto: false, primaryChecksum: "synthetic", motionChecksum: nil, modificationDate: nil)
        }
        try await manager.uploadAuthorization(localID: "initial")()
        let initialRounds = streams.withLock { $0 }
        fail.withLock { $0 = true }
        manager.noteRemoteConnectionGap()
        var started: [String] = [], completed: [String] = []
        await BackupUploadScheduler.run(ids, workers: 2, operation: { id in
            started.append(id)
            let authorization = manager.uploadAuthorization(localID: id)
            return {
                do { try await authorization(); return Outcome.uploaded }
                catch is BackupUploadAuthorityPause { return Outcome.paused }
                catch { return Outcome.failed(error.localizedDescription) }
            }
        }, didFinish: { id, outcome in
            switch outcome {
            case .uploaded: completed.append(id); return .proceed
            case .paused: return .pause
            default: XCTFail("Recovery failure was misclassified"); return .pause
            }
        })
        XCTAssertEqual(started.count, 2)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(streams.withLock { $0 }, initialRounds + 1)
        do { try await manager.uploadAuthorization(localID: "not-started")(); XCTFail() }
        catch is BackupUploadAuthorityPause {}
        XCTAssertEqual(streams.withLock { $0 }, initialRounds + 1, "A failed generation stays paused until a recovery trigger")
        let flushed = await index.flush(); XCTAssertTrue(flushed)
        let reopened = BackupIndex(fileURL: file)
        _ = await reopened.load(serverHost: client.serverKey, userId: "synthetic-owner", generation: client.context.id)
        let entries = await reopened.allEntries()
        XCTAssertEqual(Set(entries.keys), Set(ids))
        XCTAssertTrue(entries.values.allSatisfy { !$0.hasHistoricalBackup && $0.primaryRemoteId == nil })
    }
}
