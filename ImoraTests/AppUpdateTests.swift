import Foundation
import XCTest
@testable import Imora

final class AppUpdateTests: XCTestCase {
    func testVersionsOrderNumericallyAndUseBuildOnlyForTheSameVersion() throws {
        let cases: [(String, String, String, String, Bool)] = [
            ("1.0.1", "2", "1.0", "1", true),
            ("1.10.0", "1", "1.9.9", "999", true),
            ("1.0.1", "3", "1.0.1", "2", true),
            ("1.0.1", "2", "1.0.1", "2", false),
            ("1.0.0", "999", "1.0.1", "2", false),
            ("1.0.1-beta.2", "3", "1.0.1", "2", false),
            ("1.0.1", "2", "1.0.1-beta.10", "99", true),
            ("1.0.1-beta.10", "2", "1.0.1-beta.2", "3", true)
        ]
        for (candidate, build, installed, installedBuild, expected) in cases {
            let lhs = try XCTUnwrap(AppUpdateVersion(version: candidate, build: build))
            let rhs = try XCTUnwrap(AppUpdateVersion(version: installed, build: installedBuild))
            XCTAssertEqual(lhs > rhs, expected, "\(candidate) (\(build)) vs \(installed) (\(installedBuild))")
        }
        for version in ["", "latest", "1..2", "1.0.01", "1.0.0-beta.01", "1.2.3.4", "-1.0.0"] {
            XCTAssertNil(AppUpdateVersion(version: version, build: "2"), version)
        }
        for build in ["", "-2", "2.5", "huge", String(repeating: "9", count: 100)] {
            XCTAssertNil(AppUpdateVersion(version: "1.0.1", build: build), build)
        }
    }

    func testPrivateConfigurationRequiresHTTPSV1RootValidCAAndDedicatedToken() throws {
        let valid = try updateConfiguration()
        XCTAssertEqual(valid.hostId, "fixture-mac")
        XCTAssertEqual(valid.identity.apiURL.path, "/v1")
        XCTAssertNil(AppUpdateConfiguration.decode(nil))
        let mutations: [[String: Any]] = [
            ["schemaVersion": 2], ["apiURL": "http://127.0.0.1:8443/v1"],
            ["apiURL": "https://user:secret@127.0.0.1/v1"],
            ["apiURL": "https://127.0.0.1/v1?token=x"],
            ["apiURL": "https://127.0.0.1/api"],
            ["apiURL": "https://127.0.0.1/v1/../private"],
            ["caCertificateDERBase64": Data("bad".utf8).base64EncodedString()],
            ["accessToken": ""], ["accessToken": "one\r\nInjected: two"], ["hostId": ""]
        ]
        for mutation in mutations {
            XCTAssertNil(AppUpdateConfiguration.decode(try updateConfigurationData(overrides: mutation)), "\(mutation.keys)")
        }
        XCTAssertNil(AppUpdateConfiguration.decode(Data(repeating: 32, count: 131_073)))
    }

    func testStatusRejectsWrongSchemaHostMalformedVersionsStatesAndUnboundedMetadata() throws {
        let valid = try AppUpdateStatus.decode(updateStatusData(), expectedHostID: "fixture-mac")
        XCTAssertEqual(valid.latest?.releaseId, "release-2")
        let inputs = [
            #"{"schemaVersion":2,"hostId":"fixture-mac","latest":null,"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"other-mac","latest":null,"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac"}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"../../evil","version":"1.0.1","build":"2","notes":""},"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"latest","build":"2","notes":""},"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":null,"installation":{"state":"executing"}}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":null,"installation":{"state":"failed","messageCode":"shellCommand"}}"#
        ]
        for input in inputs {
            XCTAssertThrowsError(try AppUpdateStatus.decode(Data(input.utf8), expectedHostID: "fixture-mac"))
        }
        XCTAssertThrowsError(try AppUpdateStatus.decode(updateStatusData(notes: String(repeating: "x", count: 8_193)), expectedHostID: "fixture-mac"))
    }

