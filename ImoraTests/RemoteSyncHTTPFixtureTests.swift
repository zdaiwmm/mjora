import XCTest
import Synchronization
@testable import Imora

final class RemoteSyncHTTPFixtureTests: XCTestCase, @unchecked Sendable {
    /// Shapes transcribed from local Immich 3.4.1 sync.dto.ts and utils/sync.ts.
    private func assetLine(id: String, owner: String, ack: String) throws -> Data {
        let data: [String: Any] = ["id": id, "ownerId": owner, "originalFileName": "synthetic.jpg", "thumbhash": NSNull(),
            "checksum": "c3ludGhldGlj", "fileCreatedAt": "2026-11-14T00:00:00Z", "fileModifiedAt": "2026-11-14T00:00:00Z",
            "createdAt": "2026-11-14T00:00:00Z", "localDateTime": "2026-11-14T00:00:00Z", "duration": NSNull(),
            "type": "IMAGE", "deletedAt": NSNull(), "isFavorite": false, "visibility": "timeline", "livePhotoVideoId": NSNull(),
            "stackId": NSNull(), "libraryId": NSNull(), "width": 10, "height": 10, "isEdited": false]
        var line = try JSONSerialization.data(withJSONObject: ["type": "AssetV2", "ack": ack, "data": data]); line.append(10); return line
    }
    func testImmich341FirstEmptyDeleteAndThirtyDayResetOverRealHTTP() async throws {
        let owner = "00000000-0000-4000-8000-000000000001", asset = "00000000-0000-4000-8000-000000000002"
        let first = try assetLine(id: asset, owner: owner, ack: "AssetV2|100") + Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|101\",\"data\":{}}\n".utf8)
        let empty = Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|102\",\"data\":{}}\n".utf8)
        let deleted = Data("{\"type\":\"AssetDeleteV1\",\"ack\":\"AssetDeleteV1|103\",\"data\":{\"assetId\":\"\(asset)\"}}\n{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|104\",\"data\":{}}\n".utf8)
        let reset = Data("{\"type\":\"SyncResetV1\",\"ack\":\"SyncResetV1|reset\",\"data\":{}}\n".utf8)
        let replies = [first, empty, deleted, reset, empty]
        let cursor = Mutex(0)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/sync/ack" { return .init(status: 204, body: Data()) }
            guard request.path == "/api/sync/stream" else { return .init(status: 404) }
            let reply = cursor.withLock { index in defer { index += 1 }; return replies[min(index, replies.count - 1)] }
            return .init(headers: ["Content-Type": "application/jsonlines+json"], body: reply)
        }
        try await server.start(); defer { server.stop() }
        let http = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-sync-session")
        defer { http.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let scope = SyncScope(serverIdentity: http.serverKey, accountID: owner, loginSessionKey: "persistent-synthetic-session")
        let loaded = await index.load(serverHost: scope.serverIdentity, userId: owner, generation: http.context.id)
        XCTAssertTrue(loaded)
        await index.setHashed(localId: "synthetic-local", isLivePhoto: false, primaryChecksum: "c3ludGhldGlj", motionChecksum: nil, modificationDate: nil)
        await index.setPrimaryRemoteId(localId: "synthetic-local", asset)
        let store = try SyncStateStore(fileURL: directory.appending(path: "state.sqlite"))
        let client = RemoteSyncClient(store: store, transport: ImoraClientRemoteSyncTransport(client: http), indexBridge: BackupIndexSyncBridge(index: index, generation: http.context.id))
        let baseline = try await client.catchUp(scope: scope)
        XCTAssertTrue(baseline.completed); XCTAssertEqual(baseline.changedIDs, [asset])
        let noChanges = try await client.catchUp(scope: scope)
        XCTAssertTrue(noChanges.completed); XCTAssertTrue(noChanges.changedIDs.isEmpty)
        let removal = try await client.catchUp(scope: scope)
        XCTAssertEqual(removal.deletedIDs, [asset])
        let entries = await index.allEntries()
        XCTAssertTrue(entries["synthetic-local"]?.isUploadBlockedByRemoteRemoval == true)
        let rebuild = try await client.catchUp(scope: scope)
        XCTAssertTrue(rebuild.completed); XCTAssertTrue(rebuild.resetOccurred)
        let requests = server.received
        let streamRequests = requests.filter { $0.path == "/api/sync/stream" }
        XCTAssertEqual(streamRequests.count, 5)
        let dto = try XCTUnwrap(JSONSerialization.jsonObject(with: streamRequests[0].body) as? [String: Any])
        XCTAssertEqual(dto["types"] as? [String], ["AssetsV2", "AlbumsV2", "AlbumToAssetsV1"])
        XCTAssertEqual(dto["reset"] as? Bool, true)
        let acks = try requests.filter { $0.path == "/api/sync/ack" }.flatMap { request -> [String] in
            let dto = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            return try XCTUnwrap(dto["acks"] as? [String])
        }
        XCTAssertTrue(acks.contains("SyncResetV1|reset")); XCTAssertTrue(acks.contains("AssetDeleteV1|103"))
        XCTAssertTrue(requests.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-sync-session" })
    }
    func testOnlyExplicitUnsupportedHTTPSelectsCompatibility() async throws {
        for status in [404, 403, 504] {
            let server = try LocalHTTPServer { _ in .init(status: status) }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
            defer { client.invalidate() }
            do {
                _ = try await ImoraClientRemoteSyncTransport(client: client).stream(types: ["AssetsV2"], reset: false)
                XCTFail()
            } catch {
                XCTAssertEqual((error as? RemoteSyncError) == .compatibilityRequired, status == 404)
            }
        }
    }
}
