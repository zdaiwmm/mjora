import XCTest
@testable import Imora

final class ShareQueueTests: XCTestCase {
    func testRecoveryRecordContainsNoTokenAndClaimsPreventDuplicateWorkers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies")
        try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "body"); try Data("fixture-photo".utf8).write(to: body)
        let identity = ShareCredentialIdentity(apiURL: URL(string: "https://fixture.invalid/api")!, token: "private-fixture-token", generation: UUID())
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let record = ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture"))
        let queued = try store.enqueue(record)
        XCTAssertEqual(try store.pending().map(\.id), [queued.id])
        let lease = try XCTUnwrap(try store.claim(queued))
        XCTAssertNil(try store.claim(queued), "two workers acquired the same durable file")
        let request = try queued.request(token: "private-fixture-token")
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.invalid/api/assets")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-immich-checksum"), "fixture-sha1")
        XCTAssertThrowsError(try queued.request(token: "next-account-token"))
        lease.release()
        XCTAssertNotNil(try store.claim(queued))
        for file in try FileManager.default.contentsOfDirectory(at: root.appending(path: "queue"), includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("private-fixture-token".utf8)))
        }
        try store.remove(queued)
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }

    func testQueueRejectsEscapedBodyPathsAndNeverDeletesOutsideItsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProtectedTemporaryFiles.prepareDirectory(root)
        let outside = root.appending(path: "outside"); try Data("fixture".utf8).write(to: outside)
        let bodies = root.appending(path: "bodies")
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let identity = ShareCredentialIdentity(apiURL: URL(string: "https://fixture.invalid/api")!, token: "fixture", generation: UUID())
        let record = ShareQueueRecord(identity: identity, bodyPath: outside.path, filename: "fixture.jpg", checksum: "fixture-sha1", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture"))
        XCTAssertThrowsError(try store.enqueue(record))
        XCTAssertThrowsError(try store.remove(record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

extension ShareQueueTests {
    func testCancelledRecordCannotBeRecreatedByLateWorker() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bodies = root.appending(path: "bodies"); try ProtectedTemporaryFiles.prepareDirectory(bodies)
        let body = bodies.appending(path: "body"); try Data("fixture-photo".utf8).write(to: body)
        let identity = ShareCredentialIdentity(apiURL: URL(string: "https://fixture.invalid/api")!, token: "fixture", generation: UUID())
        let store = ShareQueueStore(directory: root.appending(path: "queue"), bodyDirectory: bodies)
        let record = try store.enqueue(ShareQueueRecord(identity: identity, bodyPath: body.path, filename: "fixture.jpg", checksum: "sha1", verifiedProduct: nil, transfer: .multipart(boundary: "imora-fixture")))
        let lease = try XCTUnwrap(try store.claim(record))
        defer { lease.release() }
        try store.cancel(record)
        XCTAssertThrowsError(try store.started(record))
        XCTAssertFalse(store.isPending(record))
        XCTAssertTrue(try store.pending(includeAttention: true).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }
}
