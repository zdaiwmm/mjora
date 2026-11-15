import XCTest
import UIKit
@testable import Imora

@MainActor
final class Phase4ImagePresentationFlowTests: XCTestCase {
    private func client(_ token: String = "fixture-token") -> ImoraClient {
        ImoraClient(apiURL: URL(string: "https://fixture.invalid/api")!, accessToken: token)
    }

    private func asset() -> Asset {
        Asset(id: "same-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
              visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
              duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
    }

    func testRestorePreparesActualBitmapAndSeedsFirstSynchronousGridLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = client(UUID().uuidString)
        first.confirmMediaAccount("alice")
        let asset = asset()
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: first, pixels: 416)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 416, height: 416)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 416, height: 416))
        }
        let encoded = await MediaPresentationCoordinator.encode(image: image, key: key)
        let record = try XCTUnwrap(encoded)
        let snapshot = LaunchViewportSnapshot(scope: first.mediaDisplayScope, source: "cloud", filter: "default",
            sort: "date-desc", anchor: asset.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([asset]))
        let store = LaunchPreviewStore(root: root)
        _ = try await store.checkpoint(snapshot: snapshot, images: [record])
        first.invalidate()
        let second = client(UUID().uuidString)
        second.confirmMediaAccount("alice")
        ImageLoader.shared.configure(client: second)
        defer { ImageLoader.shared.configure(client: nil); second.invalidate() }
        let coordinator = MediaPresentationCoordinator(store: LaunchPreviewStore(root: root))
        let prepared = try await coordinator.restore(client: second, filter: "default", layout: snapshot.layout)
        XCTAssertEqual(prepared?.images.count, 1)
        let bitmap = try XCTUnwrap(prepared?.images[key])
        XCTAssertNotNil(bitmap.cgImage)
        XCTAssertGreaterThanOrEqual(min(bitmap.size.width, bitmap.size.height) * bitmap.scale, 416)
        let lookup = ImageLoader.shared.cachedImage(for: second.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416)
        XCTAssertNotNil(lookup?.cgImage, "The very first grid lookup needs a real surface")
        XCTAssertNil(ImageLoader.shared.cachedImage(for: first.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416), "Stable identity must not authorize an old runtime URL")

        // Exercise a committed UIKit content frame rather than a ready Bool.
        let controller = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        window.rootViewController = controller
        let surface = UIImageView(image: lookup)
        surface.frame = window.bounds
        controller.view.addSubview(surface)
        window.makeKeyAndVisible()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let frame = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(frame.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        let rgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(rgba[0], 200)
        XCTAssertLessThan(rgba[1], 40)
        XCTAssertLessThan(rgba[2], 40)
        let attachment = XCTAttachment(image: frame)
        attachment.name = "phase4-restored-real-preview-content-frame"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreparedSurfaceDoesNotSurvivePermissionOrSessionGeneration() async throws {
        let client = client(UUID().uuidString)
        let coordinator = MediaPresentationCoordinator()
        let access = MediaPresentationCoordinator.access(for: client)
        client.invalidate()
        let key = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        XCTAssertNil(coordinator.presentation(for: key, access: access, client: client))
    }

    func testSmallNativeFinalImageEncodesWithoutInventingGridResolution() async throws {
        let client = client(UUID().uuidString)
        defer { client.invalidate() }
        let key = MediaDisplayKeyV1(scope: client.mediaDisplayScope,
            subject: .localAsset(installationID: "fixture-install", localIdentifier: "fixture-small-native"),
            sourceRevision: "native-revision", presentationRevision: "committed:native-revision", variant: .grid,
            pixelBucket: 416, fitMode: "fit-cover", orientationRevision: "source", colorProfile: "source")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let unproven = await MediaPresentationCoordinator.encode(image: small, key: key)
        XCTAssertNil(unproven, "A tiny derivative without native-source proof is insufficient")
        let native = NativeImageResolution(sourceRevision: "native-revision", pixelWidth: 16, pixelHeight: 16)
        let encoded = await MediaPresentationCoordinator.encode(image: small, key: key, nativeResolution: native)
        let result = try XCTUnwrap(encoded)
        XCTAssertEqual(result.key.pixelBucket, 416)
        XCTAssertEqual(result.pixelWidth, 16)
        XCTAssertEqual(result.pixelHeight, 16)
        XCTAssertTrue(result.isQualified)
    }

    func testHostSnapshotCannotVerifyANewCredential() {
        let first = client(UUID().uuidString), second = client(UUID().uuidString)
        first.confirmMediaAccount("alice")
        XCTAssertEqual(first.mediaDisplayScope.accountID, "alice")
        let restart = client(first.accessToken)
        XCTAssertEqual(restart.mediaDisplayScope.accountID, "alice", "Only the credential with persisted evidence may restore verified scope")
        restart.invalidate()
        XCTAssertNil(second.mediaDisplayScope.accountID)
        XCTAssertNotEqual(first.mediaDisplayScope, second.mediaDisplayScope)
        first.invalidate(); second.invalidate()
    }

    func testInitialGeometryWaitResumesOnRealLayoutAndCancelsWhenScreenLeaves() async throws {
        let model = TimelineModel(filter: TimelineFilter())
        var continued = false
        let waiting = Task { await model.waitForLaunchLayout(); continued = true }
        await Task.yield()
        XCTAssertFalse(continued)
        model.launchLayout = .init(width: 390, height: 700, scale: 3, columns: 3)
        await waiting.value
        XCTAssertTrue(continued)
        let leaving = TimelineModel(filter: TimelineFilter())
        let cancelled = Task { await leaving.waitForLaunchLayout() }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
    }

    func testTimelineRestoresPreparedW0AndAnchorWhileServerIsOffline() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 503) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "launch-flow-\(UUID())")
        client.confirmMediaAccount("alice")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let asset = asset()
        let filter = TimelineFilter(order: "launch-flow-\(UUID())")
        let filterKey = try XCTUnwrap(TimelineCache.key(for: filter))
        let layout = LaunchViewportSnapshot.Layout(width: 390, height: 700, scale: 3, columns: 3)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 416, height: 416)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 416, height: 416))
        }
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 416)
        let encoded = await MediaPresentationCoordinator.encode(image: image, key: key)
        let record = try XCTUnwrap(encoded)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: filterKey,
            sort: "desc", anchor: asset.id, layout: layout, visibleKeys: [key], metadata: try JSONEncoder().encode([asset]))
        _ = try await LaunchPreviewStore.shared.checkpoint(snapshot: snapshot, images: [record])
        let model = TimelineModel(filter: filter)
        model.launchLayout = layout
        model.attach(client, preparesLaunchViewport: true)
        await model.load()
        XCTAssertEqual(model.flatAssets.map(\.id), [asset.id])
        XCTAssertEqual(model.pendingLaunchAnchor?.id, asset.id)
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416)?.cgImage)
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" })
        try await LaunchPreviewStore.shared.invalidate(scope: client.mediaDisplayScope)
    }
}
