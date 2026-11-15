import Foundation
import XCTest
@testable import Imora

@MainActor
final class PhotoMonthContentTests: XCTestCase {
    func testEveryCaptureDaySurvivesFragmentedBucketsAndDuplicateAssets() throws {
        let first = photo("first", "2026-04-01T08:00:00Z")
        let second = photo("second", "2026-04-15T08:00:00Z")
        let third = photo("third", "2026-04-30T08:00:00Z")
        let sections = [section("a", [third, first]), section("b", [second, first])]
        let content = try content(sections)
        XCTAssertEqual(content.days.map(\.id), ["2026-04-01", "2026-04-15", "2026-04-30"])
        XCTAssertEqual(content.days.flatMap(\.assets).map(\.id), ["first", "second", "third"])
        XCTAssertEqual(content.loadedAssetCount, 3)
        XCTAssertEqual(content.completeDayCount, 3)
        XCTAssertTrue(content.isComplete)
        XCTAssertEqual(content.days[1].coverBucketID, sections[1].id)
    }

    func testUsesPhotographerWallClockInsteadOfUploadDateOrExistingDayLabel() throws {
        var afterMidnight = photo("after", "2026-04-14T20:30:00Z", offset: 5.5)
        afterMidnight.createdAt = date("2026-11-01T08:00:00Z")
        let sameDay = photo("same", "2026-04-15T12:00:00Z")
        let beforeMidnight = photo("before", "2026-04-15T01:30:00Z", offset: -7)
        let content = try content([section("a", [sameDay, afterMidnight, beforeMidnight])])
        XCTAssertEqual(content.days.map(\.id), ["2026-04-14", "2026-04-15"])
        XCTAssertEqual(content.days[1].assets.map(\.id), ["after", "same"])
        XCTAssertEqual(content.days[0].assets.map(\.id), ["before"])
    }

    func testPreferredPhotoAndRetainedCoverKeepExactAssetAndSourceBucket() throws {
        let early = photo("early", "2026-04-15T08:00:00Z")
        let late = photo("late", "2026-04-15T16:00:00Z")
        let sections = [section("a", [early]), section("b", [late])]
        let retained = try content(sections, retained: ["2026-04-15": "early"])
        XCTAssertEqual(retained.days.first?.cover.id, "early")
        XCTAssertEqual(retained.days.first?.coverBucketID, sections[0].id)
        let preferred = try content(sections, preferred: "late", retained: ["2026-04-15": "early"])
        XCTAssertEqual(preferred.days.first?.cover.id, "late")
        XCTAssertEqual(preferred.days.first?.coverBucketID, sections[1].id)
        let reordered = try content(Array(sections.reversed()))
        XCTAssertEqual(reordered.days.first?.cover.id, try content(sections).days.first?.cover.id)
        let removed = try content([section("b", [late])], preferred: "removed", retained: ["2026-04-15": "early"])
        XCTAssertEqual(removed.days.first?.cover.id, "late")
        let repeated = [section("a", [early]), section("b", [early])]
        let anchoredSource = try content(repeated, preferred: "early", preferredBucket: repeated[1].id)
        XCTAssertEqual(anchoredSource.days.first?.coverBucketID, repeated[1].id)
    }

    func testUnloadedBucketsStayUnknownEvenWhenAnotherBucketHasACover() throws {
        let loaded = section("a", [photo("one", "2026-04-15T08:00:00Z")])
        let missing = TimelineSection(id: "2026-04-01-unloaded", monthTitle: "April", count: 7, days: nil)
        let content = try content([loaded, missing])
        XCTAssertFalse(content.isComplete)
        XCTAssertNil(content.completeDayCount)
        XCTAssertEqual(content.loadedAssetCount, 1)
        XCTAssertEqual(content.missingBucketIDs, [missing.id])
        XCTAssertEqual(content.indexedAssetCount, 8)
        XCTAssertEqual(content.days.count, 1, "Known days remain available without pretending the unknown bucket is empty")
    }

    func testRemovedBucketDoesNotBecomeCompleteEmptyContent() throws {
        let sections = [section("a", [photo("one", "2026-04-15T08:00:00Z")])]
        let period = try XCTUnwrap(PhotoPeriod.months(in: sections).first)
        let content = PhotoMonthContent(period: period, sections: [])
        XCTAssertEqual(content.missingBucketIDs, [sections[0].id])
        XCTAssertFalse(content.isComplete)
        XCTAssertNil(content.completeDayCount)
        XCTAssertTrue(content.days.isEmpty)
    }

    func testLoadedEmptyMonthIsDistinctFromUnknownAndNoCaptureDayIsDiscarded() throws {
        let empty = TimelineSection(id: "2026-04-01-empty", monthTitle: "April", count: 1, days: [])
        XCTAssertEqual(try content([empty]).completeDayCount, 0)
        // Preserve real assets even if a server/source bucket's month differs;
        // the caller must resolve the index mismatch, rather than lose photos.
        let mismatch = try content([section("a", [photo("edge", "2026-03-31T23:30:00Z")])])
        XCTAssertEqual(mismatch.days.first?.id, "2026-03-31")
        XCTAssertTrue(mismatch.hasCaptureMonthMismatch)
    }

    private func content(_ sections: [TimelineSection], preferred: String? = nil,
                         preferredBucket: String? = nil, retained: [String: String] = [:]) throws -> PhotoMonthContent {
        let period = try XCTUnwrap(PhotoPeriod.months(in: sections).first)
        return PhotoMonthContent(period: period, sections: sections,
                                 preferredAssetID: preferred, preferredBucketID: preferredBucket, retainedCoverIDs: retained)
    }

    private func section(_ suffix: String, _ assets: [Asset]) -> TimelineSection {
        TimelineSection(id: "2026-04-01-\(suffix)", monthTitle: "April", count: assets.count,
                        days: [DayGroup(id: "upload-day-not-capture-day", title: "Uploaded today", assets: assets)])
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func photo(_ id: String, _ value: String, offset: Double = 0) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
              visibility: .timeline, thumbhash: nil, fileCreatedAt: date(value), localOffsetHours: offset,
              duration: nil, livePhotoVideoId: nil, ratio: 1.5, city: nil, country: nil, createdAt: nil)
    }
}
