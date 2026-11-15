import Foundation
import ImageIO
import Photos
import UIKit
import os

nonisolated struct PreparedViewport: Sendable {
    let snapshot: LaunchViewportSnapshot
    let assets: [Asset]
    let access: MediaAccessGeneration
    let images: [MediaDisplayKeyV1: UIImage]
    let missingKeys: [MediaDisplayKeyV1]
    let checkpointMiss: Bool
}

nonisolated struct ViewportRequest: Sendable {
    let snapshot: LaunchViewportSnapshot
    let assets: [Asset]
    let records: [PreparedImageRecord]
    let client: ImoraClient
    let access: MediaAccessGeneration
    let checkpointMiss: Bool
}

/// A bounded preparation/commit boundary over the existing Nuke and PhotoKit caches.
/// It owns no downloader, second bitmap cache, source files, drafts or backup evidence.
@MainActor
final class MediaPresentationCoordinator {
    static let shared = MediaPresentationCoordinator()
    private let store: LaunchPreviewStore
    private var checkpointTask: Task<Void, Never>?
    private var viewportID: UUID?
    private var pendingViewport: (snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient)?
    private var completedViewport: LaunchViewportSnapshot?
    private var anchorTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vexcited.imora", category: "LaunchPreview")

    init(store: LaunchPreviewStore = .shared) { self.store = store }

    nonisolated static func access(for client: ImoraClient) -> MediaAccessGeneration {
        .init(session: client.context.id, permission: LocalImageLoader.shared.permissionGeneration)
    }

    nonisolated static func gridKey(asset: Asset, client: ImoraClient, pixels: CGFloat) -> MediaDisplayKeyV1 {
        let subject: MediaDisplayKeyV1.Subject
        if let local = asset.localIdentifier {
            subject = .localAsset(installationID: DeviceID.current, localIdentifier: local)
        } else { subject = .remoteAsset(asset.id) }
        return .init(scope: client.mediaDisplayScope, subject: subject,
            sourceRevision: asset.localIdentifier == nil ? (asset.thumbhash ?? "") : (asset.localImageVersion ?? ""),
            presentationRevision: "committed:\(asset.localIdentifier == nil ? (asset.thumbhash ?? "") : (asset.localImageVersion ?? ""))",
            variant: .grid, pixelBucket: max(1, Int(pixels.rounded(.up))), fitMode: "fit-cover",
            orientationRevision: "source", colorProfile: "source")
    }

