import Foundation
import SwiftUI
import XCTest
@testable import Imora

@MainActor
final class PhotosCollectionsTests: XCTestCase {
    func testCompactGridFillsRowsAcrossMonthBoundariesWhenZoomedOut() {
        let assets = (0..<9).map { index in
            Asset(id: "month-\(index)", ownerId: "fixture", isImage: true, isFavorite: false,
                  isTrashed: false, visibility: .timeline, thumbhash: nil,
                  fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index / 3) * 40 * 86_400),
                  localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1,
                  city: nil, country: nil, createdAt: nil)
        }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: assets)
        model.columns = 5
        model.showsDateHeaders = false
        XCTAssertEqual(model.tileRowCount, 2)
        XCTAssertEqual(model.sectionSpans.reduce(0) { $0 + $1.tileRows }, 2)
        let rows = model.rows.compactMap { row -> [Asset]? in
            if case .tiles(_, let runs) = row { return runs.flatMap(\.assets) }
            return nil
        }
        XCTAssertEqual(rows.map(\.count), [5, 4])
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), assets.map(\.id))
    }

    func testUnsupportedCollectionsCannotBePinned() {
        let availability = CollectionsAvailability(people: false, trash: false, duplicates: false, cleanup: false)
        for id in ["people", "trash", "duplicates", "cleanup"] { XCTAssertFalse(availability.allows(id)) }
        for id in ["favorites", "recent", "places", "archive", "locked", "largeFiles"] { XCTAssertTrue(availability.allows(id)) }
        XCTAssertTrue(CollectionsAvailability().allows("cleanup"))
    }

    func testPlacesPreviewSeparatesNearbyPhotoLocationsWithoutShowingDistantOutliers() throws {
        let markers = [
            MapMarker(id: "west", lat: 37.78, lon: -122.48, city: nil, state: nil, country: nil),
            MapMarker(id: "east", lat: 37.78, lon: -122.42, city: nil, state: nil, country: nil),
            MapMarker(id: "east-again", lat: 37.78, lon: -122.42, city: nil, state: nil, country: nil),
            MapMarker(id: "outlier", lat: 51.51, lon: -0.13, city: nil, state: nil, country: nil)
        ]
        for height in [160.0, 220.0] {
            let preview = try XCTUnwrap(MapClustering.preview(markers: markers, size: CGSize(width: 350, height: height)))
            XCTAssertEqual(Set(preview.clusters.map(\.id)), ["east", "west"])
            XCTAssertEqual(preview.clusters.map(\.count), [2, 1])
        }
    }

    func testFailedAlbumRemovalReturnsToItsOriginalParentOnly() {
        var state = AlbumRemovalNavigation()
        var allAlbums = NavigationPath()
        allAlbums.append("all-albums")
        var detail = allAlbums
        detail.append("album-one")
        state.record(id: "one", path: detail)
        XCTAssertTrue(state.shouldReopen(id: "one", current: allAlbums))
        state.record(id: "one", path: detail)
        XCTAssertFalse(state.shouldReopen(id: "one", current: NavigationPath()))
        state.record(id: "one", path: detail)
        state.commit(id: "one")
        XCTAssertFalse(state.shouldReopen(id: "one", current: allAlbums))
        var rootDetail = NavigationPath()
        rootDetail.append("album-two")
        state.record(id: "two", path: rootDetail)
        XCTAssertTrue(state.shouldReopen(id: "two", current: NavigationPath()))
    }

    func testMediaSearchRefreshesAfterRealtimeChangesWithoutChangingItsFilter() async throws {
        actor Calls {
            var count = 0
            func next() { count += 1 }
        }
        let calls = Calls()
        let model = SearchModel(search: { _, _ in
            await calls.next()
            return (SearchResponse(albums: nil, assets: SearchAssetPage(count: 0, items: [], nextPage: nil, nextCursor: nil)), nil)
        })
        var filter = SearchFilter()
        filter.mediaType = .video
        model.apply(filter)
        for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let before = model.queryRevision
        let listener: any RealtimeListener = model
        listener.realtimeResync()
        for _ in 0..<100 {
            if await calls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertGreaterThan(model.queryRevision, before)
        XCTAssertEqual(model.filter, filter)
    }

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

    func testCompactTimelineKeepsEveryPhotoWhenDateBandsAreHiddenAndRestored() {
        let assets = (0..<4).map { index in
            Asset(id: "compact-\(index)", ownerId: "fixture", isImage: true, isFavorite: false,
                  isTrashed: false, visibility: .timeline, thumbhash: nil,
                  fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index / 2) * 86_400),
                  localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1,
                  city: nil, country: nil, createdAt: nil)
        }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: assets)
        model.columns = 3
        model.showsDateHeaders = false
        XCTAssertEqual(model.flatAssets.map(\.id), assets.map(\.id))
        XCTAssertEqual(model.titleBandCount, 0)
        XCTAssertEqual(model.tileRowCount, 2)
        model.showsDateHeaders = true
        XCTAssertEqual(Set(model.flatAssets.map(\.id)), Set(assets.map(\.id)))
        XCTAssertGreaterThan(model.titleBandCount, 0)
    }

    func testLivePhotoSearchSendsMotionFilterInBothServerQueryShapes() throws {
        var filter = SearchFilter()
        filter.mediaType = .image
        filter.isMotion = true
        XCTAssertTrue(filter.hasFilters)
        for supportsV2 in [false, true] {
            let request = SearchRequest(filter: filter, token: nil, supportsV2: supportsV2)
            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if supportsV2 {
                let tree = try XCTUnwrap(object["filter"] as? [String: Any])
                XCTAssertEqual((tree["isMotion"] as? [String: Bool])?["eq"], true)
                XCTAssertEqual((tree["type"] as? [String: String])?["eq"], "IMAGE")
            } else {
                XCTAssertEqual(object["isMotion"] as? Bool, true)
                XCTAssertEqual(object["type"] as? String, "IMAGE")
            }
        }
    }
}
