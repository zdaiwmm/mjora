import XCTest
@testable import Imora

final class ShareQueueRunnerTests: XCTestCase {
    func testShareUsesOfficialHeaderAndVerifiesAcknowledgedAssetBeforeRemovingStagedCopy() async throws {
        let server = try LocalHTTPServer { request in
            let body: String
            if request.path == "/api/users/me" { body = "{\"id\":\"owner\"}" }
            else if request.method == "POST" { body = "{\"id\":\"remote\",\"status\":\"created\"}" }
            else { body = "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":false}" }
            return .init(headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        try await server.start(); defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies"); try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "body"); try Data("synthetic-shared-file".utf8).write(to: body)
        let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "fixture-share-token", generation: UUID())
        let authority = ShareCredentialStore(directory: root.appending(path: "auth")); try authority.save(identity)
        let credentials = ShareTransfer.Credentials(identity: identity, token: "fixture-share-token", deviceId: "fixture-device")
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let record = try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture")))
        let result = await ShareQueueRunner.run([record], store: store, credentials: credentials, startAuthorized: { resume in try authority.withCurrent(identity) { try resume() } })
        XCTAssertEqual(result.uploaded, 1); XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(server.received.map(\.path), ["/api/users/me", "/api/assets", "/api/assets/remote"])
        XCTAssertEqual(server.received[1].headers["x-immich-checksum"], "fixture-sha1")
        XCTAssertTrue(try store.pending(includeAttention: true).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }

    func testAccountSwitchAfterReadStopsPhotoUploadWithoutUsingNextToken() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = ShareCredentialStore(directory: root.appending(path: "auth"))
        let server = try LocalHTTPServer { _ in
            try? authority.save(nil)
            return .init(body: Data("{\"id\":\"owner\"}".utf8))
        }
        try await server.start(); defer { server.stop() }
        let bodies = root.appending(path: "bodies"); try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "body"); try Data("synthetic-file".utf8).write(to: body)
        let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "old-token", generation: UUID()); try authority.save(identity)
        let credentials = ShareTransfer.Credentials(identity: identity, token: "old-token", deviceId: "fixture-device")
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let record = try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture")))
        let result = await ShareQueueRunner.run([record], store: store, credentials: credentials, startAuthorized: { resume in try authority.withCurrent(identity) { try resume() } })
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" && $0.headers["authorization"] == "Bearer old-token" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
    }
}

extension ShareQueueRunnerTests {
    func testSharedDuplicateRequiresExactOwnerTypeChecksumAndAvailableState() async throws {
        let values = [
            "{\"id\":\"remote\",\"ownerId\":\"other\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":false}",
            "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"VIDEO\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":false}",
            "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"wrong\",\"isTrashed\":false,\"isOffline\":false}",
            "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":true,\"isOffline\":false}",
            "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false,\"isOffline\":true}",
            "{\"id\":\"remote\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture-sha1\",\"isTrashed\":false}"
        ]
        for value in values {
            let body = Data(value.utf8)
            let server = try LocalHTTPServer { request in .init(body: request.path == "/api/users/me" ? Data("{\"id\":\"owner\"}".utf8) : body) }
            try await server.start()
            let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "fixture-token", generation: UUID())
            let credentials = ShareTransfer.Credentials(identity: identity, token: "fixture-token", deviceId: "fixture-device")
            do {
                try await ShareQueueRunner.verifyExisting(assetID: "remote", checksum: "fixture-sha1", mediaType: "IMAGE", credentials: credentials, startAuthorized: { try $0() })
                XCTFail("unverified duplicate was accepted")
            } catch {}
            server.stop()
        }
    }
}

extension ShareQueueRunnerTests {
    func testCancellationWhileAuthorizationIsBlockedCannotResumeARequest() async throws {
        let server = try LocalHTTPServer { _ in .init(body: Data("{}".utf8)) }
        try await server.start(); defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies"); try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "body"); try Data("synthetic".utf8).write(to: body)
        let identity = ShareCredentialIdentity(apiURL: server.apiURL, token: "fixture", generation: UUID())
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let cancellingProcess = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let record = try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture")))
        let credentials = ShareTransfer.Credentials(identity: identity, token: "fixture", deviceId: "fixture")
        let result = await ShareQueueRunner.run([record], store: store, credentials: credentials, startAuthorized: { resume in
            // Cancellation wins while this worker is awaiting authority.
            try cancellingProcess.cancel(record)
            try resume()
        })
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertTrue(server.received.isEmpty)
    }
}
