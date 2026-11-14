import Foundation
import XCTest
@testable import Imora

@MainActor
final class AppUpdateStoreTests: XCTestCase {
    func testManualCurrentVersionCheckRequestsFeedbackOnEveryTap() async throws {
        let service = UpdateServiceFixture(status: try status())
        for (version, build) in [("1.0.1", "2"), ("1.0.1", "3"), ("1.1.0", "1")] {
            let store = AppUpdateStore(service: service, installedVersion: version, installedBuild: build)
            for _ in 0..<2 {
                let result = await store.checkForUpdates()
                XCTAssertEqual(result, true, "A successful explicit check must acknowledge the current version")
                XCTAssertNil(store.availableRelease)
            }
        }
    }

    func testAutomaticCurrentVersionCheckDoesNotRequestFeedback() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0.1", installedBuild: "2")
        let result = await store.checkForUpdates(automatically: true)
        XCTAssertEqual(result, false)
    }

    func testNewerPreparedVersionDoesNotRequestCurrentVersionFeedback() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        let result = await store.checkForUpdates()
        XCTAssertEqual(result, false)
        XCTAssertNotNil(store.availableRelease)
    }

    func testFailedCheckDoesNotReusePreviousCurrentVersionResult() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0.1", installedBuild: "2")
        _ = await store.checkForUpdates()
        await service.setFailure(true)
        let result = await store.checkForUpdates()
        XCTAssertEqual(result, false)
        XCTAssertNotNil(store.failureMessage)
        XCTAssertNil(store.status)
    }

    func testBusyFailedAndInvalidInstallationsDoNotRequestCurrentVersionFeedback() async throws {
        for installation in [
            AppUpdateInstallation(state: .queued, releaseId: "release-2", messageCode: nil),
            .init(state: .installing, releaseId: "release-2", messageCode: nil),
            .init(state: .failed, releaseId: "release-2", messageCode: .invalidPackage),
            .init(state: .failed, releaseId: "release-2", messageCode: .needsPhone),
            .init(state: .idle, releaseId: nil, messageCode: .busy),
            .init(state: .succeeded, releaseId: nil, messageCode: nil)
        ] {
            let value = try status()
            let service = UpdateServiceFixture(status: AppUpdateStatus(schemaVersion: 1, hostId: value.hostId,
                latest: value.latest, installation: installation))
            let store = AppUpdateStore(service: service, installedVersion: "1.0.1", installedBuild: "2")
            let result = await store.checkForUpdates()
            XCTAssertEqual(result, false, "\(installation)")
        }
    }

    func testMissingAndInvalidMetadataDoNotRequestCurrentVersionFeedback() async throws {
        let invalidReleases: [AppUpdateRelease?] = [nil,
            .init(releaseId: "release-2", version: "latest", build: "2", notes: ""),
            .init(releaseId: "../release", version: "1.0.1", build: "2", notes: "")]
        for release in invalidReleases {
            let service = UpdateServiceFixture(status: .init(schemaVersion: 1, hostId: "fixture-mac",
                latest: release, installation: nil))
            let store = AppUpdateStore(service: service, installedVersion: "1.0.1", installedBuild: "2")
            let result = await store.checkForUpdates()
            XCTAssertEqual(result, false)
        }
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "unknown", installedBuild: "2")
        let result = await store.checkForUpdates()
        XCTAssertEqual(result, false)
    }

    func testCompletedInstallationRequiresInstalledVersionToBeCurrent() async throws {
        let value = try status()
        let service = UpdateServiceFixture(status: .init(schemaVersion: 1, hostId: value.hostId,
            latest: value.latest, installation: .init(state: .succeeded, releaseId: "release-2", messageCode: nil)))
        let old = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        let oldResult = await old.checkForUpdates()
        XCTAssertEqual(oldResult, false)
        let current = AppUpdateStore(service: service, installedVersion: "1.0.1", installedBuild: "2")
        let currentResult = await current.checkForUpdates()
        XCTAssertEqual(currentResult, true)
    }

    func testUnconfiguredCheckDoesNotRequestCurrentVersionFeedback() async {
        let store = AppUpdateStore(service: nil, installedVersion: "1.0.1", installedBuild: "2")
        let result = await store.checkForUpdates()
        XCTAssertEqual(result, false)
    }

    func testUnconfiguredSourceBuildHasNoInstallOffer() async {
        let store = AppUpdateStore(service: nil, installedVersion: "1.0", installedBuild: "1")
        await store.checkForUpdates()
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.availableRelease)
        XCTAssertNil(store.alertRelease)
    }

    func testCheckingAndLaterNeverRequestInstallation() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        await store.checkForUpdates(automatically: true, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(store.availableRelease?.releaseId, "release-2")
        XCTAssertEqual(store.alertRelease?.releaseId, "release-2")
        store.dismissUpdateAlert()
        XCTAssertNil(store.alertRelease)
        let calls = await service.calls()
        XCTAssertEqual(calls.checks, 1)
        XCTAssertTrue(calls.installs.isEmpty)
    }

    func testExplicitConfirmationRechecksThenRequestsExactlyTheConfirmedRelease() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        await store.checkForUpdates()
        let release = try XCTUnwrap(store.availableRelease)
        await store.confirmInstallation(of: release)
        let calls = await service.calls()
        XCTAssertEqual(calls.checks, 2)
        XCTAssertEqual(calls.installs, ["release-2"])
        XCTAssertEqual(store.status?.installation?.state, .queued)
        XCTAssertNil(store.availableRelease)
    }

    func testConcurrentConfirmationQueuesOnlyOnce() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        let unconfirmed = try XCTUnwrap(try status().latest)
        await store.confirmInstallation(of: unconfirmed)
        var calls = await service.calls()
        XCTAssertEqual(calls.checks, 0)
        XCTAssertTrue(calls.installs.isEmpty)
        await store.checkForUpdates()
        let release = try XCTUnwrap(store.availableRelease)
        let first = Task { await store.confirmInstallation(of: release) }
        let second = Task { await store.confirmInstallation(of: release) }
        await first.value
        await second.value
        calls = await service.calls()
        XCTAssertEqual(calls.installs, ["release-2"])
    }

    func testEqualOlderBusyAndInvalidPackagesHaveNoInstallOffer() async throws {
        let inputs = [
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"1.0","build":"1","notes":""},"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"0.9.0","build":"9","notes":""},"installation":null}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"1.0.1","build":"2","notes":""},"installation":{"state":"installing","releaseId":"release-2"}}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"1.0.1","build":"2","notes":""},"installation":{"state":"failed","messageCode":"invalidPackage"}}"#,
            #"{"schemaVersion":1,"hostId":"fixture-mac","latest":{"releaseId":"release-2","version":"1.0.1","build":"2","notes":""},"installation":{"state":"succeeded","releaseId":"release-2"}}"#
        ]
        for input in inputs {
            let service = UpdateServiceFixture(status: try AppUpdateStatus.decode(Data(input.utf8), expectedHostID: "fixture-mac"))
            let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
            await store.checkForUpdates(automatically: true)
            XCTAssertNil(store.availableRelease)
            XCTAssertNil(store.alertRelease)
            let calls = await service.calls()
            XCTAssertTrue(calls.installs.isEmpty)
        }
    }

    func testChangedReleaseOrNetworkFailureAtConfirmationDoesNotPost() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        await store.checkForUpdates()
        let release = try XCTUnwrap(store.availableRelease)
        await service.setStatus(try AppUpdateStatus.decode(Data(#"{"schemaVersion":1,"hostId":"fixture-mac","latest":null,"installation":null}"#.utf8), expectedHostID: "fixture-mac"))
        await store.confirmInstallation(of: release)
        var calls = await service.calls()
        XCTAssertTrue(calls.installs.isEmpty)
        await service.setStatus(try status())
        await store.checkForUpdates()
        await service.setFailure(true)
        await store.confirmInstallation(of: release)
        calls = await service.calls()
        XCTAssertTrue(calls.installs.isEmpty)
        XCTAssertNil(store.availableRelease)
    }

    func testForegroundChecksHaveCooldownAndLaterSuppressesRepeatedPrompts() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        let start = Date(timeIntervalSince1970: 1_000)
        await store.checkForUpdates(automatically: true, now: start)
        store.dismissUpdateAlert()
        await store.checkForUpdates(automatically: true, now: start.addingTimeInterval(5))
        var calls = await service.calls()
        XCTAssertEqual(calls.checks, 1)
        await store.checkForUpdates(automatically: true, now: start.addingTimeInterval(901))
        calls = await service.calls()
        XCTAssertEqual(calls.checks, 2)
        XCTAssertNil(store.alertRelease)
        await store.checkForUpdates(automatically: true, now: start.addingTimeInterval(86_401))
        XCTAssertEqual(store.alertRelease?.releaseId, "release-2")
        calls = await service.calls()
        XCTAssertTrue(calls.installs.isEmpty)
    }

    func testLaterSuppressionSurvivesRelaunchWhileManualCheckStillWorks() async throws {
        let suite = "AppUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = UpdateServiceFixture(status: try status())
        let start = Date(timeIntervalSince1970: 1_000)
        let first = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1", hostID: "fixture-mac", defaults: defaults)
        await first.checkForUpdates(automatically: true, now: start)
        first.dismissUpdateAlert()
        let relaunched = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1", hostID: "fixture-mac", defaults: defaults)
        await relaunched.checkForUpdates(automatically: true, now: start.addingTimeInterval(5))
        XCTAssertNil(relaunched.alertRelease)
        await relaunched.checkForUpdates(now: start.addingTimeInterval(6))
        XCTAssertNotNil(relaunched.availableRelease)
        let calls = await service.calls()
        XCTAssertTrue(calls.installs.isEmpty)
    }

    func testAutomaticFailureDoesNotShowAnAlertAndClearsStaleInstallOffer() async throws {
        let service = UpdateServiceFixture(status: try status())
        let store = AppUpdateStore(service: service, installedVersion: "1.0", installedBuild: "1")
        await store.checkForUpdates()
        XCTAssertNotNil(store.availableRelease)
        await service.setFailure(true)
        await store.checkForUpdates(automatically: true)
        XCTAssertNil(store.availableRelease)
        XCTAssertNil(store.alertRelease)
        let calls = await service.calls()
        XCTAssertTrue(calls.installs.isEmpty)
    }

    private func status() throws -> AppUpdateStatus {
        try AppUpdateStatus.decode(updateStatusData(), expectedHostID: "fixture-mac")
    }
}

private actor UpdateServiceFixture: AppUpdateServicing {
    private var value: AppUpdateStatus
    private var failing = false
    private var checkCount = 0
    private var installed: [String] = []

    init(status: AppUpdateStatus) { value = status }
    func setStatus(_ value: AppUpdateStatus) { self.value = value }
    func setFailure(_ value: Bool) { failing = value }
    func calls() -> (checks: Int, installs: [String]) { (checkCount, installed) }
    func status() async throws -> AppUpdateStatus {
        checkCount += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return value
    }
    func install(releaseID: String, requestID: UUID) async throws -> AppUpdateInstallation {
        installed.append(releaseID)
        return .init(state: .queued, releaseId: releaseID, messageCode: nil)
    }
}
