import Foundation
import Synchronization
import XCTest
@testable import Imora

@MainActor
final class OfflineTimelineTests: XCTestCase {
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
