import Foundation
import XCTest
@testable import Imora

@MainActor
final class LocalServerIdentityProvisioningTests: XCTestCase {
    private let external = URL(string: "https://photos.example.com/api")!
    private let previous = URL(string: "http://192.168.50.10:2283/api")!
    private let local = URL(string: "https://192.168.50.10:8443/api")!

    func testLegacyConfigurationDecodesWithoutIdentityOrAutomaticPreference() throws {
        let data = Data(#"{"server":"https://photos.example.com/api","apiURL":"http://192.168.50.10:2283/api","networks":[],"isEnabled":true}"#.utf8)

        let config = try JSONDecoder().decode(LocalServerConfig.self, from: data)

        XCTAssertNil(config.identity)
        XCTAssertFalse(config.automaticallyUseVerifiedLocal)
        XCTAssertEqual(config.apiURL, previous)
        XCTAssertTrue(config.isEnabled)
    }

    func testApprovedIdentityMigratesOnlyMatchingEnabledSavedConfiguration() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.server, external)
        XCTAssertEqual(fixture.router.config?.apiURL, local)
        XCTAssertEqual(fixture.router.config?.identity, identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, true)
        let persisted = try JSONDecoder().decode(LocalServerConfig.self, from: XCTUnwrap(fixture.defaults.data(forKey: "imora.localServer")))
        XCTAssertEqual(persisted.apiURL, local)
        XCTAssertEqual(persisted.identity, identity)
    }

    func testFreshDeviceExplicitHTTPSSetupVerifiesRealTLSBeforeSelectingManualLocal() async throws {
        let server = try LocalTLSServer { request in
            .init(status: request.path == "/api/server/ping" ? 200 : 404)
        }
        try await server.start()
        defer { server.stop() }
        let identity = LocalServerIdentity(apiURL: server.apiURL, rootCertificateDER: LocalTLSFixtures.root)
        let enrollment = LocalServerIdentityProvisioning(externalAPIURL: external, previousLocalAPIURL: previous, identity: identity)
        let fixture = try fixture(config: nil, data: JSONEncoder().encode(enrollment))
        defer {
            fixture.router.deactivate()
            fixture.cleanUp()
        }
        fixture.router.activate(external: external)
        fixture.router.networkChanged(network: "synthetic-wifi")
        XCTAssertNil(fixture.router.config, "account activation alone must not enable a local route")

        fixture.router.update(LocalServerConfig(server: external, apiURL: server.apiURL))
        let result = await fixture.router.requestManualLocal(confirmedURL: server.apiURL)

        XCTAssertEqual(result, .selected)
        XCTAssertEqual(fixture.router.config?.verifiedIdentity, identity)
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false, "explicit address setup must preserve the automatic-selection preference")
        XCTAssertEqual(server.received.map(\.path), ["/api/server/ping"])
        XCTAssertTrue(server.received.allSatisfy { $0.headers["authorization"] == nil && $0.headers["x-api-key"] == nil })
    }

    func testFreshDeviceExplicitLegacyAddressSetupInstallsProvisionedHTTPSIdentity() throws {
        let fixture = try fixture(config: nil)
        defer { fixture.cleanUp() }
        fixture.router.activate(external: external)
        // Opening Local Network and enabling it first saves an empty config.
        fixture.router.update(LocalServerConfig(server: external))

        fixture.router.update(LocalServerConfig(server: external, apiURL: previous))

        XCTAssertEqual(fixture.router.config?.apiURL, local)
        XCTAssertEqual(fixture.router.config?.verifiedIdentity, identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false)
        let persisted = try JSONDecoder().decode(LocalServerConfig.self, from: XCTUnwrap(fixture.defaults.data(forKey: "imora.localServer")))
        XCTAssertEqual(persisted.apiURL, local)
        XCTAssertEqual(persisted.verifiedIdentity, identity)
    }

    func testExplicitApprovedHTTPSSetupRestoresIdentityAfterSignOut() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.router.activate(external: external)
        XCTAssertEqual(fixture.router.config?.verifiedIdentity, identity)
        fixture.router.deactivate()
        fixture.router.activate(external: external)
        XCTAssertNil(fixture.router.config)

        fixture.router.update(LocalServerConfig(server: external, apiURL: local))

        XCTAssertEqual(fixture.router.config?.verifiedIdentity, identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false)
    }

    func testExplicitSetupDoesNotEnrollDisabledUnrelatedOrAlreadyPinnedAddresses() throws {
        let unrelated = URL(string: "https://192.168.50.11:8443/api")!
        for proposed in [
            LocalServerConfig(server: external, apiURL: local, isEnabled: false),
            LocalServerConfig(server: external, apiURL: unrelated),
            LocalServerConfig(server: external, apiURL: local.appending(path: "other")),
            LocalServerConfig(server: external, apiURL: local,
                              identity: LocalServerIdentity(apiURL: local, rootCertificateDER: LocalTLSFixtures.other))
        ] {
            let fixture = try fixture(config: nil)
            defer { fixture.cleanUp() }
            fixture.router.activate(external: external)

            fixture.router.update(proposed)

            XCTAssertEqual(fixture.router.config, proposed)
            XCTAssertEqual(fixture.router.config?.identity, proposed.identity)
            XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
        }
    }

    func testExplicitSetupDoesNotEnrollForAnotherAccount() throws {
        let fixture = try fixture(config: nil)
        defer { fixture.cleanUp() }
        let other = URL(string: "https://other.example.com/api")!
        fixture.router.activate(external: other)

        fixture.router.update(LocalServerConfig(server: other, apiURL: local))

        XCTAssertEqual(fixture.router.config?.server, other)
        XCTAssertNil(fixture.router.config?.identity)
    }

    func testEnrollmentDoesNotEnableDisabledLocalPreference() throws {
        let fixture = try fixture(config: LocalServerConfig(server: external, apiURL: previous, isEnabled: false))
        defer { fixture.cleanUp() }

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.apiURL, previous)
        XCTAssertEqual(fixture.router.config?.isEnabled, false)
        XCTAssertNil(fixture.router.config?.identity)
    }

    func testEnrollmentDoesNotOverwriteEditedLocalAddress() throws {
        let edited = URL(string: "http://192.168.50.11:2283/api")!
        let fixture = try fixture(config: LocalServerConfig(server: external, apiURL: edited))
        defer { fixture.cleanUp() }

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.apiURL, edited)
        XCTAssertNil(fixture.router.config?.identity)
    }

    func testEnrollmentDoesNotCreateConfigurationForMissingOrDifferentAccount() throws {
        let empty = try fixture(config: nil)
        defer { empty.cleanUp() }
        empty.router.activate(external: external)
        XCTAssertNil(empty.router.config)

        let other = try fixture()
        defer { other.cleanUp() }
        other.router.activate(external: URL(string: "https://other.example.com/api")!)
        XCTAssertNil(other.router.config)
        let persisted = try JSONDecoder().decode(LocalServerConfig.self, from: XCTUnwrap(other.defaults.data(forKey: "imora.localServer")))
        XCTAssertEqual(persisted.apiURL, previous)
        XCTAssertNil(persisted.identity)
    }

    func testInvalidManagedIdentityCannotMigrateOrEnableAutomaticSelection() throws {
        let malformed = LocalServerIdentity(apiURL: local, rootCertificateDER: Data([0, 1, 2]))
        let enrollment = LocalServerIdentityProvisioning(externalAPIURL: external, previousLocalAPIURL: previous, identity: malformed)
        let fixture = try fixture(enrollment: enrollment)
        defer { fixture.cleanUp() }

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.apiURL, previous)
        XCTAssertNil(fixture.router.config?.identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false)
    }

    func testMalformedResourceLeavesSavedConfigurationUsable() throws {
        let fixture = try fixture(data: Data("not a managed identity".utf8))
        defer { fixture.cleanUp() }

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.apiURL, previous)
        XCTAssertTrue(fixture.router.config?.isUsable == true)
        XCTAssertNil(fixture.router.config?.identity)
    }

    func testEnrollmentDigestPreventsReapplyingAfterUserRevertsAddress() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.router.activate(external: external)
        XCTAssertEqual(fixture.router.config?.apiURL, local)
        fixture.router.update(LocalServerConfig(server: external, apiURL: previous))

        fixture.router.activate(external: external)

        XCTAssertEqual(fixture.router.config?.apiURL, previous)
        XCTAssertNil(fixture.router.config?.identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false)
    }

    func testEquivalentResourceFormattingCannotBypassEnrollmentDigest() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.router.activate(external: external)
        fixture.router.update(LocalServerConfig(server: external, apiURL: previous))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reformatted = try encoder.encode(enrollment)
        let restored = LocalServerRouter(defaults: fixture.defaults, monitoringEnabled: false, notificationCenter: NotificationCenter(), provisioningData: reformatted)

        restored.activate(external: external)

        XCTAssertEqual(restored.config?.apiURL, previous)
        XCTAssertNil(restored.config?.identity)
    }

    private var identity: LocalServerIdentity {
        LocalServerIdentity(apiURL: local, rootCertificateDER: LocalTLSFixtures.root)
    }

    private var enrollment: LocalServerIdentityProvisioning {
        LocalServerIdentityProvisioning(externalAPIURL: external, previousLocalAPIURL: previous, identity: identity)
    }

    private func fixture() throws -> ProvisioningFixture {
        try fixture(config: LocalServerConfig(server: external, apiURL: previous))
    }

    private func fixture(config: LocalServerConfig?) throws -> ProvisioningFixture {
        try fixture(config: config, data: JSONEncoder().encode(enrollment))
    }

    private func fixture(enrollment: LocalServerIdentityProvisioning) throws -> ProvisioningFixture {
        try fixture(config: LocalServerConfig(server: external, apiURL: previous), data: JSONEncoder().encode(enrollment))
    }

    private func fixture(data: Data) throws -> ProvisioningFixture {
        try fixture(config: LocalServerConfig(server: external, apiURL: previous), data: data)
    }

    private func fixture(config: LocalServerConfig?, data: Data) throws -> ProvisioningFixture {
        let suite = "LocalServerIdentityProvisioningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let config { defaults.set(try JSONEncoder().encode(config), forKey: "imora.localServer") }
        let router = LocalServerRouter(defaults: defaults, monitoringEnabled: false, notificationCenter: NotificationCenter(), provisioningData: data)
        return ProvisioningFixture(router: router, defaults: defaults, suite: suite)
    }
}

@MainActor
private struct ProvisioningFixture {
    let router: LocalServerRouter
    let defaults: UserDefaults
    let suite: String

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}
