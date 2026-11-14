import XCTest
import Synchronization
@testable import Imora

final class ShareRecoveryTests: XCTestCase {
    func testForegroundRecoveryFindsDescriptorsCreatedAfterTheInitialEmptyCheck() async throws {
        let server = try LocalHTTPServer { request in
            let body: String
            if request.path == "/api/users/me" { body = "{\"id\":\"owner\"}" }
            else if request.method == "POST" { body = "{\"id\":\"remote\"}" }
            else { body = "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":false}" }
            return .init(body: Data(body.utf8))
        }
        try await server.start(); defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies")
        try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "fixture-token", generation: UUID())
        let authority = ShareCredentialStore(directory: root.appending(path: "auth"))
        try authority.save(identity)
        let credentials = ShareTransfer.Credentials(identity: identity, token: "fixture-token", deviceId: "fixture")
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let results = Mutex<[ShareQueueResult]>([])
        let coordinator = ShareUploadCoordinator(
            credentials: { (try? authority.load()) == identity ? credentials : nil },
            queueStore: { store },
            startAuthorized: { captured, resume in try authority.withCurrent(captured.identity) { try resume() } },
            report: { result in results.withLock { $0.append(result) } }
        )
        XCTAssertNil(coordinator.resumePending())
        // A different process stages work while the already-running app is away.
        let extensionStore = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let body = bodies.appending(path: "synthetic")
        try Data("synthetic-photo".utf8).write(to: body)
        let record = try extensionStore.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "fixture")))
        // An active extension owns the lease: foregrounding must not duplicate it.
        let lease = try XCTUnwrap(extensionStore.claim(record))
        await coordinator.resumePending()?.value
        XCTAssertTrue(server.received.isEmpty)
        lease.release()
        await coordinator.resumePending()?.value
        XCTAssertEqual(server.received.map(\.path), ["/api/users/me", "/api/assets", "/api/assets/remote"])
        XCTAssertTrue(try store.pending(includeAttention: true).isEmpty)
        XCTAssertEqual(results.withLock { $0.map(\.uploaded) }, [1])
        XCTAssertNil(coordinator.resumePending())
    }

    func testStorageIncludesAttentionAndExhaustedRecordsWithoutDiscardingUnreviewedBodies() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies")
        try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let identity = ShareCredentialIdentity(apiURL: URL(string: "https://fixture.invalid/api")!, token: "fixture", generation: UUID())
        func enqueue(_ name: String) throws -> ShareQueueRecord {
            let body = bodies.appending(path: name)
            try Data(repeating: 1, count: 10).write(to: body)
            return try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: name, checksum: "fixture", verifiedProduct: nil, transfer: .multipart(boundary: "fixture")))
        }
        let attention = try enqueue("attention")
        try store.markAttention(attention)
        var exhausted = try enqueue("exhausted")
        for _ in 0..<3 { exhausted = try store.started(exhausted) }
        let unknown = bodies.appending(path: "legacy-or-active-extension-body")
        try Data(repeating: 2, count: 7).write(to: unknown)
        XCTAssertTrue(try store.pending().isEmpty)
        let snapshot = try SharePendingStorage.snapshot(store: store)
        XCTAssertEqual(Set(snapshot.records.map(\.id)), Set([attention.id, exhausted.id]))
        XCTAssertEqual(snapshot.knownBytes, 20)
        XCTAssertEqual(snapshot.totalBytes, 27)
        XCTAssertEqual(snapshot.untrackedBytes, 7)
        let unreviewed = try enqueue("arrived-after-confirmation")
        XCTAssertEqual(SharePendingStorage.discard(snapshot.records, store: store), 0)
        XCTAssertEqual(try store.pending(includeAttention: true).map(\.id), [unreviewed.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        // A stale worker cannot recreate a discarded descriptor through a late write.
        try store.markAttention(attention)
        XCTAssertFalse(store.isPending(attention))
        XCTAssertNil(try store.claim(attention, includeAttention: true))
    }

    func testRecoveryDoesNotNotifyAnAccountThatReplacedTheCapturedAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = ShareCredentialStore(directory: root.appending(path: "auth"))
        let server = try LocalHTTPServer { request in
            let body: String
            if request.path == "/api/users/me" { body = "{\"id\":\"owner\"}" }
            else if request.method == "POST" { body = "{\"id\":\"remote\"}" }
            else {
                try? authority.save(nil)
                body = "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":false}"
            }
            return .init(body: Data(body.utf8))
        }
        try await server.start(); defer { server.stop() }
        let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "old-fixture-token", generation: UUID())
        try authority.save(identity)
        let credentials = ShareTransfer.Credentials(identity: identity, token: "old-fixture-token", deviceId: "fixture")
        let bodies = root.appending(path: "bodies")
        try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "synthetic")
        try Data("synthetic-photo".utf8).write(to: body)
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        _ = try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "fixture")))
        let reports = Mutex(0)
        let coordinator = ShareUploadCoordinator(
            credentials: { (try? authority.load()) == identity ? credentials : nil },
            queueStore: { store },
            startAuthorized: { captured, resume in try authority.withCurrent(captured.identity) { try resume() } },
            report: { _ in reports.withLock { $0 += 1 } }
        )
        await coordinator.resumePending()?.value
        XCTAssertEqual(reports.withLock { $0 }, 0)
        XCTAssertEqual(try store.pending(includeAttention: true).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
        XCTAssertNil(coordinator.resumePending())
        XCTAssertTrue(server.received.allSatisfy { $0.headers["authorization"] == "Bearer old-fixture-token" })
    }
}
