import AVFoundation
import SwiftUI
import XCTest
@testable import Imora

@MainActor
final class GalleryResponsivenessTests: XCTestCase {
    func testRebindingTheSameSessionPreservesPreparedThumbnails() throws {
        let client = ImoraClient(apiURL: URL(string: "https://fixture.invalid/api")!, accessToken: UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        let url = client.thumbnailURL(assetID: "resume-\(UUID())")
        ImageLoader.shared.installPrepared(image, url: url, targetPixelSize: 128, client: client)
        XCTAssertNotNil(ImageLoader.shared.cachedSurface(for: url, targetPixelSize: 128))
        ImageLoader.shared.configure(client: client)
        XCTAssertNotNil(ImageLoader.shared.cachedSurface(for: url, targetPixelSize: 128),
                        "Foreground recovery must not clear the current session's decoded photos")
    }

    func testDeletionReusesSurvivingTilesAcrossRows() throws {
        let model = TimelineModel(filter: .init(), suppliedAssets: (0..<12).map { photo("reflow-\($0)") })
        model.showsDateHeaders = false
        let session = SessionStore(), registry = AssetTileRegistry()
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        grid.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        grid.contentInsetAdjustmentBehavior = .never
        grid.update(side: AssetGridLayout.tileSide(viewportWidth: 390, columns: 3), tailPadding: 0,
            context: .init(session: session, columns: 3, targetPixelSize: 128, showsBackupBadge: false,
                usesOriginalAspectRatio: false, isSelecting: false, selection: [], reduceMotion: false,
                registry: registry, motion: GridMotion(), isSelectable: { _ in true },
                isSelectableAssetID: { _ in true }, actions: .init(toggleSelection: { _ in },
                    menu: { _ in UIMenu(children: []) }, makeViewer: { _, _, _ in nil }), toggleDay: { _, _ in }), animated: false)
        grid.layoutIfNeeded()
        func tiles(_ view: UIView) -> [TimelineTileView] {
            (view as? TimelineTileView).map { [$0] } ?? view.subviews.flatMap { tiles($0) }
        }
        let before = Dictionary(uniqueKeysWithValues: tiles(grid).compactMap { tile in tile.asset.map { ($0.id, tile) } })
        let removed = try XCTUnwrap(model.flatAssets.first?.id)
        XCTAssertEqual(before.count, 12)
        model.removeAssets(ids: [removed])
        grid.reloadRows(animated: true)
        for tile in tiles(grid) {
            let id = try XCTUnwrap(tile.asset?.id)
            XCTAssertNotEqual(id, removed)
            XCTAssertTrue(before[id] === tile, "A photo crossing a row boundary must keep its loaded tile")
        }
        XCTAssertEqual(tiles(grid).count, 11)
    }

    func testResizingKeepsTheCurrentPhotoWhileTheLargerThumbnailLoads() throws {
        let client = ImoraClient(apiURL: URL(string: "https://fixture.invalid/api")!, accessToken: UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = photo("resize-\(UUID())")
        let source = AssetThumbnailSource(assetID: value.id, localIdentifier: nil, pairedLocalIdentifier: nil,
            pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        ImageLoader.shared.installPrepared(image, url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash),
            targetPixelSize: 128, client: client)
        let tile = TimelineTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: 128)
        XCTAssertNotNil((tile.zoomReplicaFactory()?() as? UIImageView)?.image)
        tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: 512)
        XCTAssertNotNil((tile.zoomReplicaFactory()?() as? UIImageView)?.image, "Changing thumbnail resolution must not flash a blank tile")
        XCTAssertFalse(tile.hasPreparedInitialImage, "A smaller preview must not impersonate the requested final image")
        tile.recycle()
    }

