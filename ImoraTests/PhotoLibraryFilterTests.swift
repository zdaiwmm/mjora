import Foundation
import XCTest
@testable import Imora

@MainActor
final class PhotoLibraryFilterTests: XCTestCase {
    func testCloudUnfiledResultsRefreshWhenAlbumMembershipChanges() async throws {
        actor Calls {
            var count = 0
            func next() { count += 1 }
        }
        let calls = Calls()
        let search = SearchModel(search: { _, _ in
            await calls.next()
            return (SearchResponse(albums: nil, assets: SearchAssetPage(count: 0, items: [], nextPage: nil, nextCursor: nil)), nil)
        })
        var filter = SearchFilter()
        filter.notInAlbum = true
        search.apply(filter, allowEmpty: true)
        for _ in 0..<100 where search.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let before = await calls.count
        search.realtimeAlbumsChanged()
        for _ in 0..<100 {
            if await calls.count > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = await calls.count
        XCTAssertEqual(after, before + 1)
        XCTAssertTrue(search.filter.notInAlbum)
    }

    private func asset(_ id: String, edited: Bool? = nil, localID: String? = nil, backedUp: Bool = false) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
              visibility: .timeline, thumbhash: nil, fileCreatedAt: .distantPast, localOffsetHours: 0,
              duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil,
              localIdentifier: localID, isLocalBackedUp: backedUp, isEdited: edited)
    }

    func testExactPredicatesExcludeUnknownMetadataAndResetToAll() {
        var known = asset("known", edited: true)
        known.isScreenshot = true
        known.isInAppAlbum = false
        for filter in [PhotoMediaFilter.edited, .screenshots, .notInAlbum] {
            XCTAssertTrue(filter.includes(known))
            XCTAssertFalse(filter.includes(asset("unknown")))
        }
        known.isEdited = false
        known.isScreenshot = false
        known.isInAppAlbum = true
        for filter in [PhotoMediaFilter.edited, .screenshots, .notInAlbum] { XCTAssertFalse(filter.includes(known)) }
        XCTAssertTrue(PhotoMediaFilter.all.includes(known))
        XCTAssertFalse(PhotoMediaFilter.screenshots.isAvailable(onDevice: false))
        XCTAssertTrue(PhotoMediaFilter.screenshots.isAvailable(onDevice: true))
    }

    func testScreenshotSubtypeAndUnbackedAlbumStateSurviveDeviceProjection() {
        let device = DeviceAsset(localIdentifier: "screen", isVideo: false, isLivePhoto: false, isScreenshot: true,
            creationDate: .distantPast, modificationDate: .distantPast, isFavorite: false,
            durationMs: 0, pixelWidth: 10, pixelHeight: 20)
        XCTAssertEqual(device.asAsset(backedUp: false).isScreenshot, true)
        XCTAssertEqual(device.asAsset(backedUp: false).isInAppAlbum, false)
        XCTAssertNil(device.asAsset(backedUp: true).isInAppAlbum)
    }

    func testNotInAlbumUsesActualServerPredicateInBothWireShapes() throws {
        let filter = PhotoMediaFilter.notInAlbum.cloudSearchFilter
        XCTAssertEqual(filter.mediaType, .all)
        for v2 in [false, true] {
            let data = try JSONEncoder().encode(SearchRequest(filter: filter, token: nil, supportsV2: v2))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if v2 {
                let tree = try XCTUnwrap(object["filter"] as? [String: Any])
                XCTAssertEqual((tree["hasAlbums"] as? [String: Bool])?["eq"], false)
            } else { XCTAssertEqual(object["isNotInAlbum"] as? Bool, true) }
        }
        XCTAssertEqual(PhotoMediaFilter.edited.cloudSearchFilter.mediaType, .all)
    }

    func testEditedWaitsForLaterPagesAndCountsOnlyActualMatches() async {
        let first = asset("plain", edited: false), later = asset("edited-on-page-two", edited: true)
        let model = PhotosEditedLibraryModel { token in
            if token == nil { return ([first], .page(2)) }
            return ([first, later], nil)
        }
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.assets.map(\.id), ["edited-on-page-two"])
        model.apply(.updated([asset("edited-on-page-two", edited: false)]))
        XCTAssertTrue(model.assets.isEmpty, "Revert must remove an item from Edited immediately")
    }

    func testFailedSecondPageNeverPublishesPartialEditedCountAndCanRetry() async {
        actor Failure { var enabled = true; func disable() { enabled = false }; func shouldFail() -> Bool { enabled } }
        let failure = Failure(), edited = asset("edited", edited: true)
        let model = PhotosEditedLibraryModel { token in
            if token == nil { return ([edited], .page(2)) }
            if await failure.shouldFail() { throw URLError(.notConnectedToInternet) }
            return ([], nil)
        }
        await model.refresh()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.assets.isEmpty)
        await failure.disable()
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.assets.map(\.id), ["edited"])
    }

    func testMissingEditMetadataAndRepeatedPaginationRemainErrors() async {
        let unknown = asset("unknown")
        let model = PhotosEditedLibraryModel { _ in ([unknown], nil) }
        await model.refresh()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.assets.isEmpty)
        do {
            _ = try await PhotoFilterMetadata.collectAll { _ in ([unknown], .page(2)) }
            XCTFail("A repeated cursor must not silently produce a complete library")
        } catch { XCTAssertTrue(error is PhotoFilterMetadataError) }
    }

    func testDeviceAppAlbumMembershipUsesVerifiedPairsAndRejectsUnknowns() throws {
        let assets = [asset("local-unbacked", localID: "unbacked"),
                      asset("local-unfiled", localID: "unfiled", backedUp: true),
                      asset("local-filed", localID: "filed", backedUp: true)]
        let annotated = try PhotoFilterMetadata.applyingAppAlbumMembership(to: assets,
            verifiedRemoteByLocal: ["unfiled": "remote-unfiled", "filed": "remote-filed"],
            unfiledRemoteIDs: ["remote-unfiled"], uncertainLocalIDs: [])
        XCTAssertEqual(annotated.filter { PhotoMediaFilter.notInAlbum.includes($0) }.map(\.id),
                       ["local-unbacked", "local-unfiled"])
        XCTAssertThrowsError(try PhotoFilterMetadata.applyingAppAlbumMembership(to: assets,
            verifiedRemoteByLocal: [:], unfiledRemoteIDs: [], uncertainLocalIDs: ["filed"]))
    }

    func testAlbumMetadataCacheIsAccountScopedAndRealtimeInvalidatesIt() async throws {
        let cache = PhotoAppAlbumMembershipCache()
        let first = try await cache.unfiledIDs(account: "one", remoteIDs: ["same-id"]) { _ in false }
        XCTAssertEqual(first, ["same-id"])
        let cached = try await cache.unfiledIDs(account: "one", remoteIDs: ["same-id"]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(cached, ["same-id"])
        let other = try await cache.unfiledIDs(account: "two", remoteIDs: ["same-id"]) { _ in true }
        XCTAssertTrue(other.isEmpty)
        cache.realtimeAlbumsChanged()
        let refreshed = try await cache.unfiledIDs(account: "one", remoteIDs: ["same-id"]) { _ in true }
        XCTAssertTrue(refreshed.isEmpty)
    }

    func testAlbumInvalidationRejectsAnInFlightStaleLookup() async throws {
        actor Gate {
            var waiting = false
            var continuation: CheckedContinuation<Void, Never>?
            var startContinuation: CheckedContinuation<Void, Never>?
            func pause() async {
                waiting = true
                startContinuation?.resume(); startContinuation = nil
                await withCheckedContinuation { continuation = $0 }
            }
            func resume() { continuation?.resume(); continuation = nil }
            func waitUntilStarted() async {
                if waiting { return }
                await withCheckedContinuation { startContinuation = $0 }
            }
        }
        let gate = Gate(), cache = PhotoAppAlbumMembershipCache()
        let request = Task { try await cache.unfiledIDs(account: "one", remoteIDs: ["asset"]) { _ in await gate.pause(); return false } }
        await gate.waitUntilStarted()
        cache.realtimeAlbumsChanged()
        await gate.resume()
        do { _ = try await request.value; XCTFail("Stale lookup must be rejected after album change") }
        catch { XCTAssertTrue(error is CancellationError) }
        let refreshed = try await cache.unfiledIDs(account: "one", remoteIDs: ["asset"]) { _ in true }
        XCTAssertTrue(refreshed.isEmpty)
    }
    func testAlbumLookupConcurrencyIsBoundedForLargeLibraries() async throws {
        actor Work {
            var active = 0
            var peak = 0
            func lookup() async throws -> Bool {
                active += 1; peak = max(peak, active)
                defer { active -= 1 }
                try await Task.sleep(for: .milliseconds(10))
                return false
            }
            func maximum() -> Int { peak }
        }
        let work = Work()
        let values = try await PhotoFilterMetadata.albumMembership(remoteIDs: Set((0..<12).map(String.init))) { _ in
            try await work.lookup()
        }
        XCTAssertEqual(values.count, 12)
        let peak = await work.maximum()
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertGreaterThan(peak, 1)
    }

}
