import Foundation
import Synchronization
import XCTest
@testable import Imora

@MainActor
final class PhotoCalendarSourceTests: XCTestCase {
    func testCapturedSourceReusesGridAndAddedSourceCopiesEveryPredicateExceptDateField() {
        let captured = TimelineModel(filter: TimelineFilter(isFavorite: true, order: "asc"), suppliedAssets: [])
        XCTAssertTrue(PhotoCalendarSource(gridModel: captured).model === captured)
        var filter = TimelineFilter()
        filter.visibility = .timeline; filter.withPartners = true; filter.withSharedSpaces = true
        filter.withStacked = true; filter.isFavorite = true; filter.isTrashed = false
        filter.albumId = "album"; filter.spaceId = "space"; filter.personId = "person"
        filter.userId = "owner"; filter.bbox = "1,2,3,4"; filter.order = "desc"; filter.orderBy = "createdAt"
        let added = TimelineModel(filter: filter)
        let source = PhotoCalendarSource(gridModel: added)
        var expected = filter; expected.orderBy = nil
        XCTAssertFalse(source.model === added)
        XCTAssertEqual(source.model.filter, expected)
        XCTAssertEqual(added.filter, filter)
        XCTAssertTrue(source.model.sections.isEmpty)
    }

    func testRealAddedGridUsesIndependentCaptureIndexAndMapsBackToAddedBucket() async throws {
        let server = try LocalHTTPServer { request in Self.reply(request) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "calendar-\(UUID())")
        defer { client.invalidate() }
        let grid = TimelineModel(filter: TimelineFilter(isFavorite: true, albumId: UUID().uuidString, order: "asc", orderBy: "createdAt"))
        grid.assetProjection = { asset in var next = asset; next.isFavorite = true; return next }
        grid.attach(client); await grid.load()
        let addedIDs = grid.sections.map(\.id)
        let source = PhotoCalendarSource(gridModel: grid)
        defer { source.cancel(); grid.suspendForViewer() }
        await source.load(client: client)
        XCTAssertEqual(addedIDs, [Self.addedMonth])
        XCTAssertEqual(source.model.sections.map(\.id), [Self.captureMonth])
        XCTAssertEqual(grid.sections.map(\.id), addedIDs)
        XCTAssertEqual(grid.filter.orderBy, "createdAt")
        XCTAssertEqual(source.model.flatAssets.map(\.isFavorite), [true])
        let asset = try XCTUnwrap(source.model.flatAssets.first)
        XCTAssertEqual(source.gridBucketID(for: asset), Self.addedMonth)
        XCTAssertEqual(source.gridRevealRequest(for: asset)?.assetID, asset.id)
        XCTAssertEqual(source.gridRevealRequest(for: asset)?.bucketID, Self.addedMonth)
        XCTAssertEqual(PhotoCalendarSource.gridBucketID(for: asset, in: grid), Self.addedMonth)
        let anotherFromThatUploadMonth = Self.asset(id: "not-loaded-yet", createdAt: Self.date("2026-11-04T12:00:00Z"))
        XCTAssertEqual(PhotoCalendarSource.gridBucketID(for: anotherFromThatUploadMonth, in: grid), Self.addedMonth)
        XCTAssertNil(PhotoCalendarSource.gridBucketID(for: Self.asset(id: "no-upload-date", createdAt: nil), in: grid))
        let timelineRequests = server.received.filter { $0.path.hasPrefix("/api/timeline/") }
        XCTAssertTrue(timelineRequests.contains { Self.query($0)["orderBy"] == "createdAt" })
        XCTAssertTrue(timelineRequests.contains { Self.query($0)["orderBy"] == nil })
        XCTAssertTrue(timelineRequests.allSatisfy { Self.query($0)["isFavorite"] == "true" })
    }

    func testRevealUsesExactLoadedIDFirstAndNeverGuessesMissingUploadDateFromCaptureDate() {
        let loaded = Self.asset(id: "loaded", createdAt: Self.date("2026-11-02T12:00:00Z"))
        // Supplied model sections are capture-indexed regardless of its filter;
        // exact loaded membership, rather than a date guess, is authoritative.
        let grid = TimelineModel(filter: TimelineFilter(orderBy: "createdAt"), suppliedAssets: [loaded])
        let sameIDWithoutUploadMetadata = Self.asset(id: "loaded", createdAt: nil)
        XCTAssertEqual(PhotoCalendarSource.gridBucketID(for: sameIDWithoutUploadMetadata, in: grid), grid.sections.first?.id)
        XCTAssertNil(PhotoCalendarSource.gridBucketID(for: Self.asset(id: "unknown", createdAt: nil), in: grid))
        XCTAssertNil(PhotoCalendarSource.gridBucketID(for: Self.asset(id: "unknown", createdAt: Self.date("2030-02-02T12:00:00Z")), in: grid))
    }

