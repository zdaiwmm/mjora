import CoreGraphics
import UIKit
import XCTest
import Synchronization
@testable import Imora

@MainActor
final class TimelineInteractionPerformanceTests: XCTestCase {
    func testGridBehindMovingThumbnailsFillsTransientGapsWithoutBleedingAtRest() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let host = UIView(frame: bounds)
        let grid = UIScrollView(frame: bounds)
        grid.backgroundColor = .blue
        grid.contentSize = CGSize(width: 300, height: 1_000)
        host.addSubview(grid)
        let transition = TimelineGridZoomTransition()
        let photo: () -> UIView = {
            let view = UIView()
            view.backgroundColor = .red
            return view
        }
        let original = TimelineGridZoomTransition.CapturedTile(id: "photo",
            frame: CGRect(x: 100, y: 80, width: 100, height: 100), makeReplica: photo)
        let target = TimelineGridZoomTransition.CapturedTile(id: "photo",
            frame: CGRect(x: 151, y: 80, width: 149, height: 149), makeReplica: photo)
        let midpoint = CGPoint(x: 150, y: 130)

        func gapHasLiveGridPixels() throws -> Bool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { host.layer.render(in: $0.cgContext) }
            let sample = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 10, y: 295, width: 1, height: 1)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Int(pixel[2]) > Int(pixel[0]) + 120
        }

        transition.begin(in: grid, captured: [original], midpoint: midpoint, reduceMotion: false) { _, _, columns in
            columns == 2 ? .init(tiles: ["photo": target], verticalOffsets: 0...600) : nil
        }
        XCTAssertFalse(try gapHasLiveGridPixels())
        transition.update(scale: 1.25, midpoint: midpoint, in: grid)
        XCTAssertTrue(try gapHasLiveGridPixels())
        transition.update(scale: 1.38, midpoint: midpoint, in: grid)
        transition.update(scale: 1.25, midpoint: midpoint, in: grid)
        XCTAssertTrue(try gapHasLiveGridPixels())
        transition.update(scale: 1.6, midpoint: midpoint, in: grid)
        XCTAssertFalse(try gapHasLiveGridPixels())
        transition.cancel()
    }

    func testBackupBurstPublishesOneDeviceGalleryRefresh() async {
        let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
        let hub = RealtimeHub(client: client)
        let firstRefresh = expectation(description: "coalesced device refresh")
        let listener = LocalRefreshListener { firstRefresh.fulfill() }
        hub.addListener(listener)
        defer { hub.shutdown() }

        for _ in 0..<128 { hub.notifyLocalChange() }
        XCTAssertEqual(hub.localGeneration, 0, "Views must not observe a separate reload per upload")
        await fulfillment(of: [firstRefresh], timeout: 2)
        XCTAssertEqual(hub.localGeneration, 1)
        XCTAssertEqual(listener.count, 1)
    }

    private final class LocalRefreshListener: RealtimeListener {
        private let onRefresh: () -> Void
        private(set) var count = 0

        init(onRefresh: @escaping () -> Void) { self.onRefresh = onRefresh }

        func realtimeLocalChanged() {
            count += 1
            onRefresh()
        }
    }

    func testPeriodZoomStartsWithCurrentCarriedPixelsWhileTheLargePreviewIsDelayed() async throws {
        let userID = "period-carried-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 416, height: 416), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 416, height: 416))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let gate = DispatchSemaphore(value: 0), previewStarted = Mutex(false)
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("size=preview") {
                    previewStarted.withLock { $0 = true }
                    _ = gate.wait(timeout: .now() + 8)
                }
                return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-carried", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let value = photo("carried"), motion = PhotoPeriodMotion(), registry = AssetTileRegistry()
        let tile = TimelineTileView(frame: CGRect(x: 20, y: 100, width: 100, height: 100))
        let card = PeriodPhotoImageView(frame: CGRect(x: 20, y: 300, width: 350, height: 240))
        controller.view.addSubview(tile); controller.view.addSubview(card)
        defer { motion.cancel(); card.cancelLoad(); tile.unregister(); window.isHidden = true }
        tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false,
            targetPixelSize: 416, registry: registry)
        for _ in 0..<200 {
            if tile.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let carried = try XCTUnwrap(tile.preparedSurfaceForMotion())
        motion.begin(assetID: value.id, from: .all, to: .months, gridSource: tile, session: session, reduceMotion: false)
        card.configure(asset: value, mode: .months, session: session, motion: motion,
            targetPixelSize: 1200, fallbackPixelSize: 416, bucketID: "capture")
        XCTAssertTrue(card.image === carried.image)
        XCTAssertNil(card.preparedSurfaceForMotion(), "The carried thumbnail remains distinguishable from a full-resolution card")
        XCTAssertNotNil(card.preparedSurfaceForMotion(requiringCoverage: false))
        let transfers = server.received.filter { $0.path.contains("/thumbnail") }.count
        motion.arrive(at: card, mode: .months)
        XCTAssertNotNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        XCTAssertEqual(server.received.filter { $0.path.contains("/thumbnail") }.count, transfers,
            "Starting the transition itself must not request another image")
        for _ in 0..<100 {
            if previewStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(previewStarted.withLock { $0 })
        XCTAssertTrue(card.image === carried.image, "The requested large preview is still held by the fixture")
        motion.cancel()
        XCTAssertEqual(tile.alpha, 1); XCTAssertEqual(card.alpha, 1)
        XCTAssertNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        if let client = session.client {
            _ = ImageLoader.shared.invalidateSubjects(client: client, subjects: [.remoteAsset(value.id)])
            XCTAssertNil(card.preparedSurfaceForMotion(requiringCoverage: false), "Relaxed pixel coverage never relaxes current-content authority")
        }
        gate.signal()
        await session.logOut(reportRemoteFailure: false)
    }

    func testPeriodZoomKeepsReplicasBelowChromeAndRestoresEverySurfaceOnCancel() async throws {
        let userID = "period-companions-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-companions", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let values = [photo("anchor"), photo("neighbor"), photo("incoming")]
        let motion = PhotoPeriodMotion(), registry = AssetTileRegistry()
        let tiles = (0..<2).map { index in
            TimelineTileView(frame: CGRect(x: CGFloat(20 + index * 110), y: 100, width: 100, height: 100))
        }
        let cards: [PeriodPhotoImageView] = (0..<3).map { (index: Int) -> PeriodPhotoImageView in
            let x = CGFloat(20 + (index % 2) * 180)
            let y = CGFloat(300 + (index / 2) * 190)
            let frame = CGRect(x: x, y: y, width: 170, height: 170)
            return PeriodPhotoImageView(frame: frame)
        }
        defer { motion.cancel(); tiles.forEach { $0.unregister() }; window.isHidden = true }
        for (index, tile) in tiles.enumerated() {
            controller.view.addSubview(tile)
            tile.configure(asset: values[index], session: session, motion: GridMotion(), showsBackupBadge: false,
                targetPixelSize: 416, registry: registry)
        }
        for (index, card) in cards.enumerated() {
            controller.view.addSubview(card)
            card.configure(asset: values[index], mode: .months, session: session, motion: motion,
                bucketID: "capture-bucket-\(index)")
        }
        let contentLayer = UIView(frame: CGRect(x: 0, y: 90, width: 390, height: 550))
        contentLayer.clipsToBounds = true
        controller.view.addSubview(contentLayer)
        controller.view.addSubview(UIView(frame: CGRect(x: 0, y: 640, width: 390, height: 120)))
        motion.host = contentLayer
        for _ in 0..<200 {
            if tiles.allSatisfy({ $0.preparedSurfaceForMotion() != nil }) && cards.allSatisfy({ $0.preparedSurfaceForMotion() != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(tiles.allSatisfy { $0.preparedSurfaceForMotion() != nil })
        XCTAssertTrue(cards.allSatisfy { $0.preparedSurfaceForMotion() != nil })
        let transfers = server.received.filter { $0.path.contains("/thumbnail") }.count
        motion.begin(assetID: values[0].id, from: .all, to: .months, gridSource: tiles[0],
            gridSources: tiles, session: session, reduceMotion: false)
        motion.arrive(at: cards[0], mode: .months)
        XCTAssertTrue(tiles.allSatisfy { $0.alpha == 0 }, "Every visible source photo joins the spatial transition")
        XCTAssertEqual(cards[2].alpha, 1, "Incoming photos do not wait for a replica to finish")
        XCTAssertEqual(contentLayer.subviews.filter { $0 is AssetViewerBoundImageView }.count, 2)
        XCTAssertTrue(window.subviews.allSatisfy { !($0 is AssetViewerBoundImageView) })
        XCTAssertEqual(server.received.filter { $0.path.contains("/thumbnail") }.count, transfers,
            "Motion uses prepared photos without starting another image load")
        motion.cancel()
        XCTAssertTrue(tiles.allSatisfy { $0.alpha == 1 })
        XCTAssertTrue(cards.allSatisfy { $0.alpha == 1 })
        XCTAssertTrue(contentLayer.subviews.isEmpty)
        XCTAssertEqual(motion.visibleAnchor(in: .months, preferredAssetID: values[0].id)?.asset.id, values[0].id)
        cards[0].frame.origin.y = -500
        let visibleAnchor = try XCTUnwrap(motion.visibleAnchor(in: .months, preferredAssetID: values[0].id))
        XCTAssertEqual(visibleAnchor.asset.id, values[1].id,
            "Scrolling away from an old anchor selects a real visible photo for the next period transition")
        XCTAssertEqual(visibleAnchor.bucketID, "capture-bucket-1", "The visible capture bucket must not borrow All's upload-date semantics")
        await session.logOut(reportRemoteFailure: false)
    }

    func testVisibleZoomGeometryMatchesActualCompactAndDateBandRows() {
        let assets = (0..<240).map { photo("asset-\($0)", day: $0 / 7) }
        let model = TimelineModel(filter: .init(), suppliedAssets: assets)
        let ids = Set(assets.map(\.id))
        for grouped in [false, true] {
            model.showsDateHeaders = grouped
            for columns in 2...5 {
                for rightToLeft in [false, true] {
                    let expected = frames(in: model.rowsForZoom(columns: columns), columns: columns,
                        width: 393, rightToLeft: rightToLeft)
                    assertFramesEqual(model.framesForZoom(assetIDs: ids, columns: columns, width: 393,
                        rightToLeft: rightToLeft), expected)
                }
            }
        }
    }

    func testZoomWindowMatchesCompactAndGroupedRowsInBothLayoutDirections() throws {
        let assets = [1, 2, 5, 7, 12, 3, 4, 1].enumerated().flatMap { day, count in
            (0..<count).map { photo("window-\(day)-\($0)", day: day + 28) }
        }
        let model = TimelineModel(filter: .init(), suppliedAssets: assets)
        let queries: [(asset: Asset, unitY: CGFloat, reach: CGFloat)] = [
            (assets[0], 0, 0), (assets[assets.count / 2], 0.25, 195), (assets[assets.count - 1], 1, 165)
        ]
        let width: CGFloat = 393
        for grouped in [false, true] {
            model.showsDateHeaders = grouped
            for columns in 2...5 {
                let rows = model.rowsForZoom(columns: columns)
                let side = AssetGridLayout.tileSide(viewportWidth: width, columns: columns)
                let rowsHeight = rows.reduce(CGFloat.zero) { $0 + $1.height(tileSide: side) }
                for rightToLeft in [false, true] {
                    let projected = frames(in: rows, columns: columns, width: width, rightToLeft: rightToLeft)
                    for (asset, unitY, reach) in queries {
                        let anchor = try XCTUnwrap(projected[asset.id])
                        let anchorY = anchor.minY + unitY * anchor.height
                        let expected = projected.filter { $0.value.maxY >= anchorY - reach && $0.value.minY <= anchorY + reach }
                        let window = model.zoomWindow(anchorID: asset.id, unitY: unitY, viewportReach: reach,
                            columns: columns, width: width, rightToLeft: rightToLeft)
                        assertFramesEqual(window.tiles.mapValues { $0.frame }, expected)
                        XCTAssertEqual(window.tiles[asset.id]?.asset, asset)
                        XCTAssertEqual(window.rowsHeight, rowsHeight, accuracy: 0.000001)
                    }
                }
            }
        }
    }

    func testCompactGeometryPreservesUnknownSlotsAndPartialRowSemantics() {
        let firstPhotos = (0..<3).map { photo("one-\($0)") }
        let partialPhotos = (0..<8).map { photo("partial-\($0)") }
        let lastPhotos = (0..<16).map { photo("last-\($0)") }
        let firstDay = DayGroup(id: "one", title: "One", assets: firstPhotos)
        let partialDay = DayGroup(id: "partial", title: "Partial", assets: partialPhotos)
        let invalidDay = DayGroup(id: "invalid", title: "Invalid", assets: [photo("invalid")])
        let lastDay = DayGroup(id: "last", title: "Last", assets: lastPhotos)
        let first = TimelineSection(id: "one", monthTitle: "One", count: 3, days: [firstDay])
        let missing = TimelineSection(id: "missing", monthTitle: "Missing", count: 13, days: nil)
        let partial = TimelineSection(id: "partial", monthTitle: "Partial", count: 14, days: [partialDay],
            leadingUnloadedAssetCount: 3, trailingUnloadedAssetCount: 3)
        let invalid = TimelineSection(id: "invalid", monthTitle: "Invalid", count: 9, days: [invalidDay],
            leadingUnloadedAssetCount: 3, trailingUnloadedAssetCount: 3)
        let last = TimelineSection(id: "last", monthTitle: "Last", count: 16, days: [lastDay])
        let sections = [first, missing, partial, invalid, last]
        let index = TimelineGeometryIndex(sections: sections)
        let assets = sections.flatMap { ($0.days ?? []).flatMap(\.assets) }
        let indices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        for columns in 2...5 {
            let rows = TimelineModel.compactProjection(sections, columns: columns).rows
            let expected = frames(in: rows, columns: columns, width: 393, rightToLeft: false)
            assertFramesEqual(index.frames(for: indices, columns: columns, width: 393,
                grouped: false, assetsPerDay: 6, rightToLeft: false), expected)
            let window = index.window(around: assets.count - 1, unitY: 1, viewportReach: .infinity,
                columns: columns, width: 393, grouped: false, assetsPerDay: 6, rightToLeft: false)
            assertFramesEqual(Dictionary(uniqueKeysWithValues: window.tiles.map { (assets[$0.index].id, $0.frame) }), expected)
            let side = AssetGridLayout.tileSide(viewportWidth: 393, columns: columns)
            XCTAssertEqual(window.rowsHeight, rows.reduce(CGFloat.zero) { $0 + $1.height(tileSide: side) }, accuracy: 0.000001)
            let unavailableAnchor = index.window(around: indices["invalid"], unitY: 0.5, viewportReach: 100,
                columns: columns, width: 393, grouped: false, assetsPerDay: 6, rightToLeft: false)
            XCTAssertTrue(unavailableAnchor.tiles.isEmpty)
            XCTAssertEqual(unavailableAnchor.rowsHeight, window.rowsHeight)
        }
    }

    func testGroupedZoomWindowHeightIncludesLeadingAndTrailingPlaceholders() {
        let assets = [photo("first"), photo("second")]
        let sections = [
            TimelineSection(id: "before", monthTitle: "Before", count: 19, days: nil),
            TimelineSection(id: "loaded", monthTitle: "Loaded", count: 2,
                days: [.init(id: "day", title: "Day", assets: assets)]),
            TimelineSection(id: "after", monthTitle: "After", count: 33, days: nil)
        ]
        let before = TimelineModel.placeholderEstimate(count: 19, columns: 4, assetsPerDay: 6)
        let after = TimelineModel.placeholderEstimate(count: 33, columns: 4, assetsPerDay: 2)
        let rows: [TimelineRow] = [
            .placeholder("before", "before", before.tileRows, before.titleBands),
            .titleBand("day", []),
            .tiles("loaded", [.init(colStart: 0, assets: assets)]),
            .placeholder("after", "after", after.tileRows, after.titleBands)
        ]
        let window = TimelineGeometryIndex(sections: sections).window(around: 0, unitY: 0.5, viewportReach: .infinity,
            columns: 4, width: 398, grouped: true, assetsPerDay: 6, rightToLeft: false)
        assertFramesEqual(Dictionary(uniqueKeysWithValues: window.tiles.map { (assets[$0.index].id, $0.frame) }),
            frames(in: rows, columns: 4, width: 398, rightToLeft: false))
        XCTAssertEqual(window.rowsHeight, rows.reduce(CGFloat.zero) { $0 + $1.height(tileSide: 98) })
    }

    func testZoomWindowSlicesLargePlacementAtRowEdges() {
        let assets = Array(repeating: photo("asset"), count: 12_003)
        let day = DayGroup(id: "day", title: "", assets: assets)
        let section = TimelineSection(id: "month", monthTitle: "Month", count: assets.count, days: [day])
        let index = TimelineGeometryIndex(sections: [section])
        for grouped in [false, true] {
            let narrow = index.window(around: 6_001, unitY: 0, viewportReach: 1,
                columns: 4, width: 398, grouped: grouped, assetsPerDay: 6, rightToLeft: false)
            XCTAssertEqual(narrow.tiles.map { $0.index }, Array(6_000..<6_004))

            let touchingPreviousRow = index.window(around: 6_001, unitY: 0, viewportReach: 2,
                columns: 4, width: 398, grouped: grouped, assetsPerDay: 6, rightToLeft: false)
            XCTAssertEqual(touchingPreviousRow.tiles.map { $0.index }, Array(5_996..<6_004))

            let touchingLastRow = index.window(around: 11_997, unitY: 1, viewportReach: 2,
                columns: 4, width: 398, grouped: grouped, assetsPerDay: 6, rightToLeft: false)
            XCTAssertEqual(touchingLastRow.tiles.map { $0.index }, Array(11_996..<12_003))
            XCTAssertEqual(touchingLastRow.rowsHeight, 300_100)
        }
    }

    func testZoomGeometryRefreshesAfterPhotoRemovalAndLibraryReplacement() {
        let assets = (0..<70).map { photo("original-\($0)", day: $0 / 5) }
        let model = TimelineModel(filter: .init(), suppliedAssets: assets)
        model.showsDateHeaders = false
        model.removeAssets(ids: [assets[0].id, assets[8].id])
        let surviving = Set(assets.map(\.id))
        assertFramesEqual(model.framesForZoom(assetIDs: surviving, columns: 5, width: 393, rightToLeft: false),
            frames(in: model.rowsForZoom(columns: 5), columns: 5, width: 393, rightToLeft: false))
        model.replaceSuppliedAssets([photo("replacement")], groupsByDate: true)
        XCTAssertTrue(model.framesForZoom(assetIDs: surviving, columns: 3, width: 393, rightToLeft: false).isEmpty)
        XCTAssertEqual(model.framesForZoom(assetIDs: ["replacement"], columns: 3, width: 393, rightToLeft: false).count, 1)
    }

    func testInteractiveDensityMapsToFingerScaleRatherThanLinearColumnCount() {
        let width: CGFloat = 393
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: 3)
        for scale: CGFloat in [0.75, 0.9, 1, 1.2, 1.4] {
            let density = TimelineGridZoomGeometry.continuousColumns(base: 3, magnification: scale, width: width)
            let calculatedSide = (width + AssetGridLayout.gutter) / density - AssetGridLayout.gutter
            XCTAssertEqual(calculatedSide, side * scale, accuracy: 0.0001)
        }
    }

    func testCalendarCoversKeepMetadataChangesWhenReenteringTheOverview() throws {
        let model = TimelineModel(filter: .init(), suppliedAssets: [photo("older"), photo("newer", day: 1)])
        let initial = try XCTUnwrap(model.photoPeriods(mode: .months).first)
        let cover = try XCTUnwrap(initial.cover)
        _ = model.photoMonthContent(period: initial)
        model.updateAssets(ids: [cover.id]) { value in
            value.isFavorite = true
            value.thumbhash = "updated-cover-revision"
            value.isEdited = true
        }
        let refreshed = try XCTUnwrap(model.photoPeriods(mode: .months).first)
        XCTAssertTrue(try XCTUnwrap(refreshed.cover).isFavorite)
        XCTAssertEqual(refreshed.cover?.thumbhash, "updated-cover-revision")
        XCTAssertEqual(refreshed.cover?.isEdited, true)
        let day = try XCTUnwrap(model.photoMonthContent(period: refreshed).days.first { $0.cover.id == cover.id })
        XCTAssertTrue(day.cover.isFavorite)
        XCTAssertEqual(day.cover.thumbhash, "updated-cover-revision")
        XCTAssertEqual(day.cover.isEdited, true)
    }

    func testVisibleZoomGeometryWorkloadOnLargeLibrary() {
        let assets = (0..<12_000).map { photo("large-\($0)", day: $0 / 35) }
        let model = TimelineModel(filter: .init(), suppliedAssets: assets)
        model.showsDateHeaders = false
        let visible = Set(assets[6_000..<6_120].map(\.id))
        var checksum: CGFloat = 0
        var baseline: [Double] = [], indexed: [Double] = []
        func original() -> Double {
            let start = ContinuousClock.now
            for columns in [2, 3, 4, 5] {
                let result = frames(in: model.rowsForZoom(columns: columns), columns: columns, width: 393,
                    rightToLeft: false, wanted: visible)
                for id in visible { checksum += result[id]?.midY ?? 0 }
                XCTAssertEqual(result.count, visible.count)
            }
            return milliseconds(start.duration(to: .now))
        }
        func bounded() -> Double {
            let start = ContinuousClock.now
            for columns in [2, 3, 4, 5] {
                let result = model.framesForZoom(assetIDs: visible, columns: columns, width: 393, rightToLeft: false)
                for id in visible { checksum += result[id]?.midY ?? 0 }
                XCTAssertEqual(result.count, visible.count)
            }
            return milliseconds(start.duration(to: .now))
        }
        for run in 0..<5 {
            if run.isMultiple(of: 2) { baseline.append(original()); indexed.append(bounded()) }
            else { indexed.append(bounded()); baseline.append(original()) }
        }
        XCTAssertGreaterThan(checksum, 0)
        print("VISIBLE_ZOOM_12000_ASSETS baseline_ms=\(baseline) indexed_ms=\(indexed) checksum=\(checksum)")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func assertFramesEqual(_ actual: [String: CGRect], _ expected: [String: CGRect],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (id, frame) in expected {
            guard let observed = actual[id] else { continue }
            XCTAssertEqual(observed.minX, frame.minX, accuracy: 0.000001, id, file: file, line: line)
            XCTAssertEqual(observed.minY, frame.minY, accuracy: 0.000001, id, file: file, line: line)
            XCTAssertEqual(observed.width, frame.width, accuracy: 0.000001, id, file: file, line: line)
            XCTAssertEqual(observed.height, frame.height, accuracy: 0.000001, id, file: file, line: line)
        }
    }

    private func frames(in rows: [TimelineRow], columns: Int, width: CGFloat, rightToLeft: Bool,
                         wanted: Set<String>? = nil) -> [String: CGRect] {
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: columns)
        var y: CGFloat = 0, result: [String: CGRect] = [:]
        for row in rows {
            if case .tiles(_, let runs) = row {
                for run in runs {
                    for (offset, asset) in run.assets.enumerated() where wanted?.contains(asset.id) ?? true {
                        let x = CGFloat(run.colStart + offset) * (side + AssetGridLayout.gutter)
                        result[asset.id] = CGRect(x: rightToLeft ? width - x - side : x,
                            y: y, width: side, height: side)
                    }
                }
            }
            y += row.height(tileSide: side)
        }
        return result
    }

    private func photo(_ id: String, day: Int = 0) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
            visibility: .timeline, thumbhash: nil,
            fileCreatedAt: Date(timeIntervalSince1970: 1_735_689_600 + Double(day) * 86_400),
            localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
    }
}
