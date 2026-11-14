import XCTest
@testable import Imora

final class CleanupRetentionPolicyTests: XCTestCase {
    func testNaturalDayBoundaryIncludesTodayAndStrictlyPreservesCutoff() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T18:00:00Z"))
        let policy = CleanupRetentionPolicy(retentionDays: 7)
        let snapshot = policy.snapshot(at: now, timeZone: zone)
        let cutoff = try XCTUnwrap(snapshot.cutoff)
        XCTAssertEqual(cutoff, ISO8601DateFormatter().date(from: "2026-03-03T08:00:00Z"))
        XCTAssertTrue(snapshot.reasons(creationDate: cutoff, isFavorite: false, protectedAlbumMember: false).contains(.recent))
        XCTAssertTrue(snapshot.reasons(creationDate: cutoff.addingTimeInterval(-1), isFavorite: false, protectedAlbumMember: false).isEmpty)
    }

    func testUnknownDateAndOverlappingReasonsRemainProtected() {
        let snapshot = CleanupRetentionPolicy().snapshot()
        XCTAssertEqual(snapshot.reasons(creationDate: nil, isFavorite: false, protectedAlbumMember: false), [.unknownDate])
        XCTAssertEqual(snapshot.reasons(creationDate: Date(), isFavorite: true, protectedAlbumMember: true), [.recent, .favorite, .album])
    }

    func testNoTimeRetentionStillPreservesUnknownDatesFavoritesAndAlbums() {
        let snapshot = CleanupRetentionPolicy(retentionDays: nil, protectedAlbumIDs: ["album"]).snapshot()
        XCTAssertNil(snapshot.cutoff)
        XCTAssertEqual(snapshot.reasons(creationDate: .distantPast, isFavorite: true, protectedAlbumMember: true), [.favorite, .album])
        XCTAssertEqual(snapshot.reasons(creationDate: nil, isFavorite: false, protectedAlbumMember: false), [.unknownDate])
    }

    func testCustomCutoffAndSnapshotDoNotMoveAfterPreview() throws {
        let custom = Date(timeIntervalSince1970: 1_000)
        let snapshot = CleanupRetentionPolicy(retentionDays: nil, customStartDate: custom, preserveFavorites: false).snapshot()
        XCTAssertEqual(snapshot.cutoff, custom)
        XCTAssertEqual(snapshot.reasons(creationDate: custom, isFavorite: true, protectedAlbumMember: false), [.recent])
        XCTAssertTrue(snapshot.reasons(creationDate: custom.addingTimeInterval(-1), isFavorite: true, protectedAlbumMember: false).isEmpty)
    }
}
