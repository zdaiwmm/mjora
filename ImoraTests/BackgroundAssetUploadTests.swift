import CryptoKit
import Photos
import Synchronization
import UIKit
import XCTest
@testable import Imora

@MainActor
final class BackgroundAssetUploadTests: XCTestCase {
    func testFullStagingQueueFallsBackToVerifiedMultipartBackup() async throws {
        try await backUp(stagingQueueFull: true)
    }

    func testFinalAcknowledgementCompletesBackupWithoutAnotherStatusRequest() async throws {
        try await backUp(stagingQueueFull: false)
    }

    private func backUp(stagingQueueFull: Bool) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Grant Photos access on the synthetic backup simulator")
        }
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(withCompressionQuality: 0.6) { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let createdID = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: .photo, data: jpeg, options: nil)
            createdID.withLock { $0 = creation.placeholderForCreatedAsset?.localIdentifier }
        }
        let localID = try XCTUnwrap(createdID.withLock { $0 })
        let digest = try await PhotoLibraryService.hash(localIdentifier: localID, includeMotion: false)
        let size = digest.primaryBytes
        let uploadID = String(repeating: "a", count: 64)
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let staging = "/api/assets/background-uploads"
        let status = "\(staging)/\(uploadID)/status"
        let part = "\(staging)/\(uploadID)/parts/0"
        let completed = #"{"id":"synthetic-uploaded","status":"created"}"#
        let openState = #"{"uploadId":"\#(uploadID)","offset":0,"size":\#(size),"partBytes":8388608,"key":"\#(key)","capability":"synthetic-staging"}"#
        let staged = Mutex(false)
        let finalReads = Mutex(0)
        let server = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/users/me"):
                return .init(body: Data(#"{"id":"synthetic-owner","email":"fixture@example.invalid","name":"Fixture","isAdmin":false}"#.utf8))
            case ("GET", "/api/server/version"):
                return .init(body: Data(#"{"major":3,"minor":4,"patch":1}"#.utf8))
            case ("GET", "/api/server/features"):
                return .init(body: Data(#"{"backgroundUploadsV1":true}"#.utf8))
            case ("POST", "/api/sync/stream"):
                return .init(body: Data("{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|ready\",\"data\":{}}\n".utf8))
            case ("POST", "/api/sync/ack"):
                return .init(status: 204, body: Data())
            case ("POST", staging):
                if stagingQueueFull {
                    return .init(status: 400, body: Data(#"{"message":"Too many unfinished background uploads"}"#.utf8))
                }
                return .init(body: Data(openState.utf8))
            case ("PUT", part) where !stagingQueueFull:
                staged.withLock { $0 = true }
                return .init(status: 204, body: Data())
            case ("POST", status) where !stagingQueueFull:
                guard staged.withLock({ $0 }) else { return .init(body: Data(openState.utf8)) }
                let first = finalReads.withLock { count in count += 1; return count == 1 }
                guard first else { return .init(status: 400, body: Data(#"{"message":"Redundant final status request"}"#.utf8)) }
                return .init(body: Data(#"{"result":\#(completed)}"#.utf8))
            case ("POST", "/api/assets") where stagingQueueFull:
                return .init(body: Data(completed.utf8))
            case ("GET", "/api/assets/synthetic-uploaded"):
                return .init(body: Data(#"{"id":"synthetic-uploaded","ownerId":"synthetic-owner","type":"IMAGE","checksum":"\#(digest.primary)","isTrashed":false,"isOffline":false}"#.utf8))
            default:
                return .init(status: 404)
            }
        }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-backup")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let store = try SyncStateStore(fileURL: directory.appending(path: "sync.sqlite"))
        let backup = BackupManager(client: client, index: index, syncStore: store, incrementalSyncEnabled: true)
        backup.loginSessionKey = "synthetic-login"
        defer { backup.shutdown() }

        let result: String
        do {
            result = try await backup.backUp(localIdentifier: localID)
        } catch SingleAssetBackupError.failed(let reason) {
            return XCTFail(reason)
        }
        let entry = await index.entry(for: localID)
        XCTAssertEqual(result, "synthetic-uploaded")
        XCTAssertEqual(entry?.isBackedUp, true)
        XCTAssertEqual(server.received.filter { $0.path == staging }.count, 1)
        let multipartRequests = server.received.filter { $0.path == "/api/assets" }
        XCTAssertEqual(multipartRequests.count, stagingQueueFull ? 1 : 0)
        if let multipart = multipartRequests.first {
            let contentType = try XCTUnwrap(multipart.headers["content-type"])
            let prefix = "multipart/form-data; boundary="
            XCTAssertTrue(contentType.hasPrefix(prefix))
            let boundary = contentType.dropFirst(prefix.count)
            let fileHeader = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
            let start = try XCTUnwrap(multipart.body.range(of: fileHeader)).upperBound
            let end = try XCTUnwrap(multipart.body.range(of: Data("\r\n--\(boundary)--\r\n".utf8))).lowerBound
            let original = multipart.body.subdata(in: start..<end)
            XCTAssertEqual(original.count, Int(size))
            XCTAssertEqual(Data(Insecure.SHA1.hash(data: original)).base64EncodedString(), digest.primary)
        }
        XCTAssertEqual(finalReads.withLock { $0 }, stagingQueueFull ? 0 : 1)
    }
}
