import XCTest
@testable import Imora

final class NetworkBoundaryTests: XCTestCase {
    func testLoginNeverFollowsRedirects() async throws {
        let receiver = try LocalHTTPServer { _ in .init() }
        try await receiver.start()
        defer { receiver.stop() }
        for status in [301, 302, 303, 307, 308] {
            let source = try LocalHTTPServer { _ in .init(status: status, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
            try await source.start()
            _ = try? await ImoraClient.login(apiURL: source.apiURL, email: "synthetic@example.invalid", password: "synthetic-password")
            XCTAssertEqual(source.received.count, 1)
            XCTAssertEqual(receiver.received.count, 0, "login followed HTTP \(status)")
            source.stop()
        }
    }

    func testProfileUploadNeverReplaysBodyOrTokenAcrossPorts() async throws {
        let receiver = try LocalHTTPServer { _ in .init() }
        try await receiver.start()
        defer { receiver.stop() }
        for status in [301, 302, 303, 307, 308] {
            let source = try LocalHTTPServer { _ in .init(status: status, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
            try await source.start()
            let client = ImoraClient(apiURL: source.apiURL, accessToken: "synthetic-token")
            _ = try? await client.setProfileImage(data: Data("synthetic-photo".utf8), filename: "fixture.jpg", mimeType: "image/jpeg")
            XCTAssertEqual(source.received.first?.headers["authorization"], "Bearer synthetic-token")
            XCTAssertEqual(receiver.received.count, 0, "profile followed HTTP \(status)")
            source.stop()
        }
    }
}

extension NetworkBoundaryTests {
    func testImageLoaderRejectsOldURLAfterSameServerAccountSwitch() async throws {
        let source = try LocalHTTPServer { _ in .init(body: Data("not-an-image".utf8)) }
        try await source.start()
        defer { source.stop() }
        let first = ImoraClient(apiURL: source.apiURL, accessToken: "old-image-token")
        let next = ImoraClient(apiURL: source.apiURL, accessToken: "new-image-token")
        let queued = first.thumbnailURL(assetID: "synthetic-queued")
        ImageLoader.shared.configure(client: first)
        ImageLoader.shared.configure(client: next)
        _ = try? await ImageLoader.shared.image(for: queued, targetPixelSize: 64)
        XCTAssertTrue(source.received.isEmpty, "old queue was sent after account switch")
        _ = try? await ImageLoader.shared.image(for: next.thumbnailURL(assetID: "synthetic-new"), targetPixelSize: 64)
        XCTAssertEqual(source.received.last?.headers["authorization"], "Bearer new-image-token")
        ImageLoader.shared.configure(client: nil)
        let before = source.received.count
        _ = try? await ImageLoader.shared.image(for: next.thumbnailURL(assetID: "after-logout"), targetPixelSize: 64)
        XCTAssertEqual(source.received.count, before)
    }

    func testReadOnlyAPIAllowsInternalRedirectButBlocksRootEscape() async throws {
        let source = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(status: 302, headers: ["Location": "/api/profile"]) }
            return .init(body: Data("{\"id\":\"synthetic\"}".utf8))
        }
        try await source.start()
        defer { source.stop() }
        let client = ImoraClient(apiURL: source.apiURL, accessToken: "read-token")
        _ = try? await client.currentUser()
        XCTAssertEqual(source.received.map(\.path), ["/api/users/me", "/api/profile"])
        XCTAssertEqual(source.received.last?.headers["authorization"], "Bearer read-token")
    }
}

extension NetworkBoundaryTests {
    func testControlledMediaDownloadKeepsBytesLocalAndRejectsPlaylist() async throws {
        let source = try LocalHTTPServer { request in
            if request.path.contains("playlist") {
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U\nhttps://example.invalid/secret".utf8))
            }
            return .init(headers: ["Content-Type": "video/mp4"], body: Data("synthetic-video".utf8))
        }
        try await source.start()
        defer { source.stop() }
        let client = ImoraClient(apiURL: source.apiURL, accessToken: "media-token")
        let file = try await client.localMediaFile(client.playbackURL(assetID: "fixture"))
        XCTAssertTrue(try file.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: file.url), Data("synthetic-video".utf8))
        XCTAssertEqual(source.received.last?.headers["authorization"], "Bearer media-token")
        do {
            _ = try await client.localMediaFile(client.playbackURL(assetID: "playlist"))
            XCTFail("playlist was passed to AVFoundation")
        } catch {}
        client.invalidate()
        do {
            _ = try await client.localMediaFile(client.playbackURL(assetID: "after-logout"))
            XCTFail("invalidated context downloaded media")
        } catch {}
    }
}

extension NetworkBoundaryTests {
    func testNukeThumbnailsDoNotFollowCrossHostRedirect() async throws {
        let receiver = try LocalHTTPServer { _ in .init() }
        try await receiver.start()
        defer { receiver.stop() }
        for status in [301, 302, 303, 307, 308] {
            var otherHost = URLComponents(url: receiver.apiURL, resolvingAgainstBaseURL: false)!
            otherHost.host = "localhost"
            let target = otherHost.url!.appending(path: "capture")
            let source = try LocalHTTPServer { _ in .init(status: status, headers: ["Location": target.absoluteString]) }
            try await source.start()
            let client = ImoraClient(apiURL: source.apiURL, accessToken: "synthetic-image-token")
            ImageLoader.shared.configure(client: client)
            _ = try? await ImageLoader.shared.image(for: client.thumbnailURL(assetID: "redirect-\(status)"), targetPixelSize: 64)
            XCTAssertEqual(source.received.first?.headers["authorization"], "Bearer synthetic-image-token")
            XCTAssertTrue(receiver.received.isEmpty, "Nuke followed HTTP \(status)")
            ImageLoader.shared.configure(client: nil)
            client.invalidate()
            source.stop()
        }
    }

    func testReadOnlyAPIRedirectCannotEscapeRoot() async throws {
        let source = try LocalHTTPServer { request in
            request.path == "/api/users/me" ? .init(status: 302, headers: ["Location": "/outside-api"]) : .init()
        }
        try await source.start()
        defer { source.stop() }
        let client = ImoraClient(apiURL: source.apiURL, accessToken: "read-token")
        _ = try? await client.currentUser()
        XCTAssertEqual(source.received.map(\.path), ["/api/users/me"])
    }
}