    func testClientChecksOnlyStatusAndConfirmedInstallContainsOnlyReleaseAndRequestIDs() async throws {
        let server = try LocalTLSServer { request in
            if request.method == "POST" {
                return .init(status: 202, body: Data(#"{"state":"queued","releaseId":"release-2"}"#.utf8))
            }
            return .init(body: updateStatusData())
        }
        try await server.start(); defer { server.stop() }
        let root = server.apiURL.deletingLastPathComponent().appending(path: "v1")
        let client = AppUpdateClient(configuration: try updateConfiguration(apiURL: root))
        let status = try await client.status()
        XCTAssertEqual(status.latest?.version, "1.0.1")
        XCTAssertEqual(server.received.map(\.method), ["GET"])
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let result = try await client.install(releaseID: "release-2", requestID: id)
        XCTAssertEqual(result.state, .queued)
        XCTAssertEqual(server.received.map(\.path), ["/v1/status", "/v1/install"])
        XCTAssertTrue(server.received.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-update-token" })
        let body = try XCTUnwrap(server.received.last?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["releaseId", "requestId"])
        XCTAssertEqual(object["releaseId"], "release-2")
        XCTAssertEqual(object["requestId"], id.uuidString)
        do { _ = try await client.install(releaseID: "../private", requestID: UUID()); XCTFail("unsafe release ID accepted") } catch {}
        XCTAssertEqual(server.received.count, 2)
    }

    func testClientRejectsEveryRedirectAndWrongCertificateWithoutSendingCredentialsElsewhere() async throws {
        let server = try LocalTLSServer { _ in
            .init(status: 307, headers: ["Location": "/v1/redirected"], body: updateStatusData())
        }
        try await server.start(); defer { server.stop() }
        let root = server.apiURL.deletingLastPathComponent().appending(path: "v1")
        let client = AppUpdateClient(configuration: try updateConfiguration(apiURL: root))
        do { _ = try await client.status(); XCTFail("redirect accepted") } catch {}
        XCTAssertEqual(server.received.map(\.path), ["/v1/status"])
        let wrong = AppUpdateClient(configuration: try updateConfiguration(apiURL: root, certificate: LocalTLSFixtures.other))
        do { _ = try await wrong.status(); XCTFail("wrong CA accepted") } catch {}
        XCTAssertEqual(server.received.count, 1)
    }

    func testClientRejectsHTTPErrorEvenWhenBodyLooksLikeValidStatus() async throws {
        let server = try LocalTLSServer { _ in .init(status: 503, body: updateStatusData()) }
        try await server.start(); defer { server.stop() }
        let root = server.apiURL.deletingLastPathComponent().appending(path: "v1")
        let client = AppUpdateClient(configuration: try updateConfiguration(apiURL: root))
        do { _ = try await client.status(); XCTFail("HTTP error accepted") } catch {}
    }

    func testClientBoundsResponseAndRejectsWrongHostOrMismatchedInstallReceipt() async throws {
        let server = try LocalTLSServer { request in
            if request.method == "POST" {
                return .init(status: 202, body: Data(#"{"state":"queued","releaseId":"other-release"}"#.utf8))
            }
            return .init(body: Data(repeating: 32, count: 65_537))
        }
        try await server.start(); defer { server.stop() }
        let root = server.apiURL.deletingLastPathComponent().appending(path: "v1")
        let client = AppUpdateClient(configuration: try updateConfiguration(apiURL: root))
        do { _ = try await client.status(); XCTFail("oversized response accepted") } catch {}
        do { _ = try await client.install(releaseID: "release-2", requestID: UUID()); XCTFail("mismatched receipt accepted") } catch {}
    }
}

func updateConfigurationData(overrides: [String: Any] = [:], apiURL: URL = URL(string: "https://127.0.0.1:8443/v1")!, certificate: Data = LocalTLSFixtures.root) throws -> Data {
    var object: [String: Any] = ["schemaVersion": 1, "apiURL": apiURL.absoluteString,
        "caCertificateDERBase64": certificate.base64EncodedString(), "accessToken": "synthetic-update-token", "hostId": "fixture-mac"]
    object.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: object)
}

func updateConfiguration(apiURL: URL = URL(string: "https://127.0.0.1:8443/v1")!, certificate: Data = LocalTLSFixtures.root) throws -> AppUpdateConfiguration {
    try XCTUnwrap(AppUpdateConfiguration.decode(updateConfigurationData(apiURL: apiURL, certificate: certificate)))
}

func updateStatusData(notes: String = "A prepared synthetic release") -> Data {
    try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "hostId": "fixture-mac",
        "latest": ["releaseId": "release-2", "version": "1.0.1", "build": "2", "notes": notes], "installation": NSNull()])
}
