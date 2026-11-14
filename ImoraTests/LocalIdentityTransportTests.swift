import CryptoKit
import XCTest
@testable import Imora

@MainActor
final class LocalIdentityTransportTests: XCTestCase {
    private let external = URL(string: "https://fixture.invalid/api")!

    private func select(_ identity: LocalServerIdentity, for externalURL: URL? = nil) throws {
        let external = externalURL ?? self.external
        var config = LocalServerConfig(server: external, apiURL: identity.apiURL)
        config.identity = identity
        UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "imora.localServer")
        ServerRoute.use(local: identity.apiURL, external: external, allowsFallback: false, identity: identity)
    }

    func testCanonicalClientMultipartUploadReachesOnlyPinnedLANAndReceiptPreservesVerifiedCount() async throws {
        let saved = UserDefaults.standard.data(forKey: "imora.localServer")
        defer { ServerRoute.use(local: nil, external: nil); UserDefaults.standard.set(saved, forKey: "imora.localServer") }
        let externalSink = try LocalHTTPServer { _ in .init(status: 500) }
        try await externalSink.start(); defer { externalSink.stop() }
        let bytes = Data("synthetic multipart original".utf8)
        let checksum = Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
        let local = try LocalTLSServer { request in
            switch request.path {
            case "/api/server/version":
                return .init(body: Data("{\"major\":3,\"minor\":4,\"patch\":1,\"product\":\"imora\",\"features\":[]}".utf8))
            case "/api/assets":
                return .init(body: Data("{\"id\":\"multipart-still\",\"status\":\"created\"}".utf8))
            case "/api/assets/multipart-still":
                return .init(body: Data("{\"id\":\"multipart-still\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"\(checksum)\",\"isTrashed\":false,\"isOffline\":false}".utf8))
            default: return .init(body: Data("{}".utf8))
            }
        }
        try await local.start(); defer { local.stop() }
        try select(LocalServerIdentity(apiURL: local.apiURL, rootCertificateDER: LocalTLSFixtures.root), for: externalSink.apiURL)
        let client = ImoraClient(apiURL: externalSink.apiURL, accessToken: "synthetic-multipart-token")
        defer { client.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appending(path: "synthetic-original")
        try bytes.write(to: sourceFile)
        let asset = fixtureDevice()
        let upload = AssetUploadRequest(checksum: checksum, deviceAssetId: asset.localIdentifier,
            deviceId: "synthetic-device", fileCreatedAt: asset.modificationDate!, fileModifiedAt: asset.modificationDate!,
            isFavorite: false, durationMs: 0)
        let form = upload.form
        let body = try MultipartBody.makeBodyFile(fields: form.fields, fileField: form.fileField,
            filename: "synthetic-original.jpg", contentsOf: sourceFile, boundary: form.boundary, in: directory)
        let expectedBody = try Data(contentsOf: body)
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        _ = await index.load(serverHost: client.serverKey, userId: "owner", generation: client.context.id)
        await index.setHashed(localId: asset.localIdentifier, isLivePhoto: false, primaryChecksum: checksum,
            motionChecksum: nil, modificationDate: asset.modificationDate)
        let sourceValue = await index.entry(for: asset.localIdentifier)
        let source = try XCTUnwrap(sourceValue)
        let account = client.serverKey + "|owner"
        let result = try await client.uploadAsset(upload, bodyURL: body, account: account, source: source)
        XCTAssertEqual(result.id, "multipart-still")
        let posts = local.received.filter { $0.method == "POST" && $0.path == "/api/assets" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.body, expectedBody)
        XCTAssertEqual(posts.first?.headers["content-type"], MultipartBody.contentType(boundary: form.boundary))
        XCTAssertEqual(posts.first?.headers["authorization"], "Bearer synthetic-multipart-token")
        XCTAssertTrue(externalSink.received.isEmpty, "the canonical external listener must receive no requests")
        let journal = UploadJournal()
        let receipt = try XCTUnwrap(journal.receipts().first { $0.ticket.contextID == client.context.id && $0.remoteId == result.id })
        defer { journal.acknowledge(receipt.ticket) }
        let accepted = await index.applyReceipt(receipt)
        XCTAssertTrue(accepted)
        let before = await index.libraryStatus(for: [asset])
        XCTAssertEqual(before.backedUp, 0, "a transport receipt alone is not verification")
        let candidateValue = await index.entry(for: asset.localIdentifier)
        let candidate = try XCTUnwrap(candidateValue)
        let proof = try await BackupVerifier.verify(asset: asset, entry: candidate, ownerID: "owner", account: account,
            generation: client.context.id, remote: client, current: { true })
        let recorded = await index.recordProof(localId: asset.localIdentifier, source: candidate, proof: proof)
        XCTAssertTrue(recorded)
        _ = await index.applyReceipt(receipt)
        let after = await index.libraryStatus(for: [asset])
        XCTAssertEqual(after.backedUp, 1)
        XCTAssertEqual(after.pending, 0)
        XCTAssertTrue(externalSink.received.isEmpty, "verification must also stay on the pinned local listener")
    }

    func testAPIReadbackMediaAndNukeUsePinnedPoolAndChangedPinCannotReuseIt() async throws {
        let saved = UserDefaults.standard.data(forKey: "imora.localServer")
        defer {
            ServerRoute.use(local: nil, external: nil)
            UserDefaults.standard.set(saved, forKey: "imora.localServer")
            ImageLoader.shared.configure(client: nil)
        }
        let server = try LocalTLSServer { request in
            if request.path == "/api/assets/still" {
                return .init(body: Data("{\"id\":\"still\",\"ownerId\":\"owner\",\"type\":\"IMAGE\",\"checksum\":\"fixture\",\"isTrashed\":false,\"isOffline\":false}".utf8))
            }
            return .init(headers: ["Content-Type": "video/mp4"], body: Data("abc".utf8))
        }
        try await server.start(); defer { server.stop() }
        let identity = LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.root)
        try select(identity)
        let client = ImoraClient(apiURL: external, accessToken: "synthetic-local-token")
        defer { client.invalidate() }
        let request = try client.authorizedRequest(url: external.appending(path: "assets/still"))
        XCTAssertEqual(request.url, server.apiURL.appending(path: "assets/still"))
        let oldPool = try client.transportSession(for: request)
        let detail = try await client.backupAssetDetail(id: "still")
        XCTAssertEqual(detail.id, "still")
        let digest = ResourceDigest(checksum: "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=", byteCount: 3)
        let readback = try await client.readbackOriginal(assetID: "original", expected: digest)
        XCTAssertEqual(readback, digest)
        let media = try await client.localMediaFile(client.playbackURL(assetID: "movie"))
        XCTAssertEqual(try Data(contentsOf: media.url), Data("abc".utf8))
        ImageLoader.shared.configure(client: client)
        // Deliberately undecodable bytes: receipt, rather than image decoding,
        // is the contract this transport regression checks.
        _ = try? await ImageLoader.shared.image(for: client.thumbnailURL(assetID: "image-before-pin-change"), targetPixelSize: 32)
        XCTAssertTrue(server.received.contains { $0.path.contains("image-before-pin-change") })
        XCTAssertTrue(server.received.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-local-token" })
        let before = server.received.count
        try select(LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.other))
        XCTAssertFalse(oldPool === (try client.transportSession(for: request)))
        do { _ = try await client.backupAssetDetail(id: "after-pin-change"); XCTFail("wrong pin reached API") } catch {}
        _ = try? await ImageLoader.shared.image(for: client.thumbnailURL(assetID: "image-after-pin-change"), targetPixelSize: 32)
        XCTAssertEqual(server.received.count, before)
    }

    func testProcessUploadAndWebSocketAuthenticateOnlyWithEnrolledCA() async throws {
        let saved = UserDefaults.standard.data(forKey: "imora.localServer")
        defer { ServerRoute.use(local: nil, external: nil); UserDefaults.standard.set(saved, forKey: "imora.localServer") }
        let server = try LocalTLSServer { _ in .init(body: Data("{\"id\":\"uploaded\",\"status\":\"created\"}".utf8)) }
        try await server.start(); defer { server.stop() }
        try select(LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.root))
        let client = ImoraClient(apiURL: external, accessToken: "synthetic-transfer-token")
        defer { client.invalidate() }
        let request = try client.authorizedRequest(url: external.appending(path: "assets"), method: "POST")
        let directory = BackgroundUploader.bodyDirectory
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let source = BackupEntry(modificationDate: nil, isLivePhoto: false, primaryChecksum: "fixture")
        func upload() async throws {
            let file = directory.appending(path: "tls-fixture-\(UUID().uuidString)")
            try Data("synthetic-body".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let ticket = BackgroundUploader.Ticket(account: "tls-fixture", localId: UUID().uuidString, isMotion: false, bodyPath: file.path, source: source)
            _ = try await BackgroundUploader.shared.upload(request, fromFile: file, ticket: ticket, context: client.context, onProgress: nil)
        }
        try await upload()
        XCTAssertEqual(server.received.filter { $0.method == "POST" }.count, 1)
        let hub = RealtimeHub(client: client)
        hub.setActive(true)
        for _ in 0..<100 where !server.received.contains(where: { $0.path.contains("socket.io") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        hub.shutdown()
        XCTAssertTrue(server.received.contains { $0.path.contains("socket.io") && $0.headers["authorization"] == "Bearer synthetic-transfer-token" })
        try select(LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.other))
        let before = server.received.count
        do { try await upload(); XCTFail("wrong pin reached upload") } catch {}
        XCTAssertEqual(server.received.count, before)
    }
}
