import Foundation
import ImageIO
import Photos
import UIKit
import os

@MainActor
struct CommittedGridSurface {
    let image: UIImage
    let key: MediaDisplayKeyV1
    let access: MediaAccessGeneration
    let localProvenance: LocalSurfaceProvenance?
    let isCurrent: @MainActor @Sendable () -> Bool
}

typealias GridSurfaceProvider = @MainActor @Sendable (MediaDisplayKeyV1) -> CommittedGridSurface?
typealias LocalSurfaceValidator = @Sendable (LocalSurfaceProvenance) async -> Bool
typealias RemoteLaunchSurfaceValidator = @Sendable (Asset) async -> Bool

nonisolated struct PreparedViewport: Sendable {
    let snapshot: LaunchViewportSnapshot
    let assets: [Asset]
    let access: MediaAccessGeneration
    let images: [MediaDisplayKeyV1: UIImage]
    let missingKeys: [MediaDisplayKeyV1]
    let checkpointMiss: Bool
    var localEvidenceIsCurrent: @Sendable () -> Bool = { true }
    var localProvenanceByKey: [MediaDisplayKeyV1: LocalSurfaceProvenance] = [:]
}

nonisolated struct ViewportRequest: Sendable {
    let snapshot: LaunchViewportSnapshot
    let assets: [Asset]
    let records: [PreparedImageRecord]
    let client: ImoraClient
    let access: MediaAccessGeneration
    let checkpointMiss: Bool
    var isCurrent: (@MainActor @Sendable () -> Bool)? = nil
    var validateLocalSurface: LocalSurfaceValidator = { $0.remoteIdentifier == nil }
    var localEvidenceIsCurrent: @Sendable () -> Bool = { true }
    var validateRemoteSurface: RemoteLaunchSurfaceValidator = { _ in true }
}

/// A bounded preparation/commit boundary over the existing Nuke and PhotoKit caches.
/// It owns no downloader, second bitmap cache, source files, drafts or backup evidence.
@MainActor
final class MediaPresentationCoordinator {
    static let shared = MediaPresentationCoordinator()
    private nonisolated let store: LaunchPreviewStore
    private nonisolated let prepareImage: @Sendable (Asset, MediaDisplayKeyV1, PreparedImageRecord?, ImoraClient) async -> (MediaDisplayKeyV1, UIImage)?
    private var checkpointTask: Task<Void, Never>?
    private var viewportID: UUID?
    private var pendingViewport: (snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient,
        surfaceProvider: GridSurfaceProvider?, validateLocalSurface: LocalSurfaceValidator)?
    private var startupObservation: (snapshot: LaunchViewportSnapshot, session: UUID, missing: Set<MediaDisplayKeyV1>)?
    private var completedViewport: LaunchViewportSnapshot?
    private var anchorTask: Task<Void, Never>?
    private nonisolated let log = Logger(subsystem: "com.vexcited.imora", category: "LaunchPreview")

    init(store: LaunchPreviewStore = .shared,
         prepareImage: @escaping @Sendable (Asset, MediaDisplayKeyV1, PreparedImageRecord?, ImoraClient) async -> (MediaDisplayKeyV1, UIImage)? = MediaPresentationCoordinator.prepare) {
        self.store = store; self.prepareImage = prepareImage
    }

    nonisolated static func access(for client: ImoraClient) -> MediaAccessGeneration {
        .init(session: client.context.id, permission: LocalImageLoader.shared.permissionGeneration)
    }

