import Foundation
import XCTest
@testable import Imora

@MainActor
final class VerifiedLocalServerRouteTests: XCTestCase {
    private let external = URL(string: "https://photos.example.com/api")!
    private let local = URL(string: "https://192.168.50.10:8443/api")!

    func testVerifiedAutomaticSelectionUsesPinnedProbeWithoutSSID() async throws {
        let recorder = IdentityProbeRecorder(answer: true)
        let fixture = try fixture(identityProbe: { await recorder.answer($0, identity: $1) })
        defer { fixture.cleanUp() }

        try await eventually { fixture.router.status == .local }

        let requests = await recorder.requests
        let identities = await recorder.identities
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, URL(string: "https://192.168.50.10:8443/api/server/ping")!)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertEqual(identities, [fixture.identity])
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), fixture.identity)
        XCTAssertEqual(ServerRoute.resolve(URL(string: "https://photos.example.com/api/assets/one")!), URL(string: "https://192.168.50.10:8443/api/assets/one")!)
        XCTAssertFalse(fixture.router.isManualLocal)
    }

    func testFailedIdentityProbeNeverActivatesOrAuthorizesLocal() async throws {
        let fixture = try fixture(identityProbe: { _, _ in false })
        defer { fixture.cleanUp() }

        try await eventually { fixture.router.status == .external }

        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertNil(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults))
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testAutomaticVerifiedSelectionRequiresWiFiAndEnabledPreference() throws {
        for mode in 0..<3 {
            let fixture = try fixture(network: mode == 0 ? nil : "test-network", enabled: mode != 1, automatic: mode != 2)
            defer { fixture.cleanUp() }
            XCTAssertFalse(ServerRoute.isLocal)
            XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
        }
    }

    func testInvalidOrMismatchingIdentityCannotEnableAutomaticLAN() throws {
        for identity in [
            LocalServerIdentity(apiURL: local, rootCertificateDER: Data([0, 1, 2])),
            LocalServerIdentity(apiURL: URL(string: "https://192.168.50.11:8443/api")!, rootCertificateDER: LocalTLSFixtures.root)
        ] {
            let fixture = try fixture(identity: identity)
            defer { fixture.cleanUp() }
            XCTAssertFalse(ServerRoute.isLocal)
            XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
        }
    }

    func testExternalChoiceRejectsStaleVerifiedProbe() async throws {
        let pending = PendingIdentityProbe()
        let fixture = try fixture(identityProbe: { await pending.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        await pending.waitUntilRequested()

        fixture.router.useExternal()
        await pending.finish(true)
        await Task.yield()

        XCTAssertEqual(fixture.router.status, .external)
        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testNetworkLossRejectsStaleVerifiedProbe() async throws {
        let pending = PendingIdentityProbe()
        let fixture = try fixture(identityProbe: { await pending.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        await pending.waitUntilRequested()

        fixture.router.networkChanged(network: nil)
        await pending.finish(true)
        await Task.yield()

        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testAccountChangeRejectsStaleVerifiedProbe() async throws {
        let pending = PendingIdentityProbe()
        let fixture = try fixture(identityProbe: { await pending.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        await pending.waitUntilRequested()

        fixture.router.activate(external: URL(string: "https://other.example.com/api")!)
        await pending.finish(true)
        await Task.yield()

        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertNil(fixture.router.config)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testConfigurationChangeRejectsStaleVerifiedProbe() async throws {
        let pending = PendingIdentityProbe()
        let fixture = try fixture(identityProbe: { await pending.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        await pending.waitUntilRequested()

        var edited = try XCTUnwrap(fixture.router.config)
        edited.isEnabled = false
        fixture.router.update(edited)
        await pending.finish(true)
        await Task.yield()

        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testManualVerifiedSelectionAlsoPassesIdentityToProbe() async throws {
        let recorder = IdentityProbeRecorder(answer: true)
        let fixture = try fixture(automatic: false, identityProbe: { await recorder.answer($0, identity: $1) })
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(confirmedURL: local)

        XCTAssertEqual(result, .selected)
        let identities = await recorder.identities
        XCTAssertEqual(identities, [fixture.identity])
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), fixture.identity)
        XCTAssertFalse(ServerRoute.fallBack(from: local.appending(path: "assets"), after: URLError(.cannotConnectToHost)))
    }

    func testExternalChoiceRevokesActivePinnedIdentity() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try await eventually { fixture.router.status == .local }

        fixture.router.useExternal()

        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
        XCTAssertNil(ServerRoute.configuredIdentity(for: URL(string: "https://other.example.com/api")!, defaults: fixture.defaults))
    }

    func testEditingLocalURLRemovesMismatchingIdentityAndAutomaticPreference() throws {
        let fixture = try fixture(network: nil)
        defer { fixture.cleanUp() }
        var edited = try XCTUnwrap(fixture.router.config)
        edited.apiURL = URL(string: "http://192.168.50.11:2283/api")!

        fixture.router.update(edited)

        XCTAssertNil(fixture.router.config?.identity)
        XCTAssertEqual(fixture.router.config?.automaticallyUseVerifiedLocal, false)
        let persisted = try JSONDecoder().decode(LocalServerConfig.self, from: XCTUnwrap(fixture.defaults.data(forKey: "imora.localServer")))
        XCTAssertNil(persisted.identity)
    }

    func testTransportIdentityReturnsFixedPinAndRejectsCapturedLocalAfterReset() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try await eventually { fixture.router.status == .local }
        let captured = local.appending(path: "assets/one")
        XCTAssertEqual(try ServerRoute.transportIdentity(to: captured, for: external, defaults: fixture.defaults), fixture.identity)
        XCTAssertNil(try ServerRoute.transportIdentity(to: external.appending(path: "assets/one"), for: external, defaults: fixture.defaults))

        fixture.router.useExternal()

        XCTAssertThrowsError(try ServerRoute.transportIdentity(to: captured, for: external, defaults: fixture.defaults))
    }

    func testHeldManualTransportCannotDegradeToSystemTrustOrWAN() async throws {
        let fixture = try fixture(automatic: false)
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: nil)

        XCTAssertThrowsError(try ServerRoute.transportIdentity(to: local.appending(path: "assets/one"), for: external, defaults: fixture.defaults))
        XCTAssertThrowsError(try ServerRoute.transportIdentity(to: external.appending(path: "assets/one"), for: external, defaults: fixture.defaults))
    }

    func testSavedPinMismatchCannotRetargetActiveTransportOrChooseSystemTrust() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try await eventually { fixture.router.status == .local }
        var edited = try XCTUnwrap(fixture.router.config)
        edited.identity = LocalServerIdentity(apiURL: local, rootCertificateDER: LocalTLSFixtures.other)
        fixture.defaults.set(try JSONEncoder().encode(edited), forKey: "imora.localServer")

        XCTAssertThrowsError(try ServerRoute.transportIdentity(to: local.appending(path: "assets/one"), for: external, defaults: fixture.defaults))
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    func testLegacySSIDSelectionStillUsesExistingHTTPProbe() async throws {
        let fixture = try fixture(network: nil)
        defer { fixture.cleanUp() }
        let router = LocalServerRouter(defaults: fixture.defaults, monitoringEnabled: false, notificationCenter: NotificationCenter(), probe: { _ in true }, ssidProvider: { "Saved Test Wi-Fi" })
        var legacy = LocalServerConfig(server: external, apiURL: URL(string: "http://192.168.50.10:2283/api")!)
        legacy.networks = ["Saved Test Wi-Fi"]
        router.activate(external: external)
        router.update(legacy)
        router.networkChanged(network: "test-network")

        try await eventually { router.status == .local }

        XCTAssertEqual(ServerRoute.resolve(external), URL(string: "http://192.168.50.10:2283/api")!)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func fixture(
        identity suppliedIdentity: LocalServerIdentity? = nil,
        network: String? = "test-network",
        enabled: Bool = true,
        automatic: Bool = true,
        identityProbe: @escaping @Sendable (URLRequest, LocalServerIdentity) async -> Bool = { _, _ in true }
    ) throws -> VerifiedRouteFixture {
        let suite = "VerifiedLocalServerRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let identity = suppliedIdentity ?? LocalServerIdentity(apiURL: local, rootCertificateDER: LocalTLSFixtures.root)
        let config = LocalServerConfig(server: external, apiURL: local, isEnabled: enabled, identity: identity, automaticallyUseVerifiedLocal: automatic)
        defaults.set(try JSONEncoder().encode(config), forKey: "imora.localServer")
        let router = LocalServerRouter(defaults: defaults, monitoringEnabled: false, notificationCenter: NotificationCenter(), probe: { _ in false }, ssidProvider: { nil }, identityProbe: identityProbe)
        router.activate(external: external)
        router.networkChanged(network: network)
        return VerifiedRouteFixture(router: router, defaults: defaults, suite: suite, identity: identity)
    }
}

@MainActor
private struct VerifiedRouteFixture {
    let router: LocalServerRouter
    let defaults: UserDefaults
    let suite: String
    let identity: LocalServerIdentity

    func cleanUp() {
        router.deactivate()
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor IdentityProbeRecorder {
    let result: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var identities: [LocalServerIdentity] = []

    init(answer: Bool) { result = answer }

    func answer(_ request: URLRequest, identity: LocalServerIdentity) -> Bool {
        requests.append(request)
        identities.append(identity)
        return result
    }
}

private actor PendingIdentityProbe {
    private var pending: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func answer(_ request: URLRequest, identity: LocalServerIdentity) async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish(_ result: Bool) {
        pending?.resume(returning: result)
        pending = nil
    }
}