    nonisolated static func localScope(asset: Asset, client: ImoraClient, pixels: CGFloat) -> String {
        AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: pixels)
    }

    func presentation(for key: MediaDisplayKeyV1, access: MediaAccessGeneration, client: ImoraClient) -> UIImage? {
        guard client.context.isActive, Self.access(for: client) == access,
              key.scope == client.mediaDisplayScope else { return nil }
        switch key.subject {
        case .remoteAsset(let id):
            return ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: id, cacheKey: key.sourceRevision),
                targetPixelSize: CGFloat(key.pixelBucket))
        case .localAsset, .artwork: return nil
        }
    }

    func restore(client: ImoraClient, filter: String, layout: LaunchViewportSnapshot.Layout?) async throws -> PreparedViewport? {
        let started = ContinuousClock.now
        let access = Self.access(for: client)
        let context = LaunchContext(access: access, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                                    filter: filter, layout: layout)
        let read = try await store.restore(scope: client.mediaDisplayScope, context: context)
        var snapshot: LaunchViewportSnapshot
        let records: [PreparedImageRecord]
        var miss: Bool
        switch read {
        case .complete(let value, let images): (snapshot, records, miss) = (value, images, false)
        case .partial(let value, let images, _): (snapshot, records, miss) = (value, images, true)
        case .invalid(let reason): log.notice("pack invalid: \(reason, privacy: .public)"); return nil
        case .notAvailable: log.info("pack unavailable"); return nil
        }
        guard client.context.isActive, Self.access(for: client) == access,
              snapshot.scope == client.mediaDisplayScope,
              let assets = try? JSONDecoder().decode([Asset].self, from: snapshot.metadata),
              assets.count == snapshot.visibleKeys.count,
              zip(assets, snapshot.visibleKeys).allSatisfy({ asset, key in
                  asset.visibility != .locked && asset.visibility != .hidden && !asset.isTrashed
                    && Self.gridKey(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)) == key
              }) else { return nil }
        if let layout {
            let side = AssetGridLayout.tileSide(viewportWidth: CGFloat(layout.width), columns: layout.columns)
            let pixels = min(1280, (max(1, side * CGFloat(layout.scale)) / 32).rounded(.up) * 32)
            let keys = assets.map { Self.gridKey(asset: $0, client: client, pixels: pixels) }
            if snapshot.layout != layout || snapshot.visibleKeys != keys {
            miss = true
            let old = snapshot
            snapshot = .init(scope: old.scope, source: old.source, filter: old.filter, sort: old.sort,
                anchor: old.anchor, layout: layout, visibleKeys: keys,
                metadata: old.metadata, bucketList: old.bucketList, bucketIDByAssetID: old.bucketIDByAssetID, anchorOffset: old.anchorOffset)
            }
        }
        let prepared = try await prepareViewport(request: .init(snapshot: snapshot, assets: assets, records: records,
            client: client, access: access, checkpointMiss: miss))
        log.info("restore prepared \(prepared.images.count)/\(assets.count), checkpointMiss=\(miss), elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public)")
        return prepared
    }

    func prepareViewport(request: ViewportRequest) async throws -> PreparedViewport {
        let client = request.client
        guard client.context.isActive, Self.access(for: client) == request.access else { throw CancellationError() }
        let pairs = Array(zip(request.assets, request.snapshot.visibleKeys))
        // At most two reads/decodes at once; no full-library fetch enters this path.
        let images = await withTaskGroup(of: (MediaDisplayKeyV1, UIImage)?.self) { group in
            var iterator = pairs.makeIterator()
            func addNext() {
                guard let (asset, key) = iterator.next() else { return }
                let record = request.records.first { $0.key == key }
                group.addTask { await Self.prepare(asset: asset, key: key, record: record, client: client) }
            }
            for _ in 0..<2 { addNext() }
            var images: [MediaDisplayKeyV1: UIImage] = [:]
            while let result = await group.next() {
                if let (key, image) = result { images[key] = image }
                if !Task.isCancelled { addNext() }
            }
            return images
        }
        try Task.checkCancellation()
        guard client.context.isActive, Self.access(for: client) == request.access,
              client.mediaDisplayScope == request.snapshot.scope else { throw CancellationError() }
        // One MainActor transaction publishes real prepared images before timeline metadata.
        for (asset, key) in pairs {
            guard let image = images[key] else { continue }
            if let local = asset.localIdentifier {
                LocalImageLoader.shared.installPrepared(image, localIdentifier: local, targetPixelSize: CGFloat(key.pixelBucket),
                    cacheScope: Self.localScope(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)), permission: request.access.permission)
            } else {
                ImageLoader.shared.installPrepared(image, url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                    targetPixelSize: CGFloat(key.pixelBucket), client: client)
            }
        }
        return .init(snapshot: request.snapshot, assets: request.assets, access: request.access, images: images,
            missingKeys: request.snapshot.visibleKeys.filter { images[$0] == nil }, checkpointMiss: request.checkpointMiss)
    }

    @concurrent
    private nonisolated static func prepare(asset: Asset, key: MediaDisplayKeyV1, record: PreparedImageRecord?, client: ImoraClient) async -> (MediaDisplayKeyV1, UIImage)? {
        guard !Task.isCancelled, client.context.isActive else { return nil }
        if let local = asset.localIdentifier, !(await LocalImageLoader.shared.canReadPrepared(local)) { return nil }
        var native: NativeImageResolution?
        if let local = asset.localIdentifier {
            native = await LocalImageLoader.shared.nativeResolution(localIdentifier: local, sourceRevision: key.sourceRevision)
            if !key.sourceRevision.isEmpty && native == nil { return nil }
        }
        var image: UIImage?
        if let record, record.isQualified, record.nativeResolution == nil || record.nativeResolution == native {
            image = decode(record)
        }
        if image == nil {
            if let local = asset.localIdentifier {
                image = await LocalImageLoader.shared.image(localIdentifier: local, targetPixelSize: CGFloat(key.pixelBucket),
                    contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, allowsNetwork: false,
                    cacheScope: localScope(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)))
            } else {
                image = await ImageLoader.shared.diskImage(for: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                    targetPixelSize: CGFloat(key.pixelBucket))
            }
        }
        guard let image,
              min(image.size.width, image.size.height) * image.scale >= CGFloat(key.pixelBucket)
                || native?.accepts(width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), key: key) == true,
              let prepared = await image.byPreparingForDisplay() else { return nil }
        return (key, prepared)
    }

    private nonisolated static func decode(_ record: PreparedImageRecord) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(record.bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == record.pixelWidth, height == record.pixelHeight,
              max(width, height) <= 8192,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    @concurrent
    nonisolated static func encode(image: UIImage, key: MediaDisplayKeyV1, nativeResolution: NativeImageResolution? = nil) async -> PreparedImageRecord? {
        guard key.pixelBucket <= 2048,
              min(image.size.width, image.size.height) * image.scale >= CGFloat(key.pixelBucket)
                || nativeResolution?.accepts(width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), key: key) == true,
              image.cgImage != nil else { return nil }
        // Normalize orientation and reduce only this viewport's preview, never its source.
        let ratio = image.size.width / max(1, image.size.height)
        let short = min(CGFloat(key.pixelBucket), min(image.size.width, image.size.height) * image.scale)
        let size = ratio >= 1 ? CGSize(width: short * ratio, height: short) : CGSize(width: short, height: short / ratio)
        guard size.width * size.height * 4 <= CGFloat(48 << 20) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = normalized.jpegData(compressionQuality: 0.88), let result = normalized.cgImage else { return nil }
        return .init(key: key, bytes: data, pixelWidth: result.width, pixelHeight: result.height,
                     content: .photograph, nativeResolution: nativeResolution)
    }

    func checkpoint(snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient) {
        if completedViewport == snapshot { return }
        if pendingViewport?.snapshot == snapshot, checkpointTask != nil { return }
        pendingViewport = (snapshot, assets, client)
        scheduleCheckpoint(snapshot: snapshot, assets: assets, client: client)
    }

    /// Real image delivery can complete after the viewport has become stationary.
    func imageArrived() {
        guard let pending = pendingViewport, completedViewport != pending.snapshot else { return }
        scheduleCheckpoint(snapshot: pending.snapshot, assets: pending.assets, client: pending.client)
    }

    func noteViewport(snapshot: LaunchViewportSnapshot, client: ImoraClient) {
        let store = store
        anchorTask?.cancel()
        anchorTask = Task {
            guard !Task.isCancelled, client.context.isActive, snapshot.scope == client.mediaDisplayScope,
                  UIApplication.shared.isProtectedDataAvailable else { return }
            try? await store.noteViewport(snapshot)
        }
    }

    private func scheduleCheckpoint(snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient) {
        checkpointTask?.cancel()
        let id = UUID(), access = Self.access(for: client), store = store
        viewportID = id
        checkpointTask = Task { [weak self] in
            // Persist the latest anchor independently before waiting for a complete generation.
            guard client.context.isActive, UIApplication.shared.isProtectedDataAvailable else { return }
            try? await store.noteViewport(snapshot)
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.viewportID == id, client.context.isActive, Self.access(for: client) == access else { return }
            var records: [PreparedImageRecord] = []
            for (asset, key) in zip(assets, snapshot.visibleKeys) {
                try? Task.checkCancellation()
                guard !Task.isCancelled, Self.access(for: client) == access else { return }
                let image: UIImage?
                if let local = asset.localIdentifier {
                    image = LocalImageLoader.shared.cachedImage(localIdentifier: local, targetPixelSize: CGFloat(key.pixelBucket),
                        contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                        cacheScope: Self.localScope(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)))
                } else {
                    image = ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                        targetPixelSize: CGFloat(key.pixelBucket))
                }
                let native: NativeImageResolution?
                if let local = asset.localIdentifier {
                    native = await LocalImageLoader.shared.nativeResolution(localIdentifier: local, sourceRevision: key.sourceRevision)
                } else { native = nil }
                if let image, let record = await Self.encode(image: image, key: key, nativeResolution: native) { records.append(record) }
            }
            guard !Task.isCancelled, self.viewportID == id, client.context.isActive,
                  Self.access(for: client) == access, client.mediaDisplayScope == snapshot.scope else { return }
            do {
                let receipt = try await store.checkpoint(snapshot: snapshot, images: records)
                guard self.viewportID == id else { return }
                self.completedViewport = snapshot
                self.checkpointTask = nil
                self.log.info("checkpoint complete bytes=\(receipt.byteCount)")
            } catch {
                if self.viewportID == id { self.checkpointTask = nil }
                self.log.info("checkpoint incomplete: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func cancelCheckpoint() {
        checkpointTask?.cancel(); checkpointTask = nil; viewportID = nil; pendingViewport = nil
        completedViewport = nil
        anchorTask?.cancel(); anchorTask = nil
    }

    func invalidate(client: ImoraClient) {
        cancelCheckpoint()
        completedViewport = nil
        let scope = client.mediaDisplayScope, store = store
        Task { try? await store.invalidate(scope: scope) }
    }
}