    nonisolated static func gridKey(asset: Asset, client: ImoraClient, pixels: CGFloat) -> MediaDisplayKeyV1 {
        try? MediaContentGenerations.shared.ensureInitialized()
        let subject: MediaDisplayKeyV1.Subject
        if let local = asset.localIdentifier {
            subject = .localAsset(installationID: DeviceID.current, localIdentifier: local)
        } else { subject = .remoteAsset(asset.id) }
        return .init(scope: client.mediaDisplayScope, subject: subject,
            sourceRevision: asset.localIdentifier == nil ? (asset.thumbhash ?? "") : (asset.localImageVersion ?? ""),
            presentationRevision: "committed:\(asset.localIdentifier == nil ? (asset.thumbhash ?? "") : (asset.localImageVersion ?? ""))",
            variant: .grid, pixelBucket: max(1, Int(pixels.rounded(.up))), fitMode: "fit-cover",
            orientationRevision: "source", colorProfile: "source", visibilityPolicy: asset.visibility.rawValue)
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

    @concurrent
    nonisolated func restore(client: ImoraClient, filter: String, layout: LaunchViewportSnapshot.Layout?,
                 protectedDataAvailable: Bool? = nil,
                 isCurrent: (@MainActor @Sendable () -> Bool)? = nil,
                 validateLocalSurface: @escaping LocalSurfaceValidator = { $0.remoteIdentifier == nil },
                 localEvidenceIsCurrent: @escaping @Sendable () -> Bool = { true },
                 validateRemoteSurface: @escaping RemoteLaunchSurfaceValidator = { _ in true }) async throws -> PreparedViewport? {
        let started = ContinuousClock.now
        let access = Self.access(for: client)
        let available: Bool
        if let protectedDataAvailable { available = protectedDataAvailable }
        else { available = await MainActor.run { UIApplication.shared.isProtectedDataAvailable } }
        let context = LaunchContext(access: access, protectedDataAvailable: available,
                                    filter: filter, layout: layout)
        let read = try await store.restore(scope: client.mediaDisplayScope, context: context)
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.mark("local-pack-read-complete")
        #endif
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
            snapshot.bucketLeadingAssetCounts = old.bucketLeadingAssetCounts
            }
        }
        let prepared = try await prepareViewport(request: .init(snapshot: snapshot, assets: assets, records: records,
            client: client, access: access, checkpointMiss: miss, isCurrent: isCurrent, validateLocalSurface: validateLocalSurface, localEvidenceIsCurrent: localEvidenceIsCurrent, validateRemoteSurface: validateRemoteSurface))
        log.info("restore prepared \(prepared.images.count)/\(assets.count), checkpointMiss=\(miss), elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public)")
        return prepared
    }

    @concurrent
    nonisolated func prepareViewport(request: ViewportRequest) async throws -> PreparedViewport {
        #if DEBUG || PHASE4_PERFORMANCE
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        defer { LaunchPipelineTrace.record("viewport-prepare-two-workers", since: preparationStarted, items: request.assets.count) }
        #endif
        let client = request.client
        if let current = request.isCurrent, !(await current()) { throw CancellationError() }
        guard client.context.isActive, Self.access(for: client) == request.access,
              request.localEvidenceIsCurrent(),
              request.snapshot.visibleKeys.allSatisfy(\.isCurrentContent) else { throw CancellationError() }
        let pairs = Array(zip(request.assets, request.snapshot.visibleKeys))
        let prepareImage = prepareImage
        var rejected = Set<MediaDisplayKeyV1>()
        #if DEBUG || PHASE4_PERFORMANCE
        let proofStarted = ProcessInfo.processInfo.systemUptime
        #endif
        for (asset, key) in pairs where asset.localIdentifier == nil
            && request.records.first(where: { $0.key == key })?.localProvenance == nil {
            if !(await request.validateRemoteSurface(asset)) { rejected.insert(key) }
        }
        for record in request.records {
            if let provenance = record.localProvenance,
               !(await request.validateLocalSurface(provenance)) { rejected.insert(record.key) }
        }
        let rejectedKeys = rejected
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.record("local-proof-before-decode", since: proofStarted, items: request.records.count)
        #endif
        // At most two reads/decodes at once; no full-library fetch enters this path.
        var images = await withTaskGroup(of: (MediaDisplayKeyV1, UIImage)?.self) { group in
            var iterator = pairs.makeIterator()
            func addNext() {
                guard let (asset, key) = iterator.next() else { return }
                let record = request.records.first { $0.key == key }
                group.addTask {
                    guard !rejectedKeys.contains(key) else { return nil }
                    return await prepareImage(asset, key, record, client)
                }
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
        #if DEBUG || PHASE4_PERFORMANCE
        let finalProofStarted = ProcessInfo.processInfo.systemUptime
        #endif
        for record in request.records where images[record.key] != nil {
            if let provenance = record.localProvenance,
               !(await request.validateLocalSurface(provenance)) { images[record.key] = nil }
        }
        if let current = request.isCurrent, !(await current()) { throw CancellationError() }
        guard client.context.isActive, Self.access(for: client) == request.access,
              client.mediaDisplayScope == request.snapshot.scope,
              request.localEvidenceIsCurrent(),
              request.snapshot.visibleKeys.allSatisfy(\.isCurrentContent) else { throw CancellationError() }
        #if DEBUG || PHASE4_PERFORMANCE
        LaunchPipelineTrace.record("local-proof-after-decode", since: finalProofStarted, items: request.records.count)
        #endif
        // Existing cache bindings publish before the MainActor adopts metadata.
        #if DEBUG || PHASE4_PERFORMANCE
        let bindingStarted = ProcessInfo.processInfo.systemUptime
        defer { LaunchPipelineTrace.record("prepared-cache-binding", since: bindingStarted, items: images.count) }
        #endif
        for (asset, key) in pairs {
            guard !Task.isCancelled, request.localEvidenceIsCurrent() else { throw CancellationError() }
            guard let image = images[key] else { continue }
            if let local = asset.localIdentifier {
                LocalImageLoader.shared.installPrepared(image, localIdentifier: local, targetPixelSize: CGFloat(key.pixelBucket),
                    cacheScope: Self.localScope(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)), permission: request.access.permission,
                    sourceRevision: key.sourceRevision.isEmpty ? nil : key.sourceRevision)
            } else {
                ImageLoader.shared.installPrepared(image, url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                    targetPixelSize: CGFloat(key.pixelBucket), client: client,
                    localProvenance: request.records.first { $0.key == key }?.localProvenance)
            }
        }
        return .init(snapshot: request.snapshot, assets: request.assets, access: request.access, images: images,
            missingKeys: request.snapshot.visibleKeys.filter { images[$0] == nil }, checkpointMiss: request.checkpointMiss,
            localEvidenceIsCurrent: request.localEvidenceIsCurrent,
            localProvenanceByKey: Dictionary(uniqueKeysWithValues: request.records.compactMap { record in
                record.localProvenance.map { (record.key, $0) }
            }))
    }

    @concurrent
    private nonisolated static func prepare(asset: Asset, key: MediaDisplayKeyV1, record: PreparedImageRecord?, client: ImoraClient) async -> (MediaDisplayKeyV1, UIImage)? {
        guard !Task.isCancelled, client.context.isActive, key.isCurrentContent else { return nil }
        if let provenance = record?.localProvenance,
           LocalImageLoader.currentModificationRevision(provenance.localIdentifier) != provenance.modificationRevision { return nil }
        if let local = asset.localIdentifier, !(await LocalImageLoader.shared.canReadPrepared(local)) { return nil }
        var native: NativeImageResolution?
        if let local = asset.localIdentifier {
            native = await LocalImageLoader.shared.nativeResolution(localIdentifier: local, sourceRevision: key.sourceRevision)
            if !key.sourceRevision.isEmpty && native == nil { return nil }
        }
        var image: UIImage?
        if let record, record.isQualified, record.nativeResolution == nil || record.nativeResolution == native {
            #if DEBUG || PHASE4_PERFORMANCE
            let decodeStarted = ProcessInfo.processInfo.systemUptime
            defer { LaunchPipelineTrace.record("imageio-bitmap-decode", since: decodeStarted) }
            #endif
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
                if image == nil || min(image!.size.width, image!.size.height) * image!.scale < CGFloat(key.pixelBucket) {
                    let ratio = max(0.01, asset.ratio)
                    image = await ImageLoader.shared.diskImage(for: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash),
                        targetPixelSize: CGFloat(key.pixelBucket) * max(ratio, 1 / ratio))
                }
            }
        }
        #if DEBUG || PHASE4_PERFORMANCE
        let displayStarted = ProcessInfo.processInfo.systemUptime
        defer { LaunchPipelineTrace.record("uikit-prepare-for-display", since: displayStarted) }
        #endif
        guard let image,
              min(image.size.width, image.size.height) * image.scale >= CGFloat(key.pixelBucket)
                || native?.accepts(width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), key: key) == true,
              let prepared = await image.byPreparingForDisplay(), !Task.isCancelled,
              client.context.isActive, key.isCurrentContent else { return nil }
        if let provenance = record?.localProvenance,
           LocalImageLoader.currentModificationRevision(provenance.localIdentifier) != provenance.modificationRevision { return nil }
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

    func checkpoint(snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient,
                    surfaceProvider: GridSurfaceProvider? = nil,
                    validateLocalSurface: @escaping LocalSurfaceValidator = { $0.remoteIdentifier == nil }) {
        ImageLoader.shared.noteVisibleViewport(snapshot.visibleKeys, client: client)
        observeStartupViewport(snapshot: snapshot, client: client, surfaceProvider: surfaceProvider)
        if completedViewport == snapshot { return }
        if pendingViewport?.snapshot == snapshot, checkpointTask != nil { return }
        pendingViewport = (snapshot, assets, client, surfaceProvider, validateLocalSurface)
        scheduleCheckpoint(snapshot: snapshot, assets: assets, client: client,
            surfaceProvider: surfaceProvider, validateLocalSurface: validateLocalSurface)
    }

    /// Real image delivery can complete after the viewport has become stationary.
    func imageArrived(_ key: MediaDisplayKeyV1) {
        guard let pending = pendingViewport else { return }
        if var observation = startupObservation, observation.snapshot == pending.snapshot,
           observation.session == pending.client.context.id, observation.missing.contains(key),
           qualifiedSurface(key, provider: pending.surfaceProvider) {
            observation.missing.remove(key); startupObservation = observation
            if observation.missing.isEmpty {
                releaseSweepIfVisible(snapshot: pending.snapshot, client: pending.client, surfaceProvider: pending.surfaceProvider)
            }
        }
        guard completedViewport != pending.snapshot else { return }
        scheduleCheckpoint(snapshot: pending.snapshot, assets: pending.assets, client: pending.client,
            surfaceProvider: pending.surfaceProvider, validateLocalSurface: pending.validateLocalSurface)
    }

    private func qualifiedSurface(_ key: MediaDisplayKeyV1, provider: GridSurfaceProvider?) -> Bool {
        guard let surface = provider?(key), surface.key == key, surface.isCurrent() else { return false }
        return surface.image.cgImage != nil
    }

    private func observeStartupViewport(snapshot: LaunchViewportSnapshot, client: ImoraClient,
                                        surfaceProvider: GridSurfaceProvider?) {
        guard ImageLoader.shared.isFirstViewportPending(client: client), surfaceProvider != nil,
              !snapshot.visibleKeys.isEmpty else { return }
        if startupObservation?.snapshot != snapshot || startupObservation?.session != client.context.id {
            let missing = Set(snapshot.visibleKeys.filter { !qualifiedSurface($0, provider: surfaceProvider) })
            startupObservation = (snapshot, client.context.id, missing)
        }
        if startupObservation?.missing.isEmpty == true {
            releaseSweepIfVisible(snapshot: snapshot, client: client, surfaceProvider: surfaceProvider)
        }
    }

    private func releaseSweepIfVisible(snapshot: LaunchViewportSnapshot, client: ImoraClient,
                                       surfaceProvider: GridSurfaceProvider?) {
        guard let surfaceProvider, !snapshot.visibleKeys.isEmpty,
              snapshot.visibleKeys.allSatisfy({ qualifiedSurface($0, provider: surfaceProvider) }) else { return }
        ImageLoader.shared.firstViewportPresented(client: client)
    }

    func noteViewport(snapshot: LaunchViewportSnapshot, client: ImoraClient) {
        ImageLoader.shared.noteVisibleViewport(snapshot.visibleKeys, client: client)
        let store = store
        anchorTask?.cancel()
        anchorTask = Task {
            guard !Task.isCancelled, client.context.isActive, snapshot.scope == client.mediaDisplayScope,
                  UIApplication.shared.isProtectedDataAvailable else { return }
            try? await store.noteViewport(snapshot)
        }
    }

    private func scheduleCheckpoint(snapshot: LaunchViewportSnapshot, assets: [Asset], client: ImoraClient,
                                    surfaceProvider: GridSurfaceProvider?, validateLocalSurface: @escaping LocalSurfaceValidator) {
        checkpointTask?.cancel()
        let id = UUID(), access = Self.access(for: client), store = store
        viewportID = id
        checkpointTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.viewportID == id {
                    self.checkpointTask = nil
                    // A library/permission change cancels captured authority,
                    // but must not leave a finished handle suppressing retry.
                    if client.context.isActive, Self.access(for: client) != access {
                        self.scheduleCheckpoint(snapshot: snapshot, assets: assets, client: client,
                            surfaceProvider: surfaceProvider, validateLocalSurface: validateLocalSurface)
                    }
                }
            }
            // Persist the latest anchor independently before waiting for a complete generation.
            guard client.context.isActive, UIApplication.shared.isProtectedDataAvailable else { return }
            try? await store.noteViewport(snapshot)
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard self.viewportID == id, client.context.isActive, Self.access(for: client) == access else { return }
            var records: [PreparedImageRecord] = []
            var acceptedSurfaces: [CommittedGridSurface] = []
            #if DEBUG || PHASE4_PERFORMANCE
            var foundMemory = 0, foundDisk = 0, foundLocal = 0, missing = 0, rejectedEncode = 0
            #endif
            for (asset, key) in zip(assets, snapshot.visibleKeys) {
                try? Task.checkCancellation()
                guard !Task.isCancelled, Self.access(for: client) == access else { return }
                var image: UIImage?
                let surface = surfaceProvider?(key)
                var provenance: LocalSurfaceProvenance?
                if let surface, surface.key == key, surface.access == access, surface.isCurrent() {
                    if let local = surface.localProvenance {
                        if await validateLocalSurface(local), surface.isCurrent() {
                            image = surface.image; provenance = local; acceptedSurfaces.append(surface)
                        }
                    } else { image = surface.image; acceptedSurfaces.append(surface) }
                }
                // An actual grid selection is authoritative about which
                // representation is displayed. A missing/revoked selected
                // surface must not be replaced by another rendition.
                if surfaceProvider != nil, image == nil {
                    #if DEBUG || PHASE4_PERFORMANCE
                    missing += 1
                    #endif
                    continue
                }
                if image == nil, let local = asset.localIdentifier {
                    image = LocalImageLoader.shared.cachedImage(localIdentifier: local, targetPixelSize: CGFloat(key.pixelBucket),
                        contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                        cacheScope: Self.localScope(asset: asset, client: client, pixels: CGFloat(key.pixelBucket)))
                } else if image == nil {
                    let cached = ImageLoader.shared.cachedGridSurface(thumbnailURL: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
                        previewURL: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash),
                        targetPixelSize: CGFloat(key.pixelBucket), aspectRatio: asset.ratio)
                    if let local = cached?.localProvenance {
                        if await validateLocalSurface(local) { image = cached?.image; provenance = local }
                    } else { image = cached?.image }
                }
                #if DEBUG || PHASE4_PERFORMANCE
                if image != nil { foundMemory += 1 }
                #endif
                if image == nil {
                    // Mounted tiles can still own their displayed bitmap after
                    // the bounded decoded cache evicts it. Reuse only W0's
                    // existing disk derivatives/accessible local resources;
                    // preparation has no network path and runs one lane here.
                    image = await Self.prepare(asset: asset, key: key, record: nil, client: client)?.1
                    #if DEBUG || PHASE4_PERFORMANCE
                    if image != nil {
                        if asset.localIdentifier == nil { foundDisk += 1 } else { foundLocal += 1 }
                    }
                    #endif
                }
                let native: NativeImageResolution?
                if let local = asset.localIdentifier {
                    native = await LocalImageLoader.shared.nativeResolution(localIdentifier: local, sourceRevision: key.sourceRevision)
                } else { native = nil }
                if let image {
                    if var record = await Self.encode(image: image, key: key, nativeResolution: native) {
                        record.localProvenance = provenance
                        records.append(record)
                    }
                    else {
                        #if DEBUG || PHASE4_PERFORMANCE
                        rejectedEncode += 1
                        #endif
                    }
                } else {
                    #if DEBUG || PHASE4_PERFORMANCE
                    missing += 1
                    #endif
                }
            }
            for surface in acceptedSurfaces {
                guard surface.isCurrent() else { return }
                if let provenance = surface.localProvenance, !(await validateLocalSurface(provenance)) { return }
            }
            for record in records {
                if let provenance = record.localProvenance {
                    guard await validateLocalSurface(provenance),
                          LocalImageLoader.currentModificationRevision(provenance.localIdentifier) == provenance.modificationRevision else { return }
                }
            }
            guard !Task.isCancelled, self.viewportID == id, client.context.isActive,
                  Self.access(for: client) == access, client.mediaDisplayScope == snapshot.scope,
                  acceptedSurfaces.allSatisfy({ $0.isCurrent() }) else { return }
            #if DEBUG || PHASE4_PERFORMANCE
            if LaunchPresentationTrace.enabled {
                let boundLocal = acceptedSurfaces.filter { $0.localProvenance != nil }.count
                self.log.info("checkpoint qualification requested=\(assets.count) bound=\(acceptedSurfaces.count) boundLocal=\(boundLocal) memory=\(foundMemory) disk=\(foundDisk) local=\(foundLocal) missing=\(missing) rejectedEncode=\(rejectedEncode) qualified=\(records.count)")
            }
            #endif
            do {
                let receipt = try await store.checkpoint(snapshot: snapshot, images: records)
                guard self.viewportID == id else { return }
                self.completedViewport = snapshot
                #if DEBUG || PHASE4_PERFORMANCE
                if LaunchPresentationTrace.enabled { LaunchPresentationTrace.didCheckpoint(snapshot) }
                #endif
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
        startupObservation = nil
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