    func testUnloadedAddedPhotoUsesServerUTCMonthAcrossDeviceTimezoneBoundaries() async throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        let server = try LocalHTTPServer { request in Self.reply(request) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "calendar-boundary-\(UUID())")
        defer { client.invalidate() }
        let grid = TimelineModel(filter: TimelineFilter(albumId: UUID().uuidString, orderBy: "createdAt"))
        grid.attach(client); await grid.load()
        defer { grid.suspendForViewer() }
        for (zone, timestamp) in [("Asia/Shanghai", "2026-11-30T20:00:00Z"),
                                  ("America/Los_Angeles", "2026-11-01T02:00:00Z")] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            let unloaded = Self.asset(id: "unloaded-boundary", createdAt: Self.date(timestamp))
            XCTAssertEqual(PhotoCalendarSource.gridBucketID(for: unloaded, in: grid), Self.addedMonth,
                           "Server Date Added buckets use UTC months, including unloaded photos at a device-local month boundary in \(zone)")
        }
    }

    func testMonthLoadingRequiresEveryRequestedBucketRatherThanOnlyTheCover() async throws {
        let second = "2024-04-01T00:00:00.000Z"
        let server = try LocalHTTPServer { request in
            let query = Self.query(request)
            if request.path.hasPrefix("/api/timeline/buckets?") {
                return .init(body: Data("[{\"timeBucket\":\"\(Self.captureMonth)\",\"count\":1},{\"timeBucket\":\"\(second)\",\"count\":1}]".utf8))
            }
            if query["timeBucket"] == second { return .init(status: 503) }
            return Self.reply(request)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "calendar-complete-\(UUID())")
        defer { client.invalidate() }
        let source = PhotoCalendarSource(gridModel: TimelineModel(filter: TimelineFilter(albumId: UUID().uuidString, orderBy: "createdAt")))
        defer { source.cancel() }
        await source.load(client: client)
        let complete = await source.loadMonth(bucketIDs: [Self.captureMonth, second])
        XCTAssertFalse(complete)
        XCTAssertTrue(source.model.sections.first { $0.id == Self.captureMonth }?.isLoaded == true)
        XCTAssertFalse(source.model.sections.first { $0.id == second }?.isLoaded == true)
    }

    func testAccountSwitchCannotPublishThePreviousCaptureIndexOrResolveItsGridRequest() async throws {
        let firstStarted = Mutex(false)
        let first = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") { firstStarted.withLock { $0 = true }; Thread.sleep(forTimeInterval: 0.2) }
            return Self.reply(request)
        }
        let nextMonth = "2025-07-01T00:00:00.000Z"
        let next = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data("[{\"timeBucket\":\"\(nextMonth)\",\"count\":1}]".utf8)) }
            return .init(body: Self.payload(id: "next-account", captured: "2025-07-03T12:00:00Z"))
        }
        try await first.start(); defer { first.stop() }
        try await next.start(); defer { next.stop() }
        let oldClient = ImoraClient(apiURL: first.apiURL, accessToken: "old-\(UUID())")
        let nextClient = ImoraClient(apiURL: next.apiURL, accessToken: "new-\(UUID())")
        defer { oldClient.invalidate(); nextClient.invalidate() }
        let grid = TimelineModel(filter: TimelineFilter(albumId: UUID().uuidString, orderBy: "createdAt"))
        let source = PhotoCalendarSource(gridModel: grid)
        defer { source.cancel() }
        let oldModel = source.model
        let oldLoad = Task { await source.load(client: oldClient) }
        for _ in 0..<100 where !firstStarted.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(firstStarted.withLock { $0 })
        await source.load(client: nextClient)
        await oldLoad.value
        XCTAssertFalse(source.model === oldModel)
        XCTAssertEqual(source.model.sections.map(\.id), [nextMonth])
        XCTAssertEqual(source.model.flatAssets.map(\.id), ["next-account"])
        nextClient.context.invalidate()
        XCTAssertTrue(source.model.sections.isEmpty)
        XCTAssertNil(source.gridRevealRequest(for: Self.asset(id: "old", createdAt: nil)))
    }

    func testCancelPreventsInFlightIndexFromBecomingCurrent() async throws {
        let started = Mutex(false)
        let server = try LocalHTTPServer { request in
            started.withLock { $0 = true }; Thread.sleep(forTimeInterval: 0.2)
            return Self.reply(request)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "cancel-\(UUID())")
        defer { client.invalidate() }
        let source = PhotoCalendarSource(gridModel: TimelineModel(filter: TimelineFilter(albumId: UUID().uuidString, orderBy: "createdAt")))
        let pending = Task { await source.load(client: client) }
        for _ in 0..<100 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        source.cancel(); await pending.value
        XCTAssertFalse(source.isLoading)
        XCTAssertTrue(source.model.sections.isEmpty)
        let complete = await source.loadMonth(bucketIDs: [Self.captureMonth])
        XCTAssertFalse(complete)
    }

    func testDeviceProvidedCaptureGridRemainsReusableAcrossAccountAttachment() async {
        var asset = Self.asset(id: "local-device", createdAt: nil)
        asset.localIdentifier = "device-resource"
        let grid = TimelineModel(filter: TimelineFilter(), suppliedAssets: [asset])
        let source = PhotoCalendarSource(gridModel: grid)
        await source.load(client: nil)
        let client = ImoraClient(apiURL: URL(string: "https://calendar.fixture.invalid/api")!, accessToken: "local-only")
        defer { source.cancel(); client.invalidate() }
        await source.load(client: client)
        XCTAssertTrue(source.model === grid)
        XCTAssertEqual(source.model.flatAssets.map(\.id), [asset.id])
        XCTAssertNil(source.error)
    }

    func testBorrowedRemoteGridCannotReappearOnRetryAfterAccountChanges() async {
        let grid = TimelineModel(filter: TimelineFilter(), suppliedAssets: [Self.asset(id: "old-account", createdAt: nil)])
        let source = PhotoCalendarSource(gridModel: grid)
        let first = ImoraClient(apiURL: URL(string: "https://calendar.fixture.invalid/api")!, accessToken: "first")
        let next = ImoraClient(apiURL: first.apiURL, accessToken: "next")
        defer { source.cancel(); first.invalidate(); next.invalidate() }
        await source.load(client: first)
        XCTAssertTrue(source.model === grid)
        await source.load(client: next)
        await source.load(client: next)
        XCTAssertTrue(source.model.sections.isEmpty)
        XCTAssertNotNil(source.error)
        XCTAssertNil(source.gridRevealRequest(for: grid.flatAssets[0]))
    }

    nonisolated private static let captureMonth = "2024-03-01T00:00:00.000Z"
    nonisolated private static let addedMonth = "2026-11-01T00:00:00.000Z"
    nonisolated private static func query(_ request: LocalHTTPServer.Request) -> [String: String] {
        let items = URLComponents(string: "http://fixture\(request.path)")?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
    }
    nonisolated private static func reply(_ request: LocalHTTPServer.Request) -> LocalHTTPServer.Response {
        let query = query(request)
        if request.path.hasPrefix("/api/timeline/buckets?") {
            let month = query["orderBy"] == "createdAt" ? addedMonth : captureMonth
            return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8))
        }
        return .init(body: payload(id: "same-photo", captured: "2024-03-03T12:00:00Z"))
    }
    nonisolated private static func payload(id: String, captured: String) -> Data {
        Data("{\"id\":[\"\(id)\"],\"ownerId\":[\"fixture\"],\"isImage\":[true],\"isFavorite\":[false],\"isTrashed\":[false],\"thumbhash\":[null],\"fileCreatedAt\":[\"\(captured)\"],\"localOffsetHours\":[0],\"duration\":[null],\"livePhotoVideoId\":[null],\"ratio\":[1],\"createdAt\":[\"2026-11-02T12:00:00Z\"]}".utf8)
    }
    nonisolated private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    nonisolated private static func asset(id: String, createdAt: Date?) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false, visibility: .timeline,
              thumbhash: nil, fileCreatedAt: date("2024-03-03T12:00:00Z"), localOffsetHours: 0, duration: nil,
              livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: createdAt)
    }
}
