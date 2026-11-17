import XCTest
@testable import Imora

@MainActor
final class CollectionsCoverStoreTests: XCTestCase {
    func testConcurrentPreviewAndPrewarmShareMetadataAndReturningKeepsTheCover() async throws {
        let server = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets") {
                return .init(body: try! JSONSerialization.data(withJSONObject: [["timeBucket": "2026-01-01T00:00:00Z", "count": 1]]))
            }
            if request.path.hasPrefix("/api/timeline/bucket") {
                return .init(body: try! JSONSerialization.data(withJSONObject: ["id": ["cover"], "ownerId": ["fixture"], "isImage": [true],
                    "isFavorite": [false], "isTrashed": [false], "visibility": ["timeline"],
                    "thumbhash": [NSNull()], "duration": [NSNull()], "livePhotoVideoId": [NSNull()],
                    "fileCreatedAt": ["2026-01-01T12:00:00Z"], "localOffsetHours": [0], "ratio": [1.5]]))
            }
            return .init(status: 404)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-cover-token")
        defer { client.invalidate() }
        let store = CollectionsCoverStore()
        async let first: Void = store.load("recent", client: client, favoritesAcrossSpaces: false)
        async let second: Void = store.load("recent", client: client, favoritesAcrossSpaces: false)
        _ = await (first, second)
        XCTAssertEqual(store.cached("recent", client: client)?.url, client.thumbnailURL(assetID: "cover"))
        await store.load("recent", client: client, favoritesAcrossSpaces: false)
        XCTAssertEqual(server.received.filter { $0.path.hasPrefix("/api/timeline/") }.count, 2)
        await store.load("favorites", client: client, favoritesAcrossSpaces: false)
        XCTAssertNil(store.cached("favorites", client: client, favoritesAcrossSpaces: true),
                     "Capabilities resolving after prewarm must not reuse the narrower favorites query")
        await store.load("favorites", client: client, favoritesAcrossSpaces: true)
        XCTAssertNotNil(store.cached("favorites", client: client, favoritesAcrossSpaces: true))
        XCTAssertEqual(server.received.filter { $0.path.hasPrefix("/api/timeline/") }.count, 6)
        let replacement = ImoraClient(apiURL: server.apiURL, accessToken: "another-synthetic-token")
        defer { replacement.invalidate() }
        XCTAssertNil(store.cached("recent", client: replacement))
        store.reset(client: replacement)
        XCTAssertNil(store.cached("recent", client: client))
    }

    func testNoPreviewOrCollapsedPinsDoNotStartCoverRequests() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 500) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-cover-token")
        defer { client.invalidate() }
        let store = CollectionsCoverStore()
        var layout = CollectionsLayout()
        layout.previewSize = .none
        await store.prewarm(client: client, layout: layout, favoritesAcrossSpaces: false)
        layout.previewSize = .large; layout.toggleCollapsed(.pinned)
        await store.prewarm(client: client, layout: layout, favoritesAcrossSpaces: false)
        XCTAssertTrue(server.received.isEmpty)
    }
}
