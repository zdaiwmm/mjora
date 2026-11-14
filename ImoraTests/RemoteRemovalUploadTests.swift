import XCTest
@testable import Imora

@MainActor
final class RemoteRemovalUploadTests: XCTestCase {
    func testRemovalAtFinalMultipartHandoffSendsNoPhotoBytes() async throws {
        let server = try LocalHTTPServer { _ in
            .init(body: Data(#"{"id":"synthetic-removed","status":"created"}"#.utf8))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-removal-gate")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        _ = await index.load(serverHost: client.serverKey, userId: "owner", generation: client.context.id)
        let asset = fixtureDevice()
        await index.setHashed(localId: asset.localIdentifier, isLivePhoto: false, primaryChecksum: "synthetic-checksum",
            motionChecksum: nil, modificationDate: asset.modificationDate)
        await index.setPrimaryRemoteId(localId: asset.localIdentifier, "synthetic-removed")
        let entries = await index.allEntries()
        let source = try XCTUnwrap(entries[asset.localIdentifier])
        let body = directory.appending(path: "prepared-body")
        try Data("synthetic-photo-bytes".utf8).write(to: body)
        let upload = AssetUploadRequest(checksum: source.primaryChecksum, deviceAssetId: asset.localIdentifier,
            deviceId: "synthetic-device", fileCreatedAt: asset.modificationDate!, fileModifiedAt: asset.modificationDate!,
            isFavorite: false, durationMs: 0)
        do {
            _ = try await client.uploadAsset(upload, bodyURL: body, account: client.serverKey + "|owner", source: source,
                beforeUpload: {
                    await index.noteRemoteChange(ids: ["synthetic-removed"], change: .deleted, generation: client.context.id)
                    guard await index.permitsUpload(localId: asset.localIdentifier, source: source, generation: client.context.id)
                    else { throw BackupVerificationError.stale }
                })
            XCTFail("A removed copy reached upload")
        } catch {}
        XCTAssertFalse(server.received.contains { $0.method == "POST" && $0.path == "/api/assets" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path), "Only the prepared temporary body should be discarded")
        let finalEntries = await index.allEntries()
        XCTAssertNotNil(finalEntries[asset.localIdentifier])
    }
}
