import XCTest
import Synchronization
@testable import Imora

@MainActor
final class UploadAuthorityRecoveryTests: XCTestCase {
    func testDeliberateSocketDeactivationDoesNotRevokeUploadAuthority() async {
        let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
        defer { client.invalidate() }
        let hub = RealtimeHub(client: client)
        var gaps = 0
        hub.onBackupConnectionGap = { gaps += 1 }
        hub.setActive(true)
        hub.setActive(false)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(gaps, 0, "App backgrounding intentionally closes the socket; healthy upload authorization must survive")
    }

    func testCancellingPendingSocketHandshakeDoesNotReportTransportGap() async throws {
        let entered = expectation(description: "websocket handshake in progress")
        let release = DispatchSemaphore(value: 0)
        let server = try LocalHTTPServer { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return .init(status: 400)
        }
        try await server.start(); defer { release.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        defer { client.invalidate() }
        let hub = RealtimeHub(client: client)
        var gaps = 0
        hub.onBackupConnectionGap = { gaps += 1 }
        hub.setActive(true)
        await fulfillment(of: [entered], timeout: 5)
        hub.setActive(false)
        release.signal()
        // URLSession's cancellation completion is asynchronous and may be URLError.cancelled.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(gaps, 0)
    }

    func testActualManagerAuthorizationCatchesUpBeforeUnsentItem() async throws {
        let server = try LocalHTTPServer { request in
            if request.path == "/api/sync/ack" { return .init(status: 204, body: Data()) }
            if request.path == "/api/sync/stream" {
                return .init(body: Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|ready\",\"data\":{}}\n".utf8))
            }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        let manager = BackupManager(client: client, index: index, syncStore: store)
        defer { manager.shutdown() }
        manager.userId = "synthetic-owner"
        manager.loginSessionKey = "synthetic-login"
        _ = await index.load(serverHost: client.serverKey, userId: "synthetic-owner", generation: client.context.id)
        let authorize = manager.uploadAuthorization(localID: "unsent")
        // This is the same callback passed by manager to multipart and chunk handoffs.
        do { try await authorize() }
        catch RemoteSyncError.incompleteStream { XCTFail("Pending authority was skipped instead of joining catchup") }
        catch { XCTFail("Unexpected authorization failure: \(error)") }
        XCTAssertGreaterThanOrEqual(server.received.filter { $0.path == "/api/sync/stream" }.count, 1)
    }
}
