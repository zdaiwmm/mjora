import XCTest
import Synchronization
@testable import Imora

final class OriginalReadbackTests: XCTestCase {
    private let abc = ResourceDigest(checksum: "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=", byteCount: 3)

    func testReadsOriginalWithEditingDisabledAndChecksSHA1AndLength() async throws {
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "application/octet-stream"], body: Data("abc".utf8)) }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "fixture-original-token")
        let result = try await client.readbackOriginal(assetID: "fixture", expected: abc)
        XCTAssertEqual(result, abc)
        XCTAssertEqual(server.received.first?.path, "/api/assets/fixture/original?edited=false")
        XCTAssertEqual(server.received.first?.headers["authorization"], "Bearer fixture-original-token")
    }

    func testCorruptShortPartialAndUnexpectedResponseCannotPass() async throws {
        for (status, mime, data) in [(200, "image/jpeg", Data("def".utf8)), (200, "video/mp4", Data("ab".utf8)), (206, "image/jpeg", Data("abc".utf8)), (200, "text/html", Data("abc".utf8))] {
            let server = try LocalHTTPServer { _ in .init(status: status, headers: ["Content-Type": mime], body: data) }
            try await server.start()
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "fixture")
            do { _ = try await client.readbackOriginal(assetID: "fixture", expected: abc); XCTFail("bad original passed") } catch {}
            server.stop()
        }
    }

    func testOriginalRedirectNeverReachesReceiver() async throws {
        let receiver = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: Data("abc".utf8)) }
        try await receiver.start()
        defer { receiver.stop() }
        let server = try LocalHTTPServer { _ in .init(status: 307, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "fixture")
        do { _ = try await client.readbackOriginal(assetID: "fixture", expected: abc); XCTFail("redirect passed") } catch {}
        XCTAssertTrue(receiver.received.isEmpty)
    }

    func testAccountChangeDuringOriginalReadPreventsSuccess() async throws {
        let context = Mutex<AccountRequestContext?>(nil)
        let server = try LocalHTTPServer { _ in
            context.withLock { $0?.invalidate() }
            return .init(headers: ["Content-Type": "image/jpeg"], body: Data("abc".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "fixture")
        context.withLock { $0 = client.context }
        do { _ = try await client.readbackOriginal(assetID: "fixture", expected: abc); XCTFail("changed account passed") } catch {}
    }
}
