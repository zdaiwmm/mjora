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