    func testNavigationExpandsBeforeASecondTapRequestsTheLatestPhotos() {
        let controls = PhotosGridControls()
        controls.observeScroll(offset: 1_000, endOffset: 2_000, isUserScrolling: false)
        controls.observeScroll(offset: 900, endOffset: 2_000, isUserScrolling: true)
        XCTAssertTrue(controls.showsPeriodNavigation)
        controls.expandNavigation()
        XCTAssertFalse(controls.showsPeriodNavigation)
        XCTAssertNil(controls.scrollRequest)
        XCTAssertEqual(controls.scrollOffset, 900)
        controls.observeScroll(offset: 900, endOffset: 2_000, isUserScrolling: false)
        XCTAssertFalse(controls.showsPeriodNavigation)
        controls.returnToLatest()
        XCTAssertNotNil(controls.scrollRequest)
        XCTAssertNil(controls.scrollRequest?.bucketID)
        XCTAssertFalse(controls.browsingPast)
    }

    func testExpandingNavigationKeepsThePeriodAndResumesCollapsingOnAScroll() {
        let controls = PhotosGridControls()
        controls.mode = .months
        controls.expandNavigation()
        XCTAssertEqual(controls.mode, .months)
        XCTAssertFalse(controls.showsPeriodNavigation)
        controls.observeScroll(offset: 100, endOffset: 2_000, isUserScrolling: false)
        controls.observeScroll(offset: 120, endOffset: 2_000, isUserScrolling: true)
        XCTAssertTrue(controls.showsPeriodNavigation)
    }

    func testCalendarCacheRefreshesAfterAssetsAndPreferredPhotoChange() throws {
        let model = TimelineModel(filter: .init(), suppliedAssets: [photo("a"), photo("b")])
        let period = try XCTUnwrap(model.photoPeriods(mode: .months).first)
        XCTAssertEqual(period.count, 2)
        XCTAssertEqual(model.photoPeriods(mode: .years, preferredAssetID: "b").first?.cover?.id, "b")
        XCTAssertEqual(model.photoMonthContent(period: period, preferredAssetID: "a").days.first?.cover.id, "a")
        XCTAssertEqual(model.photoMonthContent(period: period, preferredAssetID: "b").days.first?.cover.id, "b")
        var changed = photo("a"); changed.isFavorite = true
        model.replaceSuppliedAssets([changed], groupsByDate: true)
        let fresh = try XCTUnwrap(model.photoPeriods(mode: .months).first)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh.cover?.id, "a")
        XCTAssertTrue(try XCTUnwrap(model.photoMonthContent(period: fresh).days.first).cover.isFavorite)
    }

    func testRepeatedCalendarLayoutsReuseGroupingWork() throws {
        let assets = (0..<12_000).map { photo("asset-\($0)", day: $0 % 360) }
        let model = TimelineModel(filter: .init(), suppliedAssets: assets)
        let period = try XCTUnwrap(model.photoPeriods(mode: .months).last)
        let iterations = 40
        let uncachedStart = ContinuousClock.now
        for _ in 0..<iterations {
            _ = PhotoPeriodCardLayout.oldestFirst(PhotoPeriod.years(in: model.sections))
            _ = PhotoMonthContent(period: period, sections: model.sections)
        }
        let uncached = uncachedStart.duration(to: .now)
        let cachedStart = ContinuousClock.now
        for _ in 0..<iterations {
            _ = model.photoPeriods(mode: .years)
            _ = model.photoMonthContent(period: period)
        }
        let cached = cachedStart.duration(to: .now)
        XCTAssertEqual(model.photoPeriods(mode: .years).reduce(0) { $0 + $1.count }, assets.count)
        print("CALENDAR_LAYOUT_12000_ASSETS_40_PASSES uncached=\(uncached) cached=\(cached)")
    }

    func testVideoTransportIsVisibleWhileThePlayerIsPreparing() {
        let chrome = AssetViewerChromePresentation(isCompact: true, isAtMedia: true,
            isInformationPresented: false, isChromeVisible: true, isContextPreview: false,
            isPlayable: true, isPlayerReady: false, isMediaZoomed: false)
        XCTAssertTrue(chrome.showsTransportControls)
        XCTAssertTrue(chrome.reservesTransportControls)
    }

    func testVideoDurationIsAvailableBeforeTheItemFinishesLoading() async {
        let playback = VideoPlayback()
        var continuation: CheckedContinuation<AVPlayerItem?, Never>?
        let task = Task {
            await playback.claim(assetID: "video", forceMuted: true, seedDuration: 42) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(playback.duration, 42)
        XCTAssertTrue(playback.isBuffering)
        XCTAssertNil(playback.player)
        continuation?.resume(returning: nil)
        await task.value
    }

    private func photo(_ id: String, day: Int = 0) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
              visibility: .timeline, thumbhash: nil,
              fileCreatedAt: Date(timeIntervalSince1970: 1_735_689_600 + Double(day) * 86_400),
              localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
    }
}

