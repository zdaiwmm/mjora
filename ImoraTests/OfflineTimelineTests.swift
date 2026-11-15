import Foundation
import Synchronization
import XCTest
@testable import Imora

@MainActor
final class OfflineTimelineTests: XCTestCase {
    func testPendingFavoriteProjectsOverFreshAndRefreshedServerBuckets() async throws {
        let month = "2026-02-01T00:00:00.000Z"
        let payload = Data(#"{"id":["pending-photo"],"ownerId":["fixture"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"thumbhash":[null],"fileCreatedAt":["2026-02-02T12:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let isCatchUp = Mutex(false)
        let server = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") {
                return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8))
            }
            // The changed ratio proves the stale catch-up response has reached
            // the model before asserting the independently pending favorite.
            let body = isCatchUp.withLock { $0 }
                ? Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"ratio\":[1]", with: "\"ratio\":[2]").utf8)
                : payload
            return .init(body: body)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "pending-\(UUID())")
        defer { client.invalidate() }
        let model = TimelineModel(filter: TimelineFilter(order: "pending-\(UUID())"))
        model.assetProjection = { asset in
            var projected = asset
            if asset.id == "pending-photo" { projected.isFavorite = true }
            return projected
        }
        model.attach(client)
        await model.load()
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true])
        await model.loadBucket(month, refresh: true)
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true], "A server response older than a durable intent must not undo it")
        isCatchUp.withLock { $0 = true }
        model.realtimeCatchUp()
        for _ in 0..<150 where model.flatAssets.first?.ratio != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.flatAssets.first?.ratio, 2, "Wait for the real catch-up payload, rather than asserting the previously loaded row")
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true], "Realtime catch-up must retain a durable favorite intent too")
    }

    func testPartialFavoriteRollbackPreservesTheItemsWhoseWritesWereAccepted() {
        let assets = ["accepted", "failed"].map { id in
            Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false,
                  isTrashed: false, visibility: .timeline, thumbhash: nil,
                  fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), localOffsetHours: 0,
                  duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: assets)
        let mutation = model.setFavoriteForOptimisticAction(ids: Set(assets.map(\.id)), value: true)
        model.restore(mutation, ids: ["failed"])
        model.commit(mutation)
        let values = Dictionary(uniqueKeysWithValues: model.flatAssets.map { ($0.id, $0.isFavorite) })
        XCTAssertEqual(values["accepted"], true)
        XCTAssertEqual(values["failed"], false)
    }

    func testSuppliedSearchAndRealtimeDetailsPreserveTheDurableFavoriteProjection() async throws {
        let json = Data(#"{"id":"pending","ownerId":"fixture","type":"IMAGE","originalFileName":"fixture.jpg","fileCreatedAt":"2026-02-02T12:00:00.000Z","localDateTime":"2026-02-02T12:00:00.000Z","isFavorite":false,"isTrashed":false}"#.utf8)
        let detail = try JSONDecoder().decode(AssetDetail.self, from: json)
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [detail.asAsset()])
        model.assetProjection = { asset in var next = asset; next.isFavorite = true; return next }
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true], "Attaching the session projection must cover initial supplied results")
        model.replaceSuppliedAssets([detail.asAsset()], groupsByDate: true)
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true])
        model.realtimeAssetUpdated(detail)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.flatAssets.map(\.isFavorite), [true])
    }

    func testAwaitingAnAlreadyLoadingMonthWaitsForItsProjectedAssets() async throws {
        let month = "2026-03-01T00:00:00.000Z"
        let server = try LocalHTTPServer { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .init(body: Data("""
            {"id":["period-cover"],"ownerId":["fixture"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"thumbhash":[null],"fileCreatedAt":["2026-03-02T12:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}
            """.utf8))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "period-\(UUID())")
        defer { client.invalidate() }
        let filter = TimelineFilter(order: "period-\(UUID())")
        let account = try XCTUnwrap(client.offlineAccountKey)
        TimelineCache.store([TimeBucket(timeBucket: month, count: 1)], for: filter, account: account)
        for _ in 0..<100 where TimelineCache.buckets(for: filter, account: account) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let model = TimelineModel(filter: filter)
        model.attach(client)
        let cover = Task { await model.loadBucket(month, immediateRows: false) }
        try await Task.sleep(for: .milliseconds(20))
        await model.loadBucket(month)
        XCTAssertEqual(model.flatAssets.map(\.id), ["period-cover"])
        XCTAssertNotNil(model.rowIndex(containingAnyOf: ["period-cover"]))
        await cover.value
        XCTAssertEqual(server.received.count, 1)
    }

    func testCatchUpReplacesDeletedAssetWhenMonthlyCountIsUnchanged() async throws {
        let currentID = Mutex("synthetic-deleted")
        let month = "2026-01-01T00:00:00.000Z"
        let server = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") {
                return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8))
            }
            let id = currentID.withLock { $0 }
            return .init(body: Data("""
            {"id":["\(id)"],"ownerId":["fixture"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"thumbhash":[null],"fileCreatedAt":["2026-01-02T12:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}
            """.utf8))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-catch-up-\(UUID())")
        defer { client.invalidate() }
        let model = TimelineModel(filter: TimelineFilter(order: "fixture-\(UUID())"))
        model.attach(client)
        await model.load()
        XCTAssertEqual(model.flatAssets.map(\.id), ["synthetic-deleted"])
        currentID.withLock { $0 = "synthetic-replacement" }
        let hub = RealtimeHub(client: client)
        model.attach(client, hub: hub)
        defer { hub.shutdown() }
        hub.setActive(true)
        for _ in 0..<150 where model.flatAssets.map(\.id) != ["synthetic-replacement"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.flatAssets.map(\.id), ["synthetic-replacement"], "Count equality cannot prove asset membership is unchanged")
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" }, "Catch-up must never mutate or re-upload server photos")
    }

    func testColdLaunchRestoresAccountBoundRemotePhotosWhenServerFails() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 503) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-offline-cache-\(UUID().uuidString)")
        defer { client.invalidate() }
        let account = try XCTUnwrap(client.offlineAccountKey)
        let filter = TimelineFilter(order: "fixture-\(UUID().uuidString)")
        let month = "2026-01-01T00:00:00.000Z"
        TimelineCache.store([TimeBucket(timeBucket: month, count: 1)], for: filter, account: account)
        for _ in 0..<100 where TimelineCache.buckets(for: filter, account: account) == nil { try await Task.sleep(for: .milliseconds(5)) }
        let payload = Data(#"{"id":["synthetic-cached-photo"],"ownerId":["fixture"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"thumbhash":[null],"fileCreatedAt":["2026-01-02T12:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        TimelineCache.storeBucketPayload(payload, bucketID: month, filter: filter, account: account)
        let model = TimelineModel(filter: filter)
        model.attach(client)
        await model.load()
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.sections.map(\.id), [month])
        XCTAssertEqual(model.flatAssets.map(\.id), ["synthetic-cached-photo"])
        let other = ImoraClient(apiURL: server.apiURL, accessToken: "different-account")
        defer { other.invalidate() }
        let isolated = TimelineModel(filter: filter); isolated.attach(other)
        await isolated.load()
        XCTAssertTrue(isolated.flatAssets.isEmpty)
    }
}
