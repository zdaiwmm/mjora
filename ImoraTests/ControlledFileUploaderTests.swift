import XCTest
@testable import Imora

final class ControlledFileUploaderTests: XCTestCase {
    func testSharedUploaderSendsOnlyToBoundRootAndRejectsEveryRedirect() async throws {
        let receiver = try LocalHTTPServer { _ in .init() }
        try await receiver.start()
        defer { receiver.stop() }
        for status in [301, 302, 303, 307, 308] {
            let server = try LocalHTTPServer { _ in .init(status: status, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
            try await server.start()
            let uploader = ControlledFileUploader(apiURL: server.apiURL, token: "fixture-bound-token")
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("synthetic-shared-media".utf8).write(to: file)
            var request = URLRequest(url: server.apiURL.appending(path: "assets")); request.httpMethod = "POST"
            _ = try? await uploader.upload(request, fromFile: file)
            XCTAssertEqual(server.received.count, 1)
            XCTAssertEqual(server.received.first?.headers["authorization"], "Bearer fixture-bound-token")
            XCTAssertTrue(receiver.received.isEmpty)
            request.url = receiver.apiURL.appending(path: "capture")
            do { _ = try await uploader.upload(request, fromFile: file); XCTFail("other origin accepted") } catch {}
            XCTAssertTrue(receiver.received.isEmpty)
            uploader.invalidate(); server.stop()
            try? FileManager.default.removeItem(at: file)
        }
    }

    func testRevokedPersistentAuthorityNeverStartsAQueuedUpload() async throws {
        let server = try LocalHTTPServer { _ in .init() }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let store = ShareCredentialStore(directory: directory)
        let first = ShareCredentialIdentity(apiURL: server.apiURL, token: "first", generation: UUID())
        let next = ShareCredentialIdentity(apiURL: server.apiURL, token: "next", generation: UUID())
        try store.save(next)
        let file = directory.appending(path: "body"); try Data("fixture".utf8).write(to: file)
        let uploader = ControlledFileUploader(apiURL: server.apiURL, token: "first")
        defer { uploader.invalidate() }
        var request = URLRequest(url: server.apiURL.appending(path: "assets")); request.httpMethod = "POST"
        do {
            _ = try await uploader.upload(request, fromFile: file, startAuthorized: { resume in try store.withCurrent(first) { try resume() } })
            XCTFail("old queued account was sent")
        } catch {}
        XCTAssertTrue(server.received.isEmpty)
    }
}
