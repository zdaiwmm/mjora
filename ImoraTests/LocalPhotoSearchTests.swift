import Foundation
import Photos
import XCTest
@testable import Imora

@MainActor
final class LocalPhotoSearchTests: XCTestCase {
    func testNormalSearchAndExplicitDeviceRequestsHaveIndependentIdentity() {
        let router = TimelineNavigationRouter.shared
        defer { router.searchRequest = nil }
        router.requestSearch(source: .device)
        let first = router.searchRequest
        XCTAssertEqual(first?.source, .device)
        router.requestSearch(source: .device)
        XCTAssertNotEqual(router.searchRequest?.id, first?.id)
        router.requestSearch()
        XCTAssertEqual(router.searchRequest?.source, .cloud)
    }

    func testOnlyCurrentVisibleMetadataCanProduceSearchResults() async {
        let records = [record("allowed", name: "Beach.HEIC"), record("hidden", name: "Beach-hidden.HEIC"),
                       record("revoked", name: "Beach-revoked.HEIC")]
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { ids in ids.intersection(["allowed"]) })
        let context = context()
        await model.reload(context: context, backedUpLocalIDs: [])
        await model.search("beach", context: context)
        XCTAssertEqual(model.results.map(\.localIdentifier), ["allowed"])
        XCTAssertEqual(model.timeline.flatAssets.map(\.localIdentifier), ["allowed"])
    }

    func testLimitedSelectionRevocationRechecksVisibilityWithoutAuthorizationEnumChange() async {
        let records = [record("first", name: "Beach.HEIC"), record("second", name: "Mountain.HEIC")]
        let visibility = SearchVisibility(["first", "second"])
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { await visibility.filter($0) })
        let first = context(epoch: 1)
        await model.reload(context: first, backedUpLocalIDs: [])
        await model.search("", context: first)
        XCTAssertEqual(model.results.count, 2)
        await visibility.replace(["second"])
        // Each query also re-fetches PhotoKit visibility, before its observer
        // has delivered a new permission epoch to SwiftUI.
        await model.search("beach", context: first)
        XCTAssertTrue(model.results.isEmpty)
        let next = context(session: first.sessionID, epoch: 2)
        await model.reload(context: next, backedUpLocalIDs: [])
        await model.search("", context: next)
        XCTAssertEqual(model.results.map(\.localIdentifier), ["second"])
    }

    func testRevocationDuringMatchingCannotPublishRemovedPhoto() async {
        let records = [record("removed", name: "Beach.HEIC")]
        let gate = SearchGate()
        let visibility = SearchVisibility(["removed"])
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { await visibility.filter($0) },
            match: { records, query in
                await gate.pause()
                return LocalPhotoSearch.results(records, query: query)
            })
        let context = context()
        await model.reload(context: context, backedUpLocalIDs: [])
        let search = Task { await model.search("beach", context: context) }
        await gate.waitUntilStarted()
        await visibility.replace([])
        await gate.resume()
        await search.value
        XCTAssertTrue(model.results.isEmpty)
    }

    func testNewerQueryWinsOverAnOlderDetachedMatch() async {
        let records = [record("beach", name: "Beach.HEIC"), record("mountain", name: "Mountain.HEIC")]
        let gate = SearchGate()
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { $0 }, match: { records, query in
            if query == "beach" { await gate.pause() }
            return LocalPhotoSearch.results(records, query: query)
        })
        let context = context()
        await model.reload(context: context, backedUpLocalIDs: [])
        let older = Task { await model.search("beach", context: context) }
        await gate.waitUntilStarted()
        await model.search("mountain", context: context)
        await gate.resume()
        await older.value
        XCTAssertEqual(model.results.map(\.localIdentifier), ["mountain"])
    }

    func testNewPermissionEpochRejectsAnEarlierMatchInTheSameSession() async {
        let records = [record("beach", name: "Beach.HEIC"), record("mountain", name: "Mountain.HEIC")]
        let gate = SearchGate()
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { $0 }, match: { records, query in
            if query == "beach" { await gate.pause() }
            return LocalPhotoSearch.results(records, query: query)
        })
        let first = context(epoch: 1)
        await model.reload(context: first, backedUpLocalIDs: [])
        let older = Task { await model.search("beach", context: first) }
        await gate.waitUntilStarted()
        let next = context(session: first.sessionID, epoch: 2)
        await model.reload(context: next, backedUpLocalIDs: [])
        await model.search("mountain", context: next)
        await gate.resume()
        await older.value
        XCTAssertEqual(model.context, next)
        XCTAssertEqual(model.results.map(\.localIdentifier), ["mountain"])
    }

    func testAccountChangeClearsResultsAndRejectsEarlierMetadataLoad() async {
        let gate = SearchGate()
        let records = [record("old-account", name: "Beach.HEIC")]
        let model = LocalPhotoSearchModel(load: { backedUp in
            if backedUp.contains("old-account") { await gate.pause(); return records }
            return []
        }, visible: { $0 })
        let first = context()
        let older = Task { await model.reload(context: first, backedUpLocalIDs: ["old-account"]) }
        await gate.waitUntilStarted()
        let next = context()
        await model.reload(context: next, backedUpLocalIDs: [])
        await gate.resume()
        await older.value
        await model.search("", context: next)
        XCTAssertEqual(model.context, next)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testLeavingPageRejectsAnInFlightMatchAndClearsTimeline() async {
        let records = [record("photo", name: "Beach.HEIC")]
        let gate = SearchGate()
        let model = LocalPhotoSearchModel(load: { _ in records }, visible: { $0 }, match: { records, query in
            if query == "beach" { await gate.pause() }
            return LocalPhotoSearch.results(records, query: query)
        })
        let context = context()
        await model.reload(context: context, backedUpLocalIDs: [])
        await model.search("", context: context)
        XCTAssertEqual(model.results.count, 1)
        let pending = Task { await model.search("beach", context: context) }
        await gate.waitUntilStarted()
        model.invalidate()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.timeline.sections.isEmpty)
        await gate.resume()
        await pending.value
        XCTAssertNil(model.context)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testDeniedOrInactiveContextCannotEnumeratePhotos() async {
        let calls = SearchLoadCalls()
        let model = LocalPhotoSearchModel(load: { _ in await calls.note(); return [] }, visible: { $0 })
        let denied = LocalPhotoSearchModel.Context(sessionID: UUID(), permissionEpoch: 1,
            authorization: PHAuthorizationStatus.denied.rawValue, isActive: true)
        await model.reload(context: denied, backedUpLocalIDs: [])
        let inactive = LocalPhotoSearchModel.Context(sessionID: UUID(), permissionEpoch: 1,
            authorization: PHAuthorizationStatus.authorized.rawValue, isActive: false)
        await model.reload(context: inactive, backedUpLocalIDs: [])
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.results.isEmpty)
    }

    private func context(session: UUID? = UUID(), epoch: Int = 1) -> LocalPhotoSearchModel.Context {
        .init(sessionID: session, permissionEpoch: epoch,
              authorization: PHAuthorizationStatus.limited.rawValue, isActive: true)
    }

    private func record(_ id: String, name: String) -> LocalPhotoSearchRecord {
        let asset = Asset(id: "local-\(id)", ownerId: "", isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: nil, fileCreatedAt: .distantPast,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1,
            city: nil, country: nil, createdAt: nil, localIdentifier: id)
        return .init(asset: asset, filename: name)
    }
}

private actor SearchVisibility {
    private var allowed: Set<String>
    init(_ allowed: Set<String>) { self.allowed = allowed }
    func filter(_ ids: Set<String>) -> Set<String> { ids.intersection(allowed) }
    func replace(_ allowed: Set<String>) { self.allowed = allowed }
}

private actor SearchLoadCalls {
    private(set) var count = 0
    func note() { count += 1 }
}

private actor SearchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    func pause() async {
        started = true
        startContinuation?.resume(); startContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
