import Foundation
import XCTest
@testable import Imora

@MainActor
final class PhotoStateConsistencyTests: XCTestCase {
    func testWallClockLabelsDoNotApplyTheDeviceTimezoneTwice() throws {
        let wallClock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-15T10:20:00Z"))
        let old = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 8 * 3600)!
        defer { NSTimeZone.default = old }
        let label = PhotoDatePresentation.dateTime(wallClock: wallClock, locale: Locale(identifier: "zh_CN"))
        XCTAssertTrue(label.contains("10:20"), label)
        XCTAssertFalse(label.contains("18:20"), label)
    }

    func testLocalSearchMatchesAllFilenameAndWallClockDateTerms() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-29T23:30:00Z"))
        let record = LocalPhotoSearchRecord(asset: sampleAsset(date: date), filename: "Beach_Holiday.HEIC")
        XCTAssertTrue(LocalPhotoSearch.matches(record, query: "beach 2024-02-29"))
        XCTAssertTrue(LocalPhotoSearch.matches(record, query: "2024年2月29日"))
        XCTAssertFalse(LocalPhotoSearch.matches(record, query: "beach 2024-03-01"))
        XCTAssertFalse(LocalPhotoSearch.matches(record, query: "mountain"))
    }

    func testPhotographerDateRemainsOnTheCorrectSideOfMidnightAcrossOffsets() throws {
        let parser = ISO8601DateFormatter()
        let cases: [(String, Double, String, String)] = [
            ("2026-01-01T18:30:00Z", 8, "2026-01-02", "02:30"),
            ("2026-01-01T02:30:00Z", -5, "2025-12-31", "21:30"),
            ("2026-01-01T00:15:00Z", 0, "2026-01-01", "00:15")
        ]
        for (utc, offset, date, time) in cases {
            var asset = sampleAsset(date: try XCTUnwrap(parser.date(from: utc)))
            asset.localOffsetHours = offset
            let tokens = PhotoDatePresentation.searchDates(wallClock: asset.localDate)
            XCTAssertTrue(tokens.contains(date), tokens.description)
            XCTAssertTrue(PhotoDatePresentation.dateTime(wallClock: asset.localDate,
                locale: Locale(identifier: "zh_CN")).contains(time))
        }
    }

    func testSearchSourceDefaultsAndInheritedDeviceScopeAreExplicit() {
        XCTAssertEqual(PhotoSearchSource(librarySource: "local"), .device)
        XCTAssertEqual(PhotoSearchSource(librarySource: "cloud"), .cloud)
        XCTAssertEqual(PhotoSearchSource(librarySource: "unknown"), .cloud)
    }

    func testFavoriteIntentSurvivesRelaunchAndIsolatesAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorites.json")
        let store = FavoriteIntentStore(url: url)
        _ = try store.record(account: "A", remoteID: "photo", localID: "device", value: true)
        _ = try store.record(account: "B", remoteID: "photo", localID: nil, value: false)
        let reloaded = FavoriteIntentStore(url: url)
        XCTAssertEqual(reloaded.pending(account: "A").map(\.value), [true])
        XCTAssertEqual(reloaded.pending(account: "B").map(\.value), [false])
        XCTAssertTrue(reloaded.pending(account: "C").isEmpty)
    }

    func testFavoriteAccountIdentitySurvivesTokenRotationWithoutCrossingUsersOrServers() {
        let first = FavoriteAccountIdentity.key(server: "https://one/api", userID: "A", credentialScope: "token-one")
        XCTAssertEqual(first, FavoriteAccountIdentity.key(server: "https://one/api", userID: "A", credentialScope: "token-two"))
        XCTAssertNotEqual(first, FavoriteAccountIdentity.key(server: "https://one/api", userID: "B", credentialScope: "token-one"))
        XCTAssertNotEqual(first, FavoriteAccountIdentity.key(server: "https://two/api", userID: "A", credentialScope: "token-one"))
        XCTAssertNil(FavoriteAccountIdentity.key(server: "https://one/api", userID: nil, credentialScope: nil))
    }

    func testConfirmedIdentityMigratesOnlyTheCurrentProvisionalAccountQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        _ = try store.record(account: "credential:current", remoteID: "photo", localID: "local", value: true)
        _ = try store.record(account: "credential:other", remoteID: "photo", localID: nil, value: false)
        try store.confirmAccount(credentialScope: "credential:current", account: "server|user:A")
        XCTAssertTrue(store.pending(account: "credential:current").isEmpty)
        XCTAssertEqual(store.pending(account: "server|user:A").map(\.value), [true])
        XCTAssertEqual(store.pending(account: "credential:other").map(\.value), [false])
    }

    func testLateFavoriteAcknowledgementCannotEraseNewerIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        let older = try store.record(account: "A", remoteID: "photo", localID: "device", value: true)
        let newer = try store.record(account: "A", remoteID: "photo", localID: "device", value: false)
        try store.acknowledge(older)
        XCTAssertEqual(store.pending(account: "A"), [newer])
        try store.acknowledge(newer)
        XCTAssertTrue(store.pending(account: "A").isEmpty)
    }

    func testAcceptedDeviceFavoriteSurvivesCloudFailureAndRetriesOnlyItsAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        let transport = FavoriteTestTransport()
        let local = FavoriteTestDevice()
        let coordinator = PhotoFavoriteCoordinator(account: "A", store: store,
            writeLocal: { id, value in await local.set(id, value) },
            writeRemote: { id, value in try await transport.set(id, value) })
        let outcome = try await coordinator.set(localID: "device", remoteID: "remote", value: true)
        await coordinator.flush()
        let localValue = await local.value("device")
        XCTAssertEqual(localValue, true)
        XCTAssertTrue(outcome.localCommitted)
        XCTAssertEqual(store.pending(account: "A").map(\.value), [true])
        _ = try store.record(account: "B", remoteID: "other", localID: nil, value: false)
        await transport.recover()
        await coordinator.flush()
        XCTAssertTrue(store.pending(account: "A").isEmpty)
        XCTAssertEqual(store.pending(account: "B").count, 1)
        coordinator.shutdown()
        do {
            _ = try await coordinator.set(localID: "afterLogout", remoteID: nil, value: true)
            XCTFail("An inactive account cannot start a PhotoKit mutation")
        } catch {}
        let afterLogout = await local.value("afterLogout")
        XCTAssertNil(afterLogout)
    }

    func testDeviceStillActionsDoNotRequireAnExistingCloudCopy() {
        let asset = sampleAsset(date: .distantPast)
        let local = AssetActionAvailability(asset: asset, ownsAsset: true)
        XCTAssertTrue(local.canFavorite)
        XCTAssertTrue(local.canEdit)
        XCTAssertTrue(local.canAddToAlbum)
        XCTAssertTrue(local.canBackUp)
        XCTAssertFalse(local.canShareLink)
        var live = asset
        live.hasLocalMotion = true
        XCTAssertFalse(AssetActionAvailability(asset: live, ownsAsset: true).canEdit)
    }

    func testSlowFirstPhotoKitWriteCannotOverwriteTheLatestFavoriteIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        let local = FavoriteTestDevice(delayFirstWrite: true)
        let coordinator = PhotoFavoriteCoordinator(account: "A", store: store,
            writeLocal: { id, value in await local.set(id, value) },
            writeRemote: { _, _ in throw URLError(.notConnectedToInternet) })
        let first = Task { try await coordinator.set(localID: "device", remoteID: "remote", value: true) }
        for _ in 0..<100 {
            if await local.startedWrites > 0 { break }
            await Task.yield()
        }
        let last = Task { try await coordinator.set(localID: "device", remoteID: "remote", value: false) }
        _ = try await first.value
        _ = try await last.value
        let localValue = await local.value("device")
        XCTAssertEqual(localValue, false)
        XCTAssertEqual(store.pending(account: "A").map(\.value), [false])
        coordinator.shutdown()
    }

    func testFailedFavoriteDoesNotBlockTheOtherPhotosInTheSameRetryPass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        _ = try store.record(account: "A", remoteID: "deleted", localID: nil, value: true)
        _ = try store.record(account: "A", remoteID: "healthy", localID: nil, value: true)
        let coordinator = PhotoFavoriteCoordinator(account: "A", store: store,
            writeLocal: { _, _ in }, writeRemote: { id, _ in
                if id == "deleted" { throw URLError(.resourceUnavailable) }
            })
        await coordinator.flush()
        XCTAssertEqual(store.pending(account: "A").map(\.remoteID), ["deleted"])
        XCTAssertTrue(coordinator.syncFailed)
        coordinator.shutdown()
    }

    func testIdentityPromotionWaitsForAcceptedLocalWritesBeforeMigratingTheirIntents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteIntentStore(url: directory.appendingPathComponent("favorites.json"))
        let device = FavoriteTestDevice(delayFirstWrite: true)
        let coordinator = PhotoFavoriteCoordinator(account: "credential:current", store: store,
            writeLocal: { id, value in await device.set(id, value) },
            writeRemote: { _, _ in throw URLError(.notConnectedToInternet) })
        let write = Task { try await coordinator.set(localID: "device", remoteID: "remote", value: true) }
        while await device.startedWrites == 0 { await Task.yield() }
        let promotion = Task {
            await coordinator.waitUntilIdle()
            try store.confirmAccount(credentialScope: coordinator.account, account: "server|user:A")
            coordinator.shutdown()
        }
        _ = try await write.value
        try await promotion.value
        XCTAssertTrue(store.pending(account: "credential:current").isEmpty)
        XCTAssertEqual(store.pending(account: "server|user:A").map(\.value), [true])
    }

    private func sampleAsset(date: Date) -> Asset {
        Asset(id: "local-fixture", ownerId: "", isImage: true, isFavorite: false,
              isTrashed: false, visibility: .timeline, thumbhash: nil, fileCreatedAt: date,
              localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1,
              city: nil, country: nil, createdAt: nil, localIdentifier: "fixture")
    }
}

private actor FavoriteTestTransport {
    private var fails = true
    func set(_ id: String, _ value: Bool) throws {
        if fails { throw URLError(.notConnectedToInternet) }
    }
    func recover() { fails = false }
}

private actor FavoriteTestDevice {
    private var values: [String: Bool] = [:]
    private let delayFirstWrite: Bool
    private(set) var startedWrites = 0
    init(delayFirstWrite: Bool = false) { self.delayFirstWrite = delayFirstWrite }
    func set(_ id: String, _ value: Bool) async {
        startedWrites += 1
        if delayFirstWrite && startedWrites == 1 { try? await Task.sleep(for: .milliseconds(50)) }
        values[id] = value
    }
    func value(_ id: String) -> Bool? { values[id] }
}
