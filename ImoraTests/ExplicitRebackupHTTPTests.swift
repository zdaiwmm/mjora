import XCTest
import Synchronization
@testable import Imora

final class ExplicitRebackupHTTPTests: XCTestCase, @unchecked Sendable {
    func testRealHTTPTrashDuplicateContractRestoresOwnedStillAndLivePair() async throws {
        for live in [false, true] {
            let restored = Mutex(false)
            let server = try LocalHTTPServer { request in
                if request.method == "POST", request.path == "/api/assets" {
                    // Immich returns its existing trashed row as a duplicate; upload cannot restore it.
                    return .init(body: Data(#"{"id":"still","status":"duplicate"}"#.utf8))
                }
                if request.path == "/api/trash/restore/assets" {
                    restored.withLock { $0 = true }
                    return .init(status: 204, body: Data())
                }
                guard request.path == "/api/assets/still" || (live && request.path == "/api/assets/motion") else {
                    return .init(status: 404)
                }
                let motion = request.path.hasSuffix("motion")
                var detail: [String: Any] = ["id": motion ? "motion" : "still", "ownerId": "owner",
                    "type": motion ? "VIDEO" : "IMAGE", "checksum": motion ? "motion-sha1" : "still-sha1",
                    "isTrashed": !restored.withLock { $0 }, "isOffline": false]
                if live && !motion { detail["livePhotoVideoId"] = "motion" }
                return .init(body: try! JSONSerialization.data(withJSONObject: detail))
            }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
            defer { client.invalidate() }
            let entry = BackupEntry(modificationDate: nil, isLivePhoto: live, primaryChecksum: "still-sha1", primaryRemoteId: "still",
                motionChecksum: live ? "motion-sha1" : nil, motionRemoteId: live ? "motion" : nil)
            let usable = try await ExplicitRebackupRecovery.restoreIfPresent(entry: entry, ownerID: "owner", remote: client, current: { client.context.isActive })
            XCTAssertTrue(usable)
            let requests = server.received
            let restore = try XCTUnwrap(requests.first { $0.path == "/api/trash/restore/assets" })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: restore.body) as? [String: [String]])
            XCTAssertEqual(body["ids"], live ? ["still", "motion"] : ["still"])
            XCTAssertEqual(requests.filter { $0.path == "/api/trash/restore/assets" }.count, 1)
            XCTAssertFalse(requests.contains { $0.method == "DELETE" || $0.path == "/api/assets" })
        }
    }

    func testPermanentAbsenceAlreadyRestoredForbiddenAndIncompleteOverHTTP() async throws {
        for mode in ["absent", "restored", "forbidden", "incomplete"] {
            let server = try LocalHTTPServer { request in
                if request.path == "/api/trash/restore/assets" { return .init(status: 403) }
                guard mode != "absent", request.path == "/api/assets/still" else { return .init(status: 404) }
                let detail: [String: Any] = ["id": "still", "ownerId": "owner", "type": "IMAGE", "checksum": "still-sha1",
                    "isTrashed": mode != "restored", "isOffline": false, "livePhotoVideoId": "motion"]
                return .init(body: try! JSONSerialization.data(withJSONObject: detail))
            }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
            defer { client.invalidate() }
            let live = mode == "incomplete"
            let entry = BackupEntry(modificationDate: nil, isLivePhoto: live, primaryChecksum: "still-sha1", primaryRemoteId: "still",
                motionChecksum: live ? "motion-sha1" : nil, motionRemoteId: live ? "motion" : nil)
            do {
                let present = try await ExplicitRebackupRecovery.restoreIfPresent(entry: entry, ownerID: "owner", remote: client, current: { true })
                XCTAssertTrue(mode == "absent" || mode == "restored")
                XCTAssertEqual(present, mode == "restored")
            } catch { XCTAssertTrue(mode == "forbidden" || mode == "incomplete", "Unexpected error: \(error)") }
            XCTAssertFalse(server.received.contains { $0.method == "DELETE" || $0.path == "/api/assets" })
            if mode == "incomplete" { XCTAssertFalse(server.received.contains { $0.path.contains("restore") }) }
        }
    }
}
