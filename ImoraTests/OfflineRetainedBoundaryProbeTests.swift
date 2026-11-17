import UIKit
import XCTest
@testable import Imora

@MainActor
final class OfflineRetainedBoundaryProbeTests: XCTestCase {
    private enum Source { case hidden, detail, download, imageData }

    func testAuthenticatedHidingRetiresPreviouslyCachedRetainedImageWithoutTimelineListener() async throws {
        try await assertRetirement(from: .hidden)
    }

    func testRejectedAssetReadRetiresPreviouslyCachedRetainedImageWithoutTimelineListener() async throws {
        try await assertRetirement(from: .detail)
    }

    func testRejectedRedownloadRetiresPreviouslyCachedRetainedImageWithoutTimelineListener() async throws {
        try await assertRetirement(from: .download)
    }

    func testRejectedImageDataRetiresPreviouslyCachedRetainedImageWithoutTimelineListener() async throws {
        try await assertRetirement(from: .imageData)
    }

    private func assertRetirement(from source: Source) async throws {
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
        let id = UUID().uuidString
        let albumData = Data("""
        {"id":"\(id)","albumName":"Synthetic cache probe","description":"synthetic only",
        "assetCount":1,"albumUsers":[],"shared":false,"hasSharedLink":false,
        "createdAt":"2026-01-01","updatedAt":"2026-01-01","order":"desc"}
        """.utf8)
        let detail = Data("""
        {"id":"\(id)","ownerId":"fixture","type":"IMAGE","originalFileName":"synthetic.png",
        "fileCreatedAt":"2026-01-01T12:00:00Z","localDateTime":"2026-01-01T12:00:00Z",
        "isFavorite":false,"isTrashed":false,"visibility":"\(source == .hidden ? "hidden" : "timeline")",
        "thumbhash":"v1","width":32,"height":32}
        """.utf8)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/assets/\(id)" {
                return .init(status: source == .detail ? 403 : 200, body: detail)
            }
            if request.path == "/api/albums/\(id)" { return .init(body: albumData) }
            if request.path == "/api/server/version" { return .init(body: Data(#"{"major":3,"minor":4,"patch":1}"#.utf8)) }
            if request.path == "/api/server/features" { return .init(body: Data("{}".utf8)) }
            if request.path == "/api/search/metadata" {
                return .init(body: Data("{\"assets\":{\"items\":[{\"id\":\"\(id)\"}]}}".utf8))
            }
            return .init(status: 403)
        }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-cache-probe")
        client.confirmMediaAccount(UUID().uuidString)
        let scope = client.mediaDisplayScope
        defer { ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        try MediaContentGenerations.shared.ensureInitialized()
        let asset = Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: "v1",
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        let album = try JSONDecoder().decode(Album.self, from: albumData)
        let component = OfflineAlbum.Component(kind: .image, asset: asset,
            generation: try XCTUnwrap(MediaContentGenerations.shared.current(scope: scope, subject: .remoteAsset(id))))
        try await OfflineAlbumStore.shared.prepare(album: album, items: [.init(asset: asset, components: [component])], scope: scope)
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary)
        try await OfflineAlbumStore.shared.install(temporary: temporary, mime: "image/png", expectedBytes: Int64(bytes.count),
            scope: scope, albumID: id, itemID: id, componentIndex: 0, context: client.context)
        ImageLoader.shared.configure(client: client)
        let url = client.thumbnailURL(assetID: id, size: "preview", cacheKey: "v1")
        _ = try await ImageLoader.shared.image(for: url, targetPixelSize: 64)
        XCTAssertTrue(server.received.isEmpty, "The initial decode must use the retained file")
        XCTAssertNotNil(ImageLoader.shared.cachedSurface(for: url, targetPixelSize: 64))
        switch source {
        case .hidden:
            let hidden = try await client.assetDetail(id: id)
            XCTAssertEqual(hidden.visibility, .hidden)
        case .detail:
            do { _ = try await client.assetDetail(id: id); XCTFail("The denied read unexpectedly succeeded") }
            catch ImoraError.http(403, _) {}
        case .download, .imageData:
            let retainedBeforeDenial = try await client.retainedMediaFile(url)
            let saved = try XCTUnwrap(retainedBeforeDenial)
            try FileManager.default.removeItem(at: saved.url)
            if source == .download {
                let downloads = OfflineAlbumDownloads()
                await downloads.attach(client)
                downloads.download(album, client: client)
                for _ in 0..<500 where downloads.workingIDs.contains(id) { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertFalse(downloads.workingIDs.contains(id))
                XCTAssertNotNil(downloads.error)
                XCTAssertTrue(server.received.contains { $0.path.contains("/original?") })
            } else {
                do {
                    _ = try await client.imageData(for: client.authorizedRequest(url: url))
                    XCTFail("The denied image read unexpectedly succeeded")
                } catch ImoraError.http(403, _) {}
                XCTAssertEqual(server.received.count, 1)
            }
        }
        let retained = try await client.retainedMediaFile(url)
        XCTAssertNil(retained)
        let cached = ImageLoader.shared.cachedSurface(for: url, targetPixelSize: 64)
        try await OfflineAlbumStore.shared.remove(scope: scope)
        XCTAssertNil(cached, "An authenticated denial must retire the retained image already decoded into Nuke")
    }
}
