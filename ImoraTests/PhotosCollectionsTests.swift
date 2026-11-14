import Foundation
import XCTest
@testable import Imora

@MainActor
final class PhotosCollectionsTests: XCTestCase {
    func testCollectionsPreferencesDoNotCrossAccountsOrPersistSignedOutChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "photos-collections-\(UUID())"))
        let store = CollectionsLayoutStore(defaults: defaults)
        var layout = CollectionsLayout()
        layout.togglePin("album:family-a")
        layout.toggleCollapsed(.people)
        store.save(layout, account: "account-a")
        XCTAssertTrue(store.load(account: "account-a").pinnedIDs.contains("album:family-a"))
        XCTAssertFalse(store.load(account: "account-b").pinnedIDs.contains("album:family-a"))
        XCTAssertFalse(store.load(account: "account-b").collapsed.contains(.people))
        store.save(layout, account: nil)
        XCTAssertFalse(store.load(account: nil).pinnedIDs.contains("album:family-a"))
    }

    func testPersistedLayoutPreservesValidOrderAndRecoversUnknownDuplicateEntries() throws {
        let data = Data(#"{"sectionIDs":["utilities","albums","future","albums"],"collapsedIDs":["people","future"],"pinnedIDs":["favorites","album:one","album:one","future", "album:"]}"#.utf8)
        let layout = CollectionsLayout.decode(data)
        XCTAssertEqual(Array(layout.sections.prefix(2)), [.utilities, .albums])
        XCTAssertEqual(Set(layout.sections).count, layout.sections.count)
        XCTAssertEqual(Set(layout.sections), Set(CollectionSection.allCases))
        XCTAssertTrue(layout.collapsed.contains(.people))
        XCTAssertEqual(layout.pinnedIDs, ["favorites", "album:one"])
        XCTAssertEqual(CollectionsLayout.decode(Data("invalid".utf8)), CollectionsLayout())
    }

    func testPinningReorderingAndConfirmedAlbumRemovalPreserveOtherPreferences() {
        var layout = CollectionsLayout()
        layout.togglePin("album:one")
        layout.togglePin("album:two")
        layout.moveSections(from: IndexSet(integer: layout.sections.firstIndex(of: .albums)!), to: 0)
        layout.toggleCollapsed(.memories)
        layout.removeAlbum("one")
        XCTAssertEqual(layout.sections.first, .albums)
        XCTAssertFalse(layout.pinnedIDs.contains("album:one"))
        XCTAssertTrue(layout.pinnedIDs.contains("album:two"))
        XCTAssertTrue(layout.collapsed.contains(.memories))
        layout.togglePin("album:two")
        XCTAssertFalse(layout.pinnedIDs.contains("album:two"))
    }

    func testYearAndMonthAggregationIncludesUnloadedBucketsAndTargetsTheRightMonth() {
        let sections = [
            TimelineSection(id: "2026-01-01T00:00:00.000Z", monthTitle: "Jan", count: 12, days: nil),
            TimelineSection(id: "2025-12-01T00:00:00.000Z", monthTitle: "Dec", count: 5, days: nil),
            TimelineSection(id: "2026-02-01T00:00:00.000Z", monthTitle: "Feb", count: 8, days: []),
            TimelineSection(id: "invalid", monthTitle: "Unknown", count: 100, days: nil)
        ]
        let years = PhotoPeriod.years(in: sections)
        XCTAssertEqual(years.map(\.year), [2026, 2025])
        XCTAssertEqual(years.map(\.count), [20, 5])
        let months = PhotoPeriod.months(in: sections, year: 2026)
        XCTAssertEqual(months.map(\.month), [2, 1])
        XCTAssertEqual(months.map(\.count), [8, 12])
        XCTAssertEqual(months.last?.representativeBucketID, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(PhotoPeriod.months(in: sections, year: 2024).count, 0)
    }

    func testGridZoomUsesNativeDensityStepsAndDoesNotGoBelowTwoColumns() {
        let controls = PhotosGridControls()
        controls.zoomOut(viewportWidth: 393)
        XCTAssertEqual(controls.columns, 5)
        controls.zoomIn(viewportWidth: 393)
        XCTAssertEqual(controls.columns, 3)
        controls.zoomIn(viewportWidth: 393)
        controls.zoomIn(viewportWidth: 393)
        XCTAssertEqual(controls.columns, 2)
    }
}
