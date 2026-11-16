import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotoEditInputTests: XCTestCase {
    private func bytes() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: .init(width: 64, height: 32), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 32))
        }.jpegData(compressionQuality: 0.9))
    }

    private func detail(bytes: Data, checksum: String? = nil) throws -> AssetDetail {
        let sha1 = checksum ?? Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
        return try JSONDecoder().decode(AssetDetail.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "ownerId": UUID().uuidString, "type": "IMAGE",
            "originalFileName": "synthetic.jpg", "fileCreatedAt": "2026-11-14T00:00:00Z",
            "localDateTime": "2026-11-14T00:00:00Z", "isFavorite": false, "isTrashed": false,
            "width": 64, "height": 32, "checksum": sha1
        ]))
    }

    func testReopenAfterDisplayRetirementKeepsIndependentPreviewInput() async throws {
        let bytes = try bytes(), detail = try detail(bytes: bytes)
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "input-fixture")
        client.confirmMediaAccount("input-\(UUID())")
        defer { client.invalidate() }
        let first = try await PhotoEditInput.load(detail: detail, client: client)
        XCTAssertEqual(first.image.size.width, 64)
        XCTAssertEqual(first.image.size.height, 32)
        await client.invalidateMediaCache(assetIDs: [detail.id])
        let reopened = try await PhotoEditInput.load(detail: detail, client: client)
        XCTAssertEqual(reopened.image.pngData(), first.image.pngData())
        XCTAssertTrue(reopened.isCurrent)
        XCTAssertEqual(server.received.count, 2)
        XCTAssertTrue(server.received.allSatisfy { $0.path.contains("/thumbnail?") && $0.path.contains("edited=false") && $0.path.contains("&c=") && !$0.path.contains("/original") })
        client.invalidate()
        XCTAssertFalse(first.isCurrent); XCTAssertFalse(reopened.isCurrent)
    }

    func testKnownSourceRevisionSeparatesInputsWithoutChangingTheURL() async throws {
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("synthetic-file".utf8)) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "input-fixture")
        defer { client.invalidate() }
        let url = client.playbackURL(assetID: UUID().uuidString)
        let first = try await client.localMediaFile(url, role: .editInput, contentRevision: "fixed-source-r1")
        let second = try await client.localMediaFile(url, role: .editInput, contentRevision: "fixed-source-r2")
        XCTAssertNotEqual(try first.url, try second.url)
        XCTAssertEqual(server.received.count, 2)
    }

    func testKnownPrivateAssetCannotLoseItsPINFenceWhenLegacyDetailOmitsVisibility() async throws {
        let bytes = try bytes(), detail = try detail(bytes: bytes)
        XCTAssertNil(detail.visibility)
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "input-fixture")
        defer { client.invalidate() }
        do { _ = try await PhotoEditInput.load(detail: detail, client: client, requiresElevation: true); XCTFail("Missing PIN was accepted") }
        catch { XCTAssertTrue(server.received.isEmpty) }
    }

    func testEditInputAndPlaybackNeverShareAFileEvenAtTheSameURL() async throws {
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("synthetic-file".utf8)) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "input-fixture")
        defer { client.invalidate() }
        let url = client.playbackURL(assetID: UUID().uuidString)
        let display = try await client.localMediaFile(url)
        let input = try await client.localMediaFile(url, role: .editInput, contentRevision: "fixed-source-r1")
        XCTAssertNotEqual(try display.url, try input.url)
        XCTAssertEqual(server.received.count, 2)
    }

    func testPrivateCachedFileCannotSurvivePINRevocationOrBeReusedByNewProducer() async throws {
        let server = try LocalHTTPServer { request in
            if request.path == "/api/auth/status" {
                return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
            }
            return .init(headers: ["Content-Type": "video/mp4"], body: Data("private-synthetic-file".utf8))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "private-input-fixture")
        client.confirmMediaAccount("private-input-\(UUID())")
        defer { client.invalidate() }
        _ = try await client.authStatus()
        let lease = try XCTUnwrap(client.lockedMediaLease)
        let url = client.playbackURL(assetID: UUID().uuidString)
        let first = try await client.localMediaFile(url, requiresElevation: true)
        let oldPath = try first.url
        let oldAsset = try first.makeAsset()
        XCTAssertTrue(ControlledMediaFile.isAuthorized(oldAsset))
        client.rejectLockedMediaLease(lease)
        XCTAssertFalse(ControlledMediaFile.isAuthorized(oldAsset))
        XCTAssertThrowsError(try first.url); XCTAssertThrowsError(try first.makeAsset())
        for _ in 0..<100 where FileManager.default.fileExists(atPath: oldPath.path) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path), "Revoked private bytes must leave the file cache")
        _ = try await client.authStatus()
        XCTAssertNotEqual(client.lockedMediaLease?.identity, lease.identity)
        let second = try await client.localMediaFile(url, requiresElevation: true)
        XCTAssertNotEqual(try second.url, oldPath)
        XCTAssertEqual(server.received.filter { $0.path.contains("/video/playback") }.count, 2)
    }
}
