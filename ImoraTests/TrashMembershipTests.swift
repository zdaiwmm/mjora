import Foundation
import Synchronization
import XCTest
@testable import Imora

@MainActor
final class TrashMembershipTests: XCTestCase {
    func testUnavailableTrashDoesNotReplayDeletedRowsAndRetryShowsServerMembers() async throws {
        let month = "2026-01-01"
        let ownerID = UUID().uuidString
        let bucketList = Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8)
        let serverBucket = Self.bucket(assetID: "still-in-trash", ownerID: ownerID)
        let available = Mutex(false)
        let server = try LocalHTTPServer { request in
            guard available.withLock({ $0 }), request.method == "GET" else { return .init(status: 503) }
            let route = URLComponents(string: request.path)
            guard route?.queryItems?.contains(.init(name: "userId", value: ownerID)) == true,
                  route?.queryItems?.contains(.init(name: "isTrashed", value: "true")) == true else {
                return .init(status: 400)
            }
            switch route?.path {
            case "/api/timeline/buckets": return .init(body: bucketList)
            case "/api/timeline/bucket": return .init(body: serverBucket)
            default: return .init(status: 404)
            }
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "trash-test-\(UUID())")
        defer { client.invalidate() }
        let account = try XCTUnwrap(client.offlineAccountKey)
        var filter = TrashScreen.filter(ownerID: ownerID)
        filter.order = "fixture-\(UUID())"
        var legacyFilter = filter
        legacyFilter.userId = nil
        TimelineCache.store([TimeBucket(timeBucket: month, count: 1)], for: legacyFilter, account: account)
        for _ in 0..<100 where TimelineCache.buckets(for: legacyFilter, account: account) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(TimelineCache.buckets(for: legacyFilter, account: account))
        TimelineCache.storeBucketPayload(Self.bucket(assetID: "already-deleted", ownerID: ownerID),
                                         bucketID: month, filter: legacyFilter, account: account)

        let legacyModel = TimelineModel(filter: legacyFilter)
        legacyModel.attach(client)
        await legacyModel.load()
        XCTAssertEqual(legacyModel.flatAssets.map(\.id), ["already-deleted"])

        let model = TimelineModel(filter: filter)
        model.attach(client)
        await model.load()
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.flatAssets.isEmpty)

        available.withLock { $0 = true }
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.flatAssets.map(\.id), ["still-in-trash"])
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" })
    }

    private static func bucket(assetID: String, ownerID: String) -> Data {
        Data("""
        {"id":["\(assetID)"],"ownerId":["\(ownerID)"],"isImage":[true],"isFavorite":[false],"isTrashed":[true],"visibility":["timeline"],"thumbhash":[null],"fileCreatedAt":["2026-01-02T12:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}
        """.utf8)
    }
}
