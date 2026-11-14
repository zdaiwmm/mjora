import Foundation
import XCTest
@testable import Imora

@MainActor
final class OfflineTimelineTests: XCTestCase {
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