@MainActor
final class ControlledMediaStreamTests: XCTestCase {
    func testRangeReadDoesNotDownloadTheWholeVideoAndRetiresWithTheAccount() async throws {
        let bytes = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        let server = try LocalHTTPServer { request in
            let range = (request.headers["range"] ?? "").dropFirst(6).split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]), end < bytes.count else {
                return .init(status: 400)
            }
            return .init(status: 206, headers: ["Content-Type": "video/mp4",
                "Content-Range": "bytes \(start)-\(end)/\(bytes.count)"], body: Data(bytes[start...end]))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-stream-token")
        let stream = try ControlledMediaStream(client: client, url: client.playbackURL(assetID: "video"), requiresElevation: false)
        let asset = stream.makeAsset()
        let head = try await stream.read(offset: 0, end: 2)
        let middle = try await stream.read(offset: 512_000, end: 524_288)
        XCTAssertEqual(head.data.count, 2)
        XCTAssertEqual(middle.data.count, 12_288)
        XCTAssertEqual(middle.totalLength, Int64(bytes.count))
        XCTAssertTrue(middle.supportsRanges)
        XCTAssertEqual(server.received.map { $0.headers["range"] }, ["bytes=0-1", "bytes=512000-524287"])
        XCTAssertTrue(server.received.allSatisfy { $0.headers["authorization"] == "Bearer synthetic-stream-token" })
        XCTAssertEqual(asset.url.scheme, "imora-stream")
        XCTAssertTrue(ControlledMediaStream.isAuthorized(asset))
        client.invalidate()
        XCTAssertFalse(ControlledMediaStream.isAuthorized(asset))
        do { _ = try await stream.read(offset: 0, end: 2); XCTFail("Retired stream made a request") } catch {}
        XCTAssertEqual(server.received.count, 2)
    }

    func testAVFoundationReadsDurationAndFirstFrameThroughTheControlledStream() async throws {
        let path = "/Users/achilles/mjora/execution/photos-phase4/services/video-media/live-motion.mov"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Synthetic motion fixture unavailable") }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let server = try LocalHTTPServer { request in
            let range = (request.headers["range"] ?? "").dropFirst(6).split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let requestedEnd = Int(range[1]), start < bytes.count else {
                return .init(status: 416)
            }
            let end = min(requestedEnd, bytes.count - 1)
            return .init(status: 206, headers: ["Content-Type": "video/quicktime",
                "Content-Range": "bytes \(start)-\(end)/\(bytes.count)"], body: Data(bytes[start...end]))
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-stream-token")
        defer { client.invalidate() }
        let stream = try ControlledMediaStream(client: client, url: client.playbackURL(assetID: "video"), requiresElevation: false)
        let asset = stream.makeAsset()
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: .zero)
        XCTAssertGreaterThan(frame.image.width, 0)
        XCTAssertTrue(server.received.allSatisfy { $0.headers["range"] != nil })

    }

    func testStreamRejectsPlaylistsAndCrossOriginRedirects() async throws {
        let receiver = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("video".utf8)) }
        try await receiver.start(); defer { receiver.stop() }
        let server = try LocalHTTPServer { request in
            if request.path.contains("playlist") {
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U".utf8))
            }
            return .init(status: 302, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString])
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-stream-token")
        defer { client.invalidate() }
        for id in ["playlist", "redirect"] {
            let stream = try ControlledMediaStream(client: client, url: client.playbackURL(assetID: id), requiresElevation: false)
            do { _ = try await stream.read(offset: 0, end: 2); XCTFail("Accepted \(id)") } catch {}
        }
        XCTAssertTrue(receiver.received.isEmpty)
    }
}
