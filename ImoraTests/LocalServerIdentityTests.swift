import Foundation
import Security
import Synchronization
import XCTest
@testable import Imora

final class LocalServerIdentityTests: XCTestCase {
    private let root = URL(string: "https://127.0.0.1:8443/api")!

    func testRouteRevocationBetweenAuthorizationAndResumeDoesNotStartTransfer() throws {
        let allowed = Mutex(true)
        let context = AccountRequestContext(apiURL: root, token: "synthetic", requestAllowed: { _ in allowed.withLock { $0 } })
        let request = try context.authorize(URLRequest(url: root.appending(path: "assets")))
        allowed.withLock { $0 = false }
        var started = false
        XCTAssertThrowsError(try context.startWhileActive(for: request) { started = true })
        XCTAssertFalse(started)
        XCTAssertThrowsError(try context.authorize(URLRequest(url: root)))
    }

    private func trust(_ leaf: Data = LocalTLSFixtures.leaf, date: Date? = nil) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, leaf as CFData))
        var value: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &value), errSecSuccess)
        let result = try XCTUnwrap(value)
        if let date { XCTAssertEqual(SecTrustSetVerifyDate(result, date as CFDate), errSecSuccess) }
        return result
    }

    func testIdentityAcceptsOnlyHTTPSAndParsedBoundedCertificate() throws {
        let good = LocalServerIdentity(apiURL: root, rootCertificateDER: LocalTLSFixtures.root)
        XCTAssertTrue(good.isValid)
        XCTAssertEqual(try JSONDecoder().decode(LocalServerIdentity.self, from: JSONEncoder().encode(good)), good)
        for input in ["http://127.0.0.1:8443/api", "https://name:secret@127.0.0.1/api", "https://127.0.0.1/api?key=value", "https://127.0.0.1/api/../other"] {
            XCTAssertFalse(LocalServerIdentity(apiURL: URL(string: input)!, rootCertificateDER: LocalTLSFixtures.root).isValid, input)
        }
        XCTAssertFalse(LocalServerIdentity(apiURL: root, rootCertificateDER: Data("bad-certificate".utf8)).isValid)
        XCTAssertFalse(LocalServerIdentity(apiURL: root, rootCertificateDER: Data(repeating: 0, count: 65_537)).isValid)
    }

    func testActualTrustRequiresPinnedChainHostnameValidityAndExactAPIRoot() throws {
        let identity = LocalServerIdentity(apiURL: root, rootCertificateDER: LocalTLSFixtures.root)
        XCTAssertTrue(identity.validates(try trust(), for: root.appending(path: "server/ping")))
        XCTAssertFalse(LocalServerIdentity(apiURL: root, rootCertificateDER: LocalTLSFixtures.other).validates(try trust(), for: root))
        XCTAssertFalse(identity.validates(try trust(LocalTLSFixtures.wrongHost), for: root))
        XCTAssertFalse(identity.validates(try trust(date: Date().addingTimeInterval(2 * 365 * 86400)), for: root))
        XCTAssertFalse(identity.validates(try trust(date: Date(timeIntervalSince1970: 0)), for: root))
        for input in ["https://127.0.0.1:8444/api", "https://127.0.0.1:8443/private", "http://127.0.0.1:8443/api", "https://localhost:8443/api"] {
            XCTAssertFalse(identity.validates(try trust(), for: URL(string: input)!))
        }
    }

    func testPinnedTLSAcceptsCorrectRootAndNeverFallsBackForWrongRoot() async throws {
        let server = try LocalTLSServer { _ in .init(body: Data("trusted".utf8)) }
        try await server.start(); defer { server.stop() }
        let identity = LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.root)
        let session = ControlledSession.make(identity: identity)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: server.apiURL.appending(path: "server/ping"))
        XCTAssertEqual(data, Data("trusted".utf8)); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let wrong = ControlledSession.make(identity: LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.other))
        defer { wrong.invalidateAndCancel() }
        do { _ = try await wrong.data(from: server.apiURL.appending(path: "assets")); XCTFail("wrong root reached HTTP") } catch {}
        XCTAssertEqual(server.received.count, 1)
    }

    func testPinDoesNotEnableRedirectsOrTrustOutsideConfiguredRoot() async throws {
        let server = try LocalTLSServer { _ in .init(status: 307, headers: ["Location": "/api/redirected"]) }
        try await server.start(); defer { server.stop() }
        let identity = LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.root)
        let session = ControlledSession.make(identity: identity)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: server.apiURL.appending(path: "server/ping"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        do { _ = try await session.data(from: server.apiURL.deletingLastPathComponent().appending(path: "private")); XCTFail("pin trusted outside API root") } catch {}
        XCTAssertEqual(server.received.count, 1)
    }
}
