import Foundation
import Synchronization
import UIKit
import XCTest
@testable import Imora

@MainActor
final class Phase4ImageDemandTests: XCTestCase {
    private func imageBytes() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
    }

    func testVisibleDemandOvertakesQueuedPrefetch() async throws {
        let bytes = try imageBytes(), starts = Mutex<[String]>([])
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path.contains("/thumbnail") {
                starts.withLock { $0.append(request.path) }
                return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "priority-\(UUID())")
        client.confirmMediaAccount("priority-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        let prefetcher = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { prefetcher.cancel() }
        let queued = client.thumbnailURL(assetID: "queued-\(UUID())", cacheKey: "r1")
        let visibleID = "visible-\(UUID())"
        let visibleURL = client.thumbnailURL(assetID: visibleID, cacheKey: "r1")
        prefetcher.warm(remote: [queued], local: [])
        try await Task.sleep(for: .milliseconds(250))
        let visible = Task { try await ImageLoader.shared.image(for: visibleURL, targetPixelSize: 416) }
        defer { visible.cancel() }
        try await Task.sleep(for: .milliseconds(250))
        await slots.release(held.removeFirst())
        for _ in 0..<200 {
            if !starts.withLock({ $0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try XCTUnwrap(starts.withLock { $0.first })
        XCTAssertTrue(first.contains(visibleID), "A visible network request must get the next shared slot before an already queued prefetch")
        for permit in held { await slots.release(permit) }
        held.removeAll()
        let image = try await visible.value
        XCTAssertNotNil(image.cgImage)
    }

    func testCancelOnePrefetchKeepsOtherScreenConsumer() async throws {
        let bytes = try imageBytes(), gate = DispatchSemaphore(value: 0), started = Mutex(false)
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            started.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 15)
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "prefetch-\(UUID())")
        client.confirmMediaAccount("prefetch-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let url = client.thumbnailURL(assetID: "shared-\(UUID())", cacheKey: "r1")
        let first = ThumbnailPrefetcher(targetPixelSize: 416), second = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { first.cancel(); second.cancel() }
        first.warm(remote: [url], local: [])
        second.warm(remote: [url], local: [])
        for _ in 0..<200 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started.withLock { $0 }, "The shared prefetch must reach the real endpoint")
        try await Task.sleep(for: .milliseconds(200))
        first.cancel()
        gate.signal()
        for _ in 0..<200 {
            if ImageLoader.shared.cachedImage(for: url, targetPixelSize: 416) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 416)?.cgImage,
            "Cancelling one screen must not cancel another screen's outstanding prefetch")
    }

    func testVisibleConsumerPromotesItsAlreadyQueuedPrefetch() async throws {
        let bytes = try imageBytes(), starts = Mutex<[String]>([])
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            starts.withLock { $0.append(request.path) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "promote-\(UUID())")
        client.confirmMediaAccount("promote-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        let first = ThumbnailPrefetcher(targetPixelSize: 416), second = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { first.cancel(); second.cancel() }
        let firstURL = client.thumbnailURL(assetID: "older-prefetch-\(UUID())", cacheKey: "r1")
        let promotedID = "promoted-\(UUID())"
        let promotedURL = client.thumbnailURL(assetID: promotedID, cacheKey: "r1")
        first.warm(remote: [firstURL], local: [])
        try await Task.sleep(for: .milliseconds(200))
        second.warm(remote: [promotedURL], local: [])
        try await Task.sleep(for: .milliseconds(200))
        let visible = Task { try await ImageLoader.shared.image(for: promotedURL, targetPixelSize: 416) }
        defer { visible.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        await slots.release(held.removeFirst())
        for _ in 0..<200 {
            if !starts.withLock({ $0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try XCTUnwrap(starts.withLock { $0.first }).contains(promotedID),
            "A visible subscriber must promote its already queued shared producer")
        for permit in held { await slots.release(permit) }
        held.removeAll()
        let image = try await visible.value
        XCTAssertNotNil(image.cgImage)
        XCTAssertEqual(starts.withLock { $0.filter { $0.contains(promotedID) }.count }, 1,
            "Promotion must reuse the same endpoint work")
    }

    func testReverseScrollDropsOldWindow() async throws {
        let bytes = try imageBytes(), starts = Mutex<[String]>([])
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            starts.withLock { $0.append(request.path) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "reverse-\(UUID())")
        client.confirmMediaAccount("reverse-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let prefix = "direction-\(UUID())"
        let assets = (0..<60).map { index in
            Asset(id: "\(prefix)-\(index)", ownerId: "fixture", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, thumbhash: "r1",
                fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: assets, groupsSuppliedAssetsByDate: false)
        let rows = model.rows.compactMap { row -> (String, Int)? in
            guard case .tiles(let id, let runs) = row else { return nil }
            return (id, runs.reduce(0) { $0 + $1.assets.count })
        }
        let middle = try XCTUnwrap(rows.dropFirst(rows.count / 2).first)
        let firstID = try XCTUnwrap(model.firstAssetIDByRowID[middle.0])
        let low = try XCTUnwrap(model.flatAssetIndex(for: firstID)), end = low + middle.1
        let reverseIndex = low - middle.1 - 1, oldIndex = end + middle.1
        XCTAssertGreaterThanOrEqual(reverseIndex, 0); XCTAssertLessThan(oldIndex, model.flatAssets.count)
        let reverseID = model.flatAssets[reverseIndex].id, oldID = model.flatAssets[oldIndex].id
        let slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        let prefetcher = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { prefetcher.cancel() }
        prefetcher.update(visibleRowIDs: [middle.0], model: model, client: client, backup: nil, direction: 1)
        try await Task.sleep(for: .milliseconds(250))
        prefetcher.update(visibleRowIDs: [middle.0], model: model, client: client, backup: nil, direction: -1)
        try await Task.sleep(for: .milliseconds(250))
        for permit in held { await slots.release(permit) }
        held.removeAll()
        for _ in 0..<400 {
            if starts.withLock({ paths in paths.contains { $0.contains(reverseID) } }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(starts.withLock { paths in paths.contains { $0.contains(reverseID) } },
            "The newly predicted side must reach the actual endpoint")
        XCTAssertFalse(starts.withLock { paths in paths.contains { $0.contains(oldID) } },
            "Queued far-side work from the old direction must be cancelled")
    }

    func testFastScrollPreservesForwardDecodeAndOnlyFetchesTrailingBytes() async throws {
        let bytes = try imageBytes(), starts = Mutex<[String]>([])
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            starts.withLock { $0.append(request.path) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "fling-\(UUID())")
        client.confirmMediaAccount("fling-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let prefix = "fling-asset-\(UUID())"
        let assets = (0..<60).map { index in
            Asset(id: "\(prefix)-\(index)", ownerId: "fixture", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, thumbhash: "r1",
                fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: assets, groupsSuppliedAssetsByDate: false)
        let rows = model.rows.compactMap { row -> (String, Int)? in
            guard case .tiles(let id, let runs) = row else { return nil }
            return (id, runs.reduce(0) { $0 + $1.assets.count })
        }
        let middle = try XCTUnwrap(rows.dropFirst(rows.count / 2).first)
        let firstID = try XCTUnwrap(model.firstAssetIDByRowID[middle.0])
        let low = try XCTUnwrap(model.flatAssetIndex(for: firstID)), end = low + middle.1
        let trailingID = model.flatAssets[low - 1].id, forwardID = model.flatAssets[end].id
        let trailing = client.thumbnailURL(assetID: trailingID, cacheKey: "r1")
        let forward = client.thumbnailURL(assetID: forwardID, cacheKey: "r1")
        let prefetcher = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { prefetcher.cancel() }
        prefetcher.update(visibleRowIDs: [middle.0], model: model, client: client, backup: nil, direction: 1, isFast: true)
        for _ in 0..<400 {
            if starts.withLock({ paths in paths.contains { $0.contains(trailingID) } }),
               ImageLoader.shared.cachedImage(for: forward, targetPixelSize: 416) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(starts.withLock { paths in paths.contains { $0.contains(trailingID) } },
            "The trailing side should still fetch encoded bytes")
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: forward, targetPixelSize: 416)?.cgImage,
            "The immediately predicted side should have a decoded image")
        XCTAssertNil(ImageLoader.shared.cachedImage(for: trailing, targetPixelSize: 416),
            "A fast fling should not decode the trailing side")
    }

    #if DEBUG
    func testSameURLNewGenerationDoesNotJoinRetiredTransfer() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func bytes(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let red = try bytes(.red), blue = try bytes(.blue)
        let oldGate = DispatchSemaphore(value: 0), newGate = DispatchSemaphore(value: 0)
        let reads = Mutex(0), oldStarted = Mutex(false), newStarted = Mutex(false), wireOK = Mutex(true)
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            if request.path.contains("imora-content-generation") || request.path.contains("imora-work-session")
                || request.path.contains("imora-private-producer")
                || request.headers["authorization"] != "Bearer generation-fixture" { wireOK.withLock { $0 = false } }
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 1 {
                oldStarted.withLock { $0 = true }; _ = oldGate.wait(timeout: .now() + 20)
                return .init(headers: ["Content-Type": "image/jpeg"], body: red)
            }
            newStarted.withLock { $0 = true }; _ = newGate.wait(timeout: .now() + 20)
            return .init(headers: ["Content-Type": "image/jpeg"], body: blue)
        }
        try await server.start(); defer { oldGate.signal(); newGate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "generation-fixture")
        client.confirmMediaAccount("generation-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let scope = client.mediaDisplayScope, generations = MediaContentGenerations.shared
        let journal = LaunchPreviewStore.rootDirectory.appending(path: "content-generations.json")
        let before = try? Data(contentsOf: journal)
        let restore = try generations.isolatedFixtureRestorer(scopes: [scope])
        var restored = false
        defer { if !restored { try? restore() } }
        let id = "generation-asset-\(UUID())"
        let url = client.thumbnailURL(assetID: id, cacheKey: "same-opaque-revision")
        let oldKey = ImageLoader.shared.requestKey(for: url, targetPixelSize: 416)
        let old = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 416) }
        defer { old.cancel() }
        for _ in 0..<200 {
            if oldStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard oldStarted.withLock({ $0 }) else { XCTFail("The old endpoint must be held"); throw CocoaError(.fileReadUnknown) }
        _ = try generations.retire(scope: scope, subjects: [.remoteAsset(id)], retiresSourceRevisions: false)
        XCTAssertNotEqual(oldKey, ImageLoader.shared.requestKey(for: url, targetPixelSize: 416))
        let current = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 416) }
        defer { current.cancel() }
        for _ in 0..<200 {
            if newStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard newStarted.withLock({ $0 }) else {
            XCTFail("A new content generation must start its own endpoint while the retired transfer is held")
            oldGate.signal(); newGate.signal(); _ = try? await old.value; _ = try? await current.value
            return
        }
        let peer = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 416) }
        let otherSize = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 640) }
        defer { peer.cancel() }
        defer { otherSize.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.withLock { $0 }, 2, "Same-current-generation consumers and compatible sizes must still share one transfer")
        oldGate.signal()
        do { _ = try await old.value; XCTFail("Retired endpoint bytes cannot be delivered") } catch { }
        newGate.signal()
        let image = try await current.value, shared = try await peer.value, larger = try await otherSize.value
        XCTAssertNotNil(image.cgImage); XCTAssertNotNil(shared.cgImage); XCTAssertNotNil(larger.cgImage)
        XCTAssertGreaterThanOrEqual(image.cgImage?.width ?? 0, 416)
        XCTAssertGreaterThanOrEqual(larger.cgImage?.width ?? 0, 640)
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[2], 180); XCTAssertLessThan(pixel[0], 80)
        XCTAssertTrue(wireOK.withLock { $0 }, "The local work identity must never alter the authenticated wire endpoint")
        try restore(); restored = true
        XCTAssertEqual(try? Data(contentsOf: journal), before, "The synthetic scope must leave all existing journal bytes intact")
    }
    #endif

    func testCancelPrefetchKeepsVisibleSharedConsumer() async throws {
        let bytes = try imageBytes(), gate = DispatchSemaphore(value: 0), started = Mutex(false)
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            started.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 15)
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "visible-consumer-\(UUID())")
        client.confirmMediaAccount("visible-consumer-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let url = client.thumbnailURL(assetID: "shared-visible-\(UUID())", cacheKey: "r1")
        let prefetcher = ThumbnailPrefetcher(targetPixelSize: 416)
        defer { prefetcher.cancel() }
        prefetcher.warm(remote: [url], local: [])
        for _ in 0..<200 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started.withLock { $0 })
        let visible = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 416) }
        defer { visible.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        prefetcher.cancel(); gate.signal()
        let image = try await visible.value
        XCTAssertNotNil(image.cgImage, "Dropping prefetch must preserve the visible consumer's real image")
    }
}
