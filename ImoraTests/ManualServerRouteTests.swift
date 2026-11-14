import Foundation
import UIKit
import XCTest
@testable import Imora

@MainActor
final class ManualServerRouteTests: XCTestCase {
    private let external = URL(string: "https://photos.example.com/api")!
    private let local = URL(string: "http://192.168.50.10:2283/api")!
    private let externalAsset = URL(string: "https://photos.example.com/api/assets/one/original")!
    private let localAsset = URL(string: "http://192.168.50.10:2283/api/assets/one/original")!

    func testManualSelectionWorksWithoutSSIDOrSavedNetworkNames() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(confirmedURL: local)

        XCTAssertEqual(result, .selected)
        XCTAssertEqual(fixture.router.status, .local)
        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), localAsset)
        XCTAssertEqual(fixture.router.activeEndpoint, local)
        XCTAssertEqual(fixture.router.config?.server, external)
        XCTAssertEqual(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults), local)
    }

    func testDisabledMissingAndWrongAccountConfigurationsCannotSelectLocal() async throws {
        let configurations: [LocalServerConfig?] = [
            nil,
            LocalServerConfig(server: external, apiURL: nil),
            LocalServerConfig(server: external, apiURL: local, isEnabled: false),
            LocalServerConfig(server: URL(string: "https://other.example.com/api")!, apiURL: local)
        ]
        for configuration in configurations {
            let fixture = try fixture(configuration: configuration)
            defer { fixture.cleanUp() }

            let result = await fixture.router.requestManualLocal(confirmedURL: local)

            XCTAssertEqual(result, .unavailable)
            XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
            XCTAssertNil(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults))
        }
    }

    func testManualSelectionRequiresWiFiTransport() async throws {
        let fixture = try fixture(network: nil)
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(confirmedURL: local)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testConfirmationForDifferentSavedURLCannotSelectLocal() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(
            confirmedURL: URL(string: "http://192.168.50.11:2283/api")!
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testConfirmationFromBeforeNetworkUpdateCannotSelectLocal() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let confirmationRevision = fixture.router.selectionRevision
        fixture.router.networkChanged(network: "another-test-network")

        let result = await fixture.router.requestManualLocal(confirmedURL: local, revision: confirmationRevision)

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testUnreachableProbeRetainsPriorRoute() async throws {
        let fixture = try fixture(probe: { _ in false })
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(confirmedURL: local)

        XCTAssertEqual(result, .unreachable)
        XCTAssertEqual(fixture.router.status, .external)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testProbeIsAnUnauthenticatedPingToOnlyTheConfirmedURL() async throws {
        let recorder = RouteRequestRecorder()
        let fixture = try fixture(probe: { request in
            await recorder.record(request)
            return true
        })
        defer { fixture.cleanUp() }

        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        let requests = await recorder.requests

        XCTAssertEqual(result, .selected)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, URL(string: "http://192.168.50.10:2283/api/server/ping")!)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(requests.first?.httpBody)
    }

    func testNetworkChangeWhileProbeWaitsCannotActivateLocal() async throws {
        let probe = SuspendedRouteProbe()
        let fixture = try fixture(probe: { await probe.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: local) }
        await probe.waitUntilRequested()

        fixture.router.networkChanged(network: "another-test-network")
        await probe.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testExternalChoiceSupersedesAnAwaitingManualProbe() async throws {
        let probe = SuspendedRouteProbe()
        let fixture = try fixture(probe: { await probe.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: local) }
        await probe.waitUntilRequested()

        fixture.router.useExternal()
        await probe.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertEqual(fixture.router.status, .external)
    }

    func testCancellationWhileProbeWaitsCannotActivateLocal() async throws {
        let probe = SuspendedRouteProbe()
        let fixture = try fixture(probe: { await probe.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: local) }
        await probe.waitUntilRequested()

        selection.cancel()
        fixture.router.cancelManualSelection()
        await probe.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testAccountChangeWhileProbeWaitsCannotActivateLocal() async throws {
        let probe = SuspendedRouteProbe()
        let fixture = try fixture(probe: { await probe.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: local) }
        await probe.waitUntilRequested()

        fixture.router.activate(external: URL(string: "https://other.example.com/api")!)
        await probe.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertNil(fixture.router.config)
    }

    func testConfigurationChangeWhileProbeWaitsCannotActivateOldLocalURL() async throws {
        let probe = SuspendedRouteProbe()
        let fixture = try fixture(probe: { await probe.answer($0) })
        defer { fixture.cleanUp() }
        let selection = Task { await fixture.router.requestManualLocal(confirmedURL: local) }
        await probe.waitUntilRequested()

        fixture.router.update(LocalServerConfig(server: external, apiURL: URL(string: "http://192.168.50.11:2283/api")!))
        await probe.finish(true)

        let result = await selection.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
    }

    func testManualLANTransportFailureDoesNotFallBackToExternal() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        let errors: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost]
        for method in ["GET", "POST"] {
            for code in errors {
                XCTAssertFalse(ServerRoute.fallBack(from: localAsset, after: URLError(code), method: method))
                XCTAssertEqual(ServerRoute.resolve(externalAsset), localAsset)
            }
        }
    }

    func testExternalButtonSwitchesImmediatelyAndPreservesSavedConfiguration() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.useExternal()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertEqual(fixture.router.status, .external)
        XCTAssertEqual(fixture.router.config?.apiURL, local)
        XCTAssertFalse(fixture.router.isManualLocal)
    }

    func testManualOverrideClearsOnNetworkUpdateEvenWhenGatewayIsUnchanged() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.networkChanged(network: "test-network")
        await Task.yield()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertFalse(fixture.router.isManualLocal)
    }

    func testManualOverrideClearsWhenReturningAfterBackground() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.applicationReturnedToForeground()
        await Task.yield()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertFalse(fixture.router.isManualLocal)
    }

    func testManualOverrideClearsWhenConfigurationChanges() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.update(LocalServerConfig(server: external, apiURL: local, networks: ["Saved Test Network"]))
        await Task.yield()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertFalse(fixture.router.isManualLocal)
    }

    func testLogoutClearsManualOverrideAndSavedAccountConfiguration() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.router.deactivate()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertNil(fixture.router.config)
        XCTAssertEqual(fixture.router.status, .off)
        XCTAssertNil(fixture.defaults.data(forKey: "imora.localServer"))
    }

    func testNewRouterDoesNotRestoreManualOverride() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        let restored = LocalServerRouter(defaults: fixture.defaults, monitoringEnabled: false, probe: { _ in true }, ssidProvider: { nil })
        restored.activate(external: external)
        restored.networkChanged(network: "test-network")
        await Task.yield()

        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        XCTAssertFalse(restored.isManualLocal)
    }

    func testSavedButInactiveLocalURLCannotReceiveAccountCredentials() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")

        assertLocalRequestsRejected(fixture: fixture, context: context)
    }

    func testActiveMatchingLocalRouteCanAuthorizeMediaAndUploadRequests() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        let allowedLocal = ServerRoute.configuredLocal(for: external, defaults: fixture.defaults)
        let media = context.mediaURL(localAsset)
        let mediaRequest = try context.authorize(URLRequest(url: media), localAPIURL: allowedLocal)
        var upload = URLRequest(url: local.appending(path: "assets"))
        upload.httpMethod = "POST"
        let uploadRequest = try context.authorize(upload, localAPIURL: allowedLocal)
        XCTAssertEqual(mediaRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-route-token")
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-route-token")
        XCTAssertNil(mediaRequest.url?.fragment)
    }

    func testExternalChoiceRevokesCapturedLocalMediaAndUploadAuthorization() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)
        let captured = context.mediaURL(ServerRoute.resolve(externalAsset))

        fixture.router.useExternal()

        assertLocalRequestsRejected(fixture: fixture, context: context, capturedMedia: captured)
    }

    func testNetworkUpdateRevokesCapturedLocalMediaAndUploadAuthorization() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)
        let captured = context.mediaURL(ServerRoute.resolve(externalAsset))

        fixture.router.networkChanged(network: "another-test-network")

        assertLocalRequestsRejected(fixture: fixture, context: context, capturedMedia: captured)
    }

    func testForegroundReturnRevokesCapturedLocalMediaAndUploadAuthorization() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)
        let captured = context.mediaURL(ServerRoute.resolve(externalAsset))

        fixture.router.applicationReturnedToForeground()

        assertLocalRequestsRejected(fixture: fixture, context: context, capturedMedia: captured)
    }

    func testSavedAllowlistDoesNotAuthorizeAnotherActiveLocalOrExternalRoot() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        ServerRoute.use(local: URL(string: "http://192.168.50.11:2283/api")!, external: external)
        assertLocalRequestsRejected(fixture: fixture, context: context)

        ServerRoute.use(local: local, external: URL(string: "https://other.example.com/api")!)
        assertLocalRequestsRejected(fixture: fixture, context: context)
    }

    func testInactiveThenActiveDoesNotClearManualRouteOrItsAuthorization() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)

        fixture.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), localAsset)
        XCTAssertEqual(ServerRoute.configuredLocal(for: external, defaults: fixture.defaults), local)
    }

    func testRealBackgroundReturnClearsManualRouteAndRevokesLocalAuthorization() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let context = AccountRequestContext(apiURL: external, token: "test-route-token")
        let result = await fixture.router.requestManualLocal(confirmedURL: local)
        XCTAssertEqual(result, .selected)
        let captured = context.mediaURL(ServerRoute.resolve(externalAsset))

        fixture.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertFalse(fixture.router.isManualLocal)
        XCTAssertEqual(ServerRoute.resolve(externalAsset), externalAsset)
        assertLocalRequestsRejected(fixture: fixture, context: context, capturedMedia: captured)
    }

    private func assertLocalRequestsRejected(
        fixture: RouteFixture,
        context: AccountRequestContext,
        capturedMedia: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let allowedLocal = ServerRoute.configuredLocal(for: external, defaults: fixture.defaults)
        let media = capturedMedia ?? context.mediaURL(localAsset)
        var upload = URLRequest(url: local.appending(path: "assets"))
        upload.httpMethod = "POST"
        XCTAssertNil(context.policy(for: media, localAPIURL: allowedLocal), file: file, line: line)
        XCTAssertThrowsError(try context.authorize(URLRequest(url: media), localAPIURL: allowedLocal), file: file, line: line)
        XCTAssertThrowsError(try context.authorize(upload, localAPIURL: allowedLocal), file: file, line: line)
        XCTAssertNoThrow(try context.authorize(URLRequest(url: externalAsset), localAPIURL: allowedLocal), file: file, line: line)
    }

    private func fixture(
        network: String? = "test-network",
        probe: @escaping @Sendable (URLRequest) async -> Bool = { _ in true }
    ) throws -> RouteFixture {
        try fixture(configuration: LocalServerConfig(server: external, apiURL: local), network: network, probe: probe)
    }

    private func fixture(
        configuration: LocalServerConfig?,
        network: String? = "test-network",
        probe: @escaping @Sendable (URLRequest) async -> Bool = { _ in true }
    ) throws -> RouteFixture {
        let name = "ManualServerRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        if let configuration {
            defaults.set(try JSONEncoder().encode(configuration), forKey: "imora.localServer")
        }
        let notifications = NotificationCenter()
        let router = LocalServerRouter(defaults: defaults, monitoringEnabled: false, notificationCenter: notifications, probe: probe, ssidProvider: { nil })
        router.activate(external: external)
        router.networkChanged(network: network)
        return RouteFixture(router: router, defaults: defaults, suiteName: name, notifications: notifications)
    }
}

@MainActor
private struct RouteFixture {
    let router: LocalServerRouter
    let defaults: UserDefaults
    let suiteName: String
    let notifications: NotificationCenter

    func cleanUp() {
        router.cancelManualSelection()
        ServerRoute.use(local: nil, external: nil)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor RouteRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private actor SuspendedRouteProbe {
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

    func finish(_ answer: Bool) {
        pending?.resume(returning: answer)
        pending = nil
    }
}
