import UIKit
import XCTest
@testable import Imora

@MainActor
final class GridThumbnailNetworkTests: XCTestCase {
    func testServerThumbnailErrorUsesPreviewWithoutOriginalOrVideo() async throws {
        let sharp = imageData(pixels: 700)
        let server = try LocalHTTPServer { request in
            request.path.contains("size=preview")
                ? .init(headers: ["Content-Type": "image/png"], body: sharp)
                : .init(status: 500)
        }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        let image = try await ImageLoader.shared.gridThumbnail(
            thumbnailURL: client.thumbnailURL(assetID: UUID().uuidString),
            previewURL: client.thumbnailURL(assetID: "preview-fixture", size: "preview"), targetPixelSize: 600)
        XCTAssertEqual(image.size.width * image.scale, 600, accuracy: 1)
        XCTAssertEqual(server.received.count, 2)
        XCTAssertEqual(server.received.filter { $0.path.contains("size=preview") }.count, 1)
        XCTAssertEqual(server.received.filter { $0.path.contains("original") || $0.path.contains("video") }.count, 0)
    }

    func testAdequateThumbnailDoesNotUpgrade() async throws {
        let data = imageData(pixels: 700)
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/png"], body: data) }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        let id = UUID().uuidString
        _ = try await ImageLoader.shared.gridThumbnail(thumbnailURL: client.thumbnailURL(assetID: id),
            previewURL: client.thumbnailURL(assetID: id, size: "preview"), targetPixelSize: 300)
        XCTAssertEqual(server.received.count, 1)
        XCTAssertFalse(server.received[0].path.contains("size=preview"))
        XCTAssertEqual(server.received.filter { $0.path.contains("original") || $0.path.contains("video") }.count, 0)
    }

    func testUndersizedThumbnailUpgradesOnceAndSmallPreviewStops() async throws {
        let tiny = imageData(pixels: 100)
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/png"], body: tiny) }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        let id = UUID().uuidString
        let image = try await ImageLoader.shared.gridThumbnail(
            thumbnailURL: client.thumbnailURL(assetID: id),
            previewURL: client.thumbnailURL(assetID: id, size: "preview"), targetPixelSize: 600)
        XCTAssertEqual(image.size.width * image.scale, 100, accuracy: 1)
        XCTAssertEqual(server.received.count, 2)
        XCTAssertEqual(server.received.filter { $0.path.contains("size=preview") }.count, 1)
        XCTAssertEqual(server.received.filter { $0.path.contains("original") || $0.path.contains("video") }.count, 0)
    }

    func testFailedDerivativesAreRetriedRatherThanCachedAsSuccess() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 500) }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        let id = UUID().uuidString
        for _ in 0..<2 {
            do {
                _ = try await ImageLoader.shared.gridThumbnail(thumbnailURL: client.thumbnailURL(assetID: id),
                    previewURL: client.thumbnailURL(assetID: id, size: "preview"), targetPixelSize: 600)
                XCTFail("A failed derivative became success")
            } catch {}
        }
        XCTAssertEqual(server.received.count, 4)
        XCTAssertNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: id), targetPixelSize: 600))
    }

    func testAccountSwitchCancelsOldRequestAndNeverStartsOldPreview() async throws {
        let gate = DispatchSemaphore(value: 0)
        let data = imageData(pixels: 100)
        let server = try LocalHTTPServer { _ in
            _ = gate.wait(timeout: .now() + 5)
            return .init(headers: ["Content-Type": "image/png"], body: data)
        }
        try await server.start()
        let old = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-old")
        let next = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-next")
        ImageLoader.shared.configure(client: old)
        defer { gate.signal(); ImageLoader.shared.configure(client: nil); old.invalidate(); next.invalidate(); server.stop() }
        let id = UUID().uuidString
        let operation = Task { try await ImageLoader.shared.gridThumbnail(thumbnailURL: old.thumbnailURL(assetID: id),
            previewURL: old.thumbnailURL(assetID: id, size: "preview"), targetPixelSize: 600) }
        for _ in 0..<200 where server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.received.count, 1)
        ImageLoader.shared.configure(client: next)
        gate.signal()
        do { _ = try await operation.value; XCTFail("Old account completed after switch") } catch {}
        XCTAssertEqual(server.received.count, 1, "Old preview must not inherit the next account")
    }

    func testOffscreenCancellationDoesNotUpgradeAfterLateResponse() async throws {
        let gate = DispatchSemaphore(value: 0)
        let data = imageData(pixels: 100)
        let server = try LocalHTTPServer { _ in
            _ = gate.wait(timeout: .now() + 5)
            return .init(headers: ["Content-Type": "image/png"], body: data)
        }
        try await server.start()
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        ImageLoader.shared.configure(client: client)
        defer { gate.signal(); ImageLoader.shared.configure(client: nil); client.invalidate(); server.stop() }
        let id = UUID().uuidString
        let operation = Task { try await ImageLoader.shared.gridThumbnail(thumbnailURL: client.thumbnailURL(assetID: id),
            previewURL: client.thumbnailURL(assetID: id, size: "preview"), targetPixelSize: 600) }
        for _ in 0..<200 where server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        operation.cancel(); gate.signal()
        do { _ = try await operation.value; XCTFail("Offscreen request completed") } catch {}
        XCTAssertEqual(server.received.count, 1)
    }

    private func imageData(pixels: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).pngData { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }
}
