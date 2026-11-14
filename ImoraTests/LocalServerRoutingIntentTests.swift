import Foundation
import XCTest
@testable import Imora

@MainActor
final class LocalServerRoutingIntentTests: XCTestCase {
    private let external = URL(string: "https://photos.example.com/api")!
    private let http = URL(string: "http://192.168.50.10:2283/api")!
    private let https = URL(string: "https://192.168.50.10:8443/api")!

    func testHTTPBackgroundHoldBlocksCanonicalAndCapturedLocalGETAndPOST() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: http)
        XCTAssertEqual(result, .selected)
        let context = accountContext()

        fixture.router.applicationReturnedToForeground()

        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(fixture.router.status, .held)
        assertBlocked(context, fixture: fixture)
    }

    func testWiFiLossHoldsManualHTTPIntentUntilExplicitReconfirmation() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let initial = await fixture.router.requestManualLocal(confirmedURL: http)
        XCTAssertEqual(initial, .selected)

        fixture.router.networkChanged(network: nil)
        fixture.router.networkChanged(network: "another-test-network")

        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(fixture.router.status, .held)
        assertBlocked(accountContext(), fixture: fixture)

        let result = await fixture.router.requestManualLocal(confirmedURL: http)
        XCTAssertEqual(result, .selected)
        XCTAssertEqual(fixture.router.status, .local)
        XCTAssertTrue(ServerRoute.permitsRequest(to: http.appending(path: "assets"), for: external))
        XCTAssertFalse(ServerRoute.permitsRequest(to: external.appending(path: "assets"), for: external))
    }

    func testUseExternalExplicitlyReleasesHeldManualIntent() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: http)
        XCTAssertEqual(result, .selected)
        fixture.router.applicationReturnedToForeground()

        fixture.router.useExternal()

        XCTAssertFalse(fixture.router.isManualLocal)
        XCTAssertEqual(fixture.router.status, .external)
        XCTAssertTrue(ServerRoute.permitsRequest(to: external.appending(path: "assets"), for: external))
        XCTAssertNoThrow(try accountContext().authorize(URLRequest(url: external.appending(path: "assets"))))
    }

    func testCapturedLocalRequestCannotResumeAfterSwitchingToExternal() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: http)
        XCTAssertEqual(result, .selected)
        let context = accountContext()
        let captured = try context.authorize(URLRequest(url: http.appending(path: "assets")), localAPIURL: ServerRoute.configuredLocal(for: external, defaults: fixture.defaults))

        fixture.router.useExternal()

        var resumed = false
        XCTAssertThrowsError(try context.startWhileActive(for: captured) { resumed = true })
        XCTAssertFalse(resumed)
        XCTAssertTrue(ServerRoute.permitsRequest(to: external.appending(path: "assets"), for: external))
    }

    func testDuplicateNetworkCallbackDoesNotCancelPendingPinnedManualConfirmation() async throws {
        let pending = IntentProbeGate()
        let fixture = try fixture(pinned: true, identityProbe: { request, _ in await pending.answer(request) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: https) }
        await pending.waitUntilRequested()

        fixture.router.networkChanged(network: "test-network")
        await pending.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .selected)
        XCTAssertEqual(fixture.router.status, .local)
    }

    func testGatewayOrderingDoesNotResetConfirmedPinnedManualRoute() async throws {
        let fixture = try fixture(pinned: true, network: LocalServerRouter.networkSignature(gateways: ["gateway-a", "gateway-b"], connectedToWiFi: true))
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: LocalServerRouter.networkSignature(gateways: ["gateway-b", "gateway-a"], connectedToWiFi: true))

        XCTAssertEqual(fixture.router.status, .local)
        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults), https)
    }

    func testSameOrAbsentGatewayCannotKeepUnverifiedHTTPAuthorization() async throws {
        for signature in ["test-network", ""] {
            let fixture = try fixture(network: signature)
            defer { fixture.cleanUp() }
            let result = await fixture.router.requestManualLocal(confirmedURL: http)
            XCTAssertEqual(result, .selected)

            fixture.router.networkChanged(network: signature)

            XCTAssertTrue(fixture.router.isManualLocal)
            XCTAssertEqual(fixture.router.status, .held)
            XCTAssertEqual(fixture.router.holdReason, .confirmationRequired)
            assertBlocked(accountContext(), fixture: fixture)
        }
    }

    func testUncertainCallbackRejectsPendingUnverifiedHTTPConfirmation() async throws {
        let pending = IntentProbeGate()
        let fixture = try fixture(probe: { await pending.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: http) }
        await pending.waitUntilRequested()

        fixture.router.networkChanged(network: "test-network")
        await pending.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertFalse(fixture.router.isManualLocal)
        XCTAssertNil(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults))
    }

    func testDuplicateCallbackPreservesPinnedManualRouteAndFixedIdentity() async throws {
        let fixture = try fixture(pinned: true)
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: "test-network")

        XCTAssertEqual(fixture.router.status, .local)
        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), fixture.identity)
    }

    func testPinnedManualChoiceSurvivesRealForegroundReturnWithoutChoosingWAN() async throws {
        let fixture = try fixture(pinned: true)
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.applicationReturnedToForeground()

        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(fixture.router.status, .local)
        XCTAssertEqual(ServerRoute.resolve(external), https)
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), fixture.identity)
        XCTAssertFalse(ServerRoute.permitsRequest(to: external.appending(path: "assets"), for: external))
    }

    func testPinnedManualWiFiLossHoldsIntentAndBlocksWAN() async throws {
        let fixture = try fixture(pinned: true)
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: nil)

        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(fixture.router.status, .held)
        XCTAssertEqual(ServerRoute.resolve(external), https)
        XCTAssertNil(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults))
        assertBlocked(accountContext(), fixture: fixture)
    }

    func testPinnedManualNewNetworkReprobesSameIdentityThenResumesWithoutSSID() async throws {
        let probe = RecheckingIdentityProbe()
        let fixture = try fixture(pinned: true, identityProbe: { await probe.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: "new-test-network")
        await probe.waitUntilRechecking()
        XCTAssertEqual(fixture.router.status, .held)
        assertBlocked(accountContext(), fixture: fixture)
        await probe.finish(true)
        try await eventually { fixture.router.status == .local }

        let identities = await probe.identities
        XCTAssertEqual(identities, [fixture.identity, fixture.identity])
        XCTAssertEqual(ServerRoute.configuredIdentity(for: external, defaults: fixture.defaults), fixture.identity)
        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertFalse(ServerRoute.fallBack(from: https.appending(path: "assets"), after: URLError(.cannotConnectToHost)))
    }

    func testFailedPinnedManualRecheckRemainsHeldAndNeverChoosesWAN() async throws {
        let probe = RecheckingIdentityProbe()
        let fixture = try fixture(pinned: true, identityProbe: { await probe.answer($0, identity: $1) })
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: https)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: "new-test-network")
        await probe.waitUntilRechecking()
        await probe.finish(false)
        try await eventually { fixture.router.holdReason == .unreachable }

        XCTAssertEqual(fixture.router.status, .held)
        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.resolve(external), https)
        assertBlocked(accountContext(), fixture: fixture)
    }

    private func accountContext() -> AccountRequestContext {
        let external = external
        return AccountRequestContext(apiURL: external, token: "test-intent-token", requestAllowed: {
            ServerRoute.permitsRequest(to: $0, for: external)
        })
    }

    private func assertBlocked(_ context: AccountRequestContext, fixture: IntentFixture, file: StaticString = #filePath, line: UInt = #line) {
        let allowedLocal = ServerRoute.configuredLocal(for: external, defaults: fixture.defaults)
        for root in [external, fixture.local] {
            for method in ["GET", "POST"] {
                var request = URLRequest(url: root.appending(path: "assets"))
                request.httpMethod = method
                XCTAssertThrowsError(try context.authorize(request, localAPIURL: allowedLocal), file: file, line: line)
            }
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func fixture(
        pinned: Bool = false,
        network: String? = "test-network",
        probe: @escaping @Sendable (URLRequest) async -> Bool = { _ in true },
        identityProbe: @escaping @Sendable (URLRequest, LocalServerIdentity) async -> Bool = { _, _ in true }
    ) throws -> IntentFixture {
        let suite = "LocalServerRoutingIntentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let local = pinned ? https : http
        let identity = LocalServerIdentity(apiURL: https, rootCertificateDER: LocalTLSFixtures.root)
        let config = LocalServerConfig(server: external, apiURL: local, identity: pinned ? identity : nil)
        defaults.set(try JSONEncoder().encode(config), forKey: "imora.localServer")
        let router = LocalServerRouter(defaults: defaults, monitoringEnabled: false, notificationCenter: NotificationCenter(), probe: probe, ssidProvider: { nil }, identityProbe: identityProbe)
        router.activate(external: external)
        router.networkChanged(network: network)
        return IntentFixture(router: router, defaults: defaults, suite: suite, local: local, identity: identity)
    }
}

@MainActor
private struct IntentFixture {
    let router: LocalServerRouter
    let defaults: UserDefaults
    let suite: String
    let local: URL
    let identity: LocalServerIdentity

    func cleanUp() {
        router.deactivate()
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor IntentProbeGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func answer(_ request: URLRequest) async -> Bool {
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

private actor RecheckingIdentityProbe {
    private(set) var identities: [LocalServerIdentity] = []
    private var pending: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func answer(_ request: URLRequest, identity: LocalServerIdentity) async -> Bool {
        identities.append(identity)
        if identities.count == 1 { return true }
        return await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRechecking() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish(_ result: Bool) {
        pending?.resume(returning: result)
        pending = nil
    }
}
