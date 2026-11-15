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

    private func sampleAsset(date: Date) -> Asset {
        Asset(id: "local-fixture", ownerId: "", isImage: true, isFavorite: false,
              isTrashed: false, visibility: .timeline, thumbhash: nil, fileCreatedAt: date,
              localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1,
              city: nil, country: nil, createdAt: nil, localIdentifier: "fixture")
    }
}
