import AVFoundation
import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import Imora

/// Writes only synthetic assets in the separate Phase 4 native fixture account.
final class Immich341IntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let apiURL: URL
        let email: String
        let password: String
        let ownerID: String
        let stillID: String
        let motionID: String
        let stillChecksum: String
        let motionChecksum: String
        let stillBytes: Int64
        let motionBytes: Int64
    }
    private static func allowed(apiURL: URL, email: String, ownerID: String, stillID: String, motionID: String) -> Bool {
        apiURL.absoluteString == "http://127.0.0.1:33284/api"
            && email.hasSuffix("@imora-phase4-fixture.invalid")
            && UUID(uuidString: ownerID) != nil && UUID(uuidString: stillID) != nil
            && UUID(uuidString: motionID) != nil && stillID != motionID
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
        let url = root.appending(path: "native-integration-fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the dedicated local Immich 3.4.1 iOS fixture first.") }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        guard url.resolvingSymlinksInPath().path == url.path, permissions?.intValue == 0o600 else { throw ServerTrustError.untrustedTarget }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard Self.allowed(apiURL: fixture.apiURL, email: fixture.email, ownerID: fixture.ownerID,
                           stillID: fixture.stillID, motionID: fixture.motionID) else {
            throw ServerTrustError.untrustedTarget
        }
        for name in ["ui-fixture.json", "entry-ui-fixture.json", "legacy-ui-fixture.json"] {
            let other = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: name))) as? [String: Any]
            guard let owner = other?["ownerID"] as? String, UUID(uuidString: owner) != nil, owner != fixture.ownerID else {
                throw ServerTrustError.untrustedTarget
            }
        }
        return fixture
    }

    func testOwnedNativeFixtureGuardRejectsUntrustedDestinations() throws {
        let f = try fixture()
        XCTAssertTrue(Self.allowed(apiURL: f.apiURL, email: f.email, ownerID: f.ownerID, stillID: f.stillID, motionID: f.motionID))
        XCTAssertFalse(Self.allowed(apiURL: URL(string: "http://127.0.0.1:32283/api")!, email: f.email,
            ownerID: f.ownerID, stillID: f.stillID, motionID: f.motionID))
        XCTAssertFalse(Self.allowed(apiURL: f.apiURL, email: "unrelated@example.invalid", ownerID: f.ownerID,
            stillID: f.stillID, motionID: f.motionID))
        XCTAssertFalse(Self.allowed(apiURL: f.apiURL, email: f.email, ownerID: "invalid", stillID: f.stillID, motionID: f.motionID))
    }
    private func checksum(_ hex: String) throws -> String {
        guard hex.count == 40, hex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else { throw ControlledUploadError.unconfirmed }
        let values = Array(hex)
        var data = Data()
        for index in stride(from: 0, to: values.count, by: 2) { data.append(UInt8(String(values[index...index + 1]), radix: 16)!) }
        return data.base64EncodedString()
    }
    private func client(_ fixture: Fixture) async throws -> ImoraClient {
        let login = try await ImoraClient.login(apiURL: fixture.apiURL, email: fixture.email, password: fixture.password)
        guard login.userId == fixture.ownerID else { throw ServerTrustError.untrustedTarget }
        let client = ImoraClient(apiURL: fixture.apiURL, accessToken: login.accessToken)
        guard try await client.currentUser().id == fixture.ownerID else { client.invalidate(); throw ServerTrustError.untrustedTarget }
        return client
    }

    func testActual341ExactPairRepairBulkCheckAndBothOriginalReadbacks() async throws {
        let f = try fixture()
        let client = try await client(f)
        defer { client.invalidate() }
        let user = try await client.currentUser()
        XCTAssertEqual(user.id, f.ownerID)
        let still = try checksum(f.stillChecksum), motion = try checksum(f.motionChecksum)
        let rows = try await client.bulkUploadCheck([.init(id: "still", checksum: still), .init(id: "motion", checksum: motion)])
        let map = try BackupVerifier.validatedResults(items: [.init(id: "still", checksum: still), .init(id: "motion", checksum: motion)], results: rows)
        XCTAssertEqual(map["still"]?.assetId, f.stillID)
        XCTAssertEqual(map["motion"]?.assetId, f.motionID)
        let device = fixtureDevice(id: "fixture-ios-live-photo", live: true)
        let entry = BackupEntry(modificationDate: device.modificationDate, isLivePhoto: true, primaryChecksum: still,
                                primaryRemoteId: f.stillID, motionChecksum: motion, motionRemoteId: f.motionID)
        let proof = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: f.ownerID,
            account: client.serverKey + "|" + f.ownerID, generation: client.context.id, remote: client,
            repairEmptyPair: true, wait: { _ in }, current: { client.context.isActive })
        XCTAssertEqual(proof.livePhotoVideoID, f.motionID)
        let stillReadback = try await client.readbackOriginal(assetID: f.stillID, expected: .init(checksum: still, byteCount: f.stillBytes))
        let motionReadback = try await client.readbackOriginal(assetID: f.motionID, expected: .init(checksum: motion, byteCount: f.motionBytes))
        XCTAssertEqual(stillReadback.byteCount, f.stillBytes)
        XCTAssertEqual(motionReadback.byteCount, f.motionBytes)
    }

    @MainActor
    func testActual341NewUploadAndHeaderDuplicateShortCircuit() async throws {
        let f = try fixture()
        let client = try await client(f)
        defer { client.invalidate() }
        let marker = UUID().uuidString
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            (marker as NSString).draw(at: CGPoint(x: 2, y: 2), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.white])
        }
        let directory = BackgroundUploader.bodyDirectory
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let sourceURL = directory.appending(path: "fixture-source-\(marker).jpg")
        try jpeg.write(to: sourceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sha1 = Data(Insecure.SHA1.hash(data: jpeg)).base64EncodedString()
        let now = Date()
        let upload = AssetUploadRequest(checksum: sha1, deviceAssetId: "fixture-ios-\(marker)", deviceId: "fixture-ios",
            fileCreatedAt: now, fileModifiedAt: now, isFavorite: false, durationMs: 0, livePhotoVideoId: nil)
        let form = upload.form
        let body = try MultipartBody.makeBodyFile(fields: form.fields, fileField: form.fileField, filename: "fixture-\(marker).jpg",
                                                  contentsOf: sourceURL, boundary: form.boundary, in: directory)
        var source = BackupEntry(modificationDate: now, isLivePhoto: false, primaryChecksum: sha1)
        source.primaryByteCount = Int64(jpeg.count)
        let first = try await client.uploadAsset(upload, bodyURL: body, account: client.serverKey + "|" + f.ownerID, source: source)
        XCTAssertFalse(first.isDuplicate)
        let detail = try await client.backupAssetDetail(id: first.id)
        XCTAssertEqual(detail.checksum, sha1)
        XCTAssertEqual(detail.ownerId, f.ownerID)
        // An empty multipart body succeeds only if 3.4.1 recognizes our checksum
        // header and returns the duplicate before reading the form.
        let empty = directory.appending(path: "fixture-empty-\(marker)")
        try Data().write(to: empty)
        let duplicate = try await client.uploadAsset(upload, bodyURL: empty, account: client.serverKey + "|" + f.ownerID, source: source)
        XCTAssertTrue(duplicate.isDuplicate)
        XCTAssertEqual(duplicate.id, first.id)
        let original = try await client.readbackOriginal(assetID: first.id, expected: .init(checksum: sha1, byteCount: Int64(jpeg.count)))
        XCTAssertEqual(original.byteCount, Int64(jpeg.count))
    }

    func testActual341PlaybackDownloadsLocallyAndAVFoundationDecodesFrame() async throws {
        let f = try fixture()
        let client = try await client(f)
        defer { client.invalidate() }
        let start = Date()
        let local = try await client.localMediaFile(client.playbackURL(assetID: f.motionID))
        XCTAssertTrue(local.url.isFileURL)
        let asset = local.makeAsset()
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero)
        XCTAssertGreaterThan(frame.image.width, 0)
        XCTAssertGreaterThan(frame.image.height, 0)
        print("Synthetic 3.4.1 local video preparation seconds: \(Date().timeIntervalSince(start))")
    }
}
