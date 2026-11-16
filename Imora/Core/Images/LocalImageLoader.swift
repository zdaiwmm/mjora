import AVFoundation
import Photos
import UIKit
import os

/// one step of a progressive photokit load: the library's own stored
/// thumbnail while the sharp render is still being decoded, then the render.
nonisolated enum LocalImageDelivery: @unchecked Sendable {
    case preview(UIImage)
    case final(UIImage)
    case terminal(LocalImageResult)
}

nonisolated struct BoundLocalImage: @unchecked Sendable {
    let image: UIImage
    let localIdentifier: String
    let modificationRevision: String
    let permission: Int
    let cacheScope: String
    let targetPixelSize: CGFloat
    let contentMode: PHImageContentMode
    let coversTarget: Bool
    fileprivate let validate: @Sendable () -> Bool
    var isCurrent: Bool { validate() }
}

/// how grids ask photokit for device tiles: uncropped, at the tile's own
/// size, with the target covering the tile's short side. the tile, the
/// opening transition and the page's first frame then all paint the same
/// bitmap, so nothing zooms out once the full render lands. the square tile
/// crops it visually. the caching manager stores decoded sources and only
/// crops at delivery, so this costs no more than asking for the crop.
nonisolated enum DeviceTileRender {
    static let contentMode: PHImageContentMode = .aspectFit
    static let coversTile = true
}

/// photokit loading for device assets merged into the timeline. the heavy
/// lifting - decoding, downscaling and keeping a window of tiles warm - is
/// photokit's own caching manager, the local twin of the nuke pipeline behind
/// remote thumbnails.
/// unchecked because nscache is documented thread-safe.
nonisolated final class LocalImageLoader: @unchecked Sendable {
    static let shared = LocalImageLoader()

    /// caching manager rather than the default one: it prefetches and holds
    /// decoded thumbnails for the identifiers the grid asks it to keep warm.
    private let manager: PHCachingImageManager
    // Reserve two of the shared four slots for a server fallback while
    // local providers are slow or only send degraded callbacks.
    private static let localSlots = ThumbnailLoadLimiter(limit: 2)
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private struct Consumer {
        let continuation: AsyncStream<LocalImageDelivery>.Continuation
        var globalDemand: UUID?
        var localDemand: UUID?
    }
    private struct SharedWork {
        let id: UUID
        var consumers: [UUID: Consumer]
        var producer: Task<Void, Never>?
        var latest: LocalImageDelivery?
    }
    private let sharedWork = OSAllocatedUnfairLock(initialState: [String: SharedWork]())
    /// decoded results still get a small cache of their own so a tile
    /// scrolling back into view renders on its first frame, synchronously -
    /// photokit only ever answers through a callback.
    private final class CachedImage {
        let image: UIImage
        let modificationRevision: String?
        init(_ image: UIImage, modificationRevision: String?) {
            self.image = image; self.modificationRevision = modificationRevision
        }
    }
    private let cache: NSCache<NSString, CachedImage>
    private let cachedSizes = OSAllocatedUnfairLock(initialState: [String: CGFloat]())
    /// photokit's stored previews, one per asset whatever size was asked. the
    /// opening transition needs an uncropped picture for a tile that only has
    /// its preview yet - a snapshot of the square tile is a crop the viewer
    /// visibly zooms out of once the render lands.
    private let previews: NSCache<NSString, UIImage>
    private let assets: NSCache<NSString, PHAsset>
    private let libraryGeneration = OSAllocatedUnfairLock(initialState: 0)
    var permissionGeneration: Int {
        libraryGeneration.withLock { $0 } * 10 + PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
    }

    nonisolated static func currentModificationRevision(_ localIdentifier: String) -> String? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              !asset.isHidden, let modified = asset.modificationDate else { return nil }
        return String(modified.timeIntervalSinceReferenceDate.bitPattern)
    }

    @concurrent
    func canReadPrepared(_ localIdentifier: String) async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return false }
        return !asset.isHidden
    }

    /// Only exact current PhotoKit metadata may justify a small final source.
    /// Cached image dimensions, filenames and backup pairing are not evidence.
    @concurrent
    func nativeResolution(localIdentifier: String, sourceRevision: String) async -> NativeImageResolution? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited, !sourceRevision.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              !asset.isHidden,
              let modified = asset.modificationDate,
              String(modified.timeIntervalSinceReferenceDate.bitPattern) == sourceRevision,
              asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
        return .init(sourceRevision: sourceRevision, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
    }

    func installPrepared(_ image: UIImage, localIdentifier: String, targetPixelSize: CGFloat,
                         cacheScope: String, permission: Int, sourceRevision: String? = nil) {
        guard permission == permissionGeneration else { return }
        let revision = sourceRevision.flatMap {
            Self.currentModificationRevision(localIdentifier) == $0 ? $0 : nil
        }
        store(image, localIdentifier: localIdentifier, targetPixelSize: targetPixelSize,
              contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: cacheScope,
              modificationRevision: revision)
        storePreview(image, localIdentifier: localIdentifier, cacheScope: cacheScope)
    }
    /// exported live photo motion files in least-recently-used order.
    private let motionFiles = OSAllocatedUnfairLock<[URL]>(initialState: [])
    /// a window can hold dozens of identifiers and every miss is a synchronous
    /// library query, so the bookkeeping stays off the caller's thread. serial
    /// keeps a stop from overtaking the start it cancels.
    private let cachingQueue = DispatchQueue(label: "app.imora.local-image-caching", qos: .userInitiated)

    fileprivate static func releaseLocalPermit(_ permit: UUID) async {
        await localSlots.release(permit)
    }

    private init(manager: PHCachingImageManager = PHCachingImageManager()) {
        self.manager = manager
        cache = NSCache()
        cache.totalCostLimit = 48 << 20
        previews = NSCache()
        previews.totalCostLimit = 12 << 20
        assets = NSCache()
        assets.countLimit = 512
    }

    #if DEBUG
    static func fixture(manager: PHCachingImageManager) -> LocalImageLoader { LocalImageLoader(manager: manager) }
    #endif

    /// asset lookups are cached; a library change invalidates them all.
    func noteLibraryChange() {
        libraryGeneration.withLock { $0 &+= 1 }
        Task { @MainActor in ImageLoadRecovery.shared.contentChanged() }
        cachingQueue.async { [self] in
            prefetchTasks.values.forEach { $0.cancel() }
            prefetchTasks.removeAll()
        }
        assets.removeAllObjects()
        cache.removeAllObjects()
        cachedSizes.withLock { $0.removeAll() }
        previews.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }

    private func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        let key = localIdentifier as NSString
        if let cached = assets.object(forKey: key) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        assets.setObject(asset, forKey: key)
        return asset
    }

    /// one library query for every identifier not already cached, instead of
    /// one per tile: a prefetch window moves dozens of identifiers at a time
    /// and each query is a round trip to the photos database.
    private func fetchAssets(_ localIdentifiers: [String]) -> [PHAsset] {
        var found: [PHAsset] = []
        var missing: [String] = []
        found.reserveCapacity(localIdentifiers.count)
        for localIdentifier in localIdentifiers {
            if let cached = assets.object(forKey: localIdentifier as NSString) {
                found.append(cached)
            } else {
                missing.append(localIdentifier)
            }
        }
        guard !missing.isEmpty else { return found }
        PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
            self.assets.setObject(asset, forKey: asset.localIdentifier as NSString)
            found.append(asset)
        }
        return found
    }

    private func key(
        _ localIdentifier: String,
        _ size: CGFloat,
        _ contentMode: PHImageContentMode,
        coversTarget: Bool,
        cacheScope: String = ""
    ) -> NSString {
        "\(permissionGeneration)|\(cacheScope)|\(localIdentifier)#\(Int(size))#\(contentMode.rawValue)\(coversTarget ? "#cover" : "")" as NSString
    }

    /// the photokit target for a request. a covering fit puts the tile's
    /// size on the short side, so the uncropped render still fills a square
    /// tile edge to edge instead of arriving a third smaller than the crop
    /// would have. the strip beyond the square is all it costs over a crop.
    private static func targetSize(
        for asset: PHAsset,
        pixels: CGFloat,
        contentMode: PHImageContentMode,
        coversTarget: Bool
    ) -> CGSize {
        guard coversTarget, contentMode == .aspectFit,
              asset.pixelWidth > 0, asset.pixelHeight > 0
        else { return CGSize(width: pixels, height: pixels) }
        let ratio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        return ratio >= 1
            ? CGSize(width: (pixels * ratio).rounded(.up), height: pixels)
            : CGSize(width: pixels, height: (pixels / ratio).rounded(.up))
    }

    /// the caching manager only serves a prefetched thumbnail when the request
    /// that follows carries the same options, so every path shares these.
    /// opportunistic delivery hands back the library's stored thumbnail at
    /// once whenever the render at the asked size still has to be decoded,
    /// which is what keeps a fling painted instead of grey.
    private static func requestOptions(allowsNetwork: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowsNetwork
        return options
    }

    private static func isDegraded(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
    }

    private static func isCancelled(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageCancelledKey] as? Bool) ?? false
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    private func store(
        _ image: UIImage,
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode,
        coversTarget: Bool,
        cacheScope: String = "",
        modificationRevision: String? = nil
    ) {
        let cacheKey = key(localIdentifier, targetPixelSize, contentMode, coversTarget: coversTarget, cacheScope: cacheScope)
        let cacheKeyString = cacheKey as String
        cachedSizes.withLock { sizes in
            if sizes.count >= 4096, let oldest = sizes.keys.first { sizes[oldest] = nil }
            sizes[cacheKeyString] = targetPixelSize
        }
        cache.setObject(
            CachedImage(image, modificationRevision: modificationRevision),
            forKey: cacheKey,
            cost: Self.cost(of: image)
        )
    }

    func releaseOffscreenImagesForMemoryPressure() {
        cachingQueue.async { [self] in
            prefetchTasks.values.forEach { $0.cancel() }
            prefetchTasks.removeAll()
        }
        let oversized = cachedSizes.withLock { sizes -> [String] in
            let keys = sizes.compactMap { $0.value > 1280 ? $0.key : nil }
            keys.forEach { sizes[$0] = nil }
            return keys
        }
        for key in oversized { cache.removeObject(forKey: key as NSString) }
        previews.removeAllObjects()
    }

    private func storePreview(_ image: UIImage, localIdentifier: String, cacheScope: String = "") {
        previews.setObject(image, forKey: "\(permissionGeneration)|\(cacheScope)|\(localIdentifier)" as NSString, cost: Self.cost(of: image))
    }

    func cachedImage(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        coversTarget: Bool = false,
        cacheScope: String = ""
    ) -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return cache.object(forKey: key(localIdentifier, targetPixelSize, contentMode, coversTarget: coversTarget, cacheScope: cacheScope))?.image
    }

    func cachedBoundImage(localIdentifier: String, targetPixelSize: CGFloat, contentMode: PHImageContentMode,
                          coversTarget: Bool, cacheScope: String) -> BoundLocalImage? {
        let permission = permissionGeneration
        guard let entry = cache.object(forKey: key(localIdentifier, targetPixelSize, contentMode, coversTarget: coversTarget, cacheScope: cacheScope)),
              let revision = entry.modificationRevision,
              Self.currentModificationRevision(localIdentifier) == revision, permissionGeneration == permission else { return nil }
        return BoundLocalImage(image: entry.image, localIdentifier: localIdentifier, modificationRevision: revision,
            permission: permission, cacheScope: cacheScope, targetPixelSize: targetPixelSize,
            contentMode: contentMode, coversTarget: coversTarget, validate: { [weak self] in
                guard let self, self.permissionGeneration == permission else { return false }
                return Self.currentModificationRevision(localIdentifier) == revision
            })
    }

    /// the last preview photokit handed over for the asset, at whatever size.
    func cachedPreview(localIdentifier: String, cacheScope: String = "") -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return previews.object(forKey: "\(permissionGeneration)|\(cacheScope)|\(localIdentifier)" as NSString)
    }

    /// the sharp render alone, for callers that want exactly one image.
    /// concurrent so the photokit fetch never runs inline on the caller. under
    /// approachable concurrency a plain nonisolated async body stays on the
    /// caller's actor, which put a synchronous library query on the main
    /// thread every time a page or tile asked for its image.
    @concurrent
    func image(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        coversTarget: Bool = false,
        allowsNetwork: Bool = true,
        cacheScope: String = "",
        priority: ThumbnailDemandPriority = .visible
    ) async -> UIImage? {
        for await delivery in deliveries(
            localIdentifier: localIdentifier,
            targetPixelSize: targetPixelSize,
            contentMode: contentMode,
            coversTarget: coversTarget,
            allowsNetwork: allowsNetwork,
            cacheScope: cacheScope,
            priority: priority
        ) {
            guard !Task.isCancelled else { return nil }
            if case .final(let image) = delivery { return image }
        }
        return nil
    }

    /// progressive load for tiles: photokit's stored thumbnail lands first
    /// when the render at `targetPixelSize` still has to be decoded, so a tile
    /// paints on arrival and sharpens a moment later. only the sharp render is
    /// cached. a stream that ends without one means photokit could not produce
    /// it - the asset is gone, or sits in icloud with network access off.
    func deliveries(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        coversTarget: Bool = false,
        allowsNetwork: Bool = true,
        cacheScope: String = "",
        priority: ThumbnailDemandPriority = .visible
    ) -> AsyncStream<LocalImageDelivery> {
        if let cached = cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: targetPixelSize,
            contentMode: contentMode,
            coversTarget: coversTarget,
            cacheScope: cacheScope
        ) {
            return AsyncStream { continuation in
                continuation.yield(.final(cached))
                continuation.finish()
            }
        }
        let workKey = "local|\(key(localIdentifier, targetPixelSize, contentMode, coversTarget: coversTarget, cacheScope: cacheScope))|\(Double(targetPixelSize).bitPattern)|network:\(allowsNetwork)"
        let consumerID = UUID()
        return AsyncStream { continuation in
            let registration = sharedWork.withLock { works -> (UUID, Bool, LocalImageDelivery?) in
                if var work = works[workKey] {
                    work.consumers[consumerID] = Consumer(continuation: continuation)
                    works[workKey] = work
                    return (work.id, false, work.latest)
                }
                let id = UUID()
                works[workKey] = SharedWork(id: id, consumers: [consumerID: Consumer(continuation: continuation)])
                return (id, true, nil)
            }
            continuation.onTermination = { [weak self] _ in self?.removeConsumer(consumerID, key: workKey, workID: registration.0) }
            if let latest = registration.2 { continuation.yield(latest) }
            let demand = Task { [self] in
                let global = await ThumbnailDemandScheduler.shared.addDemand(key: workKey, priority: priority)
                let local = await Self.localSlots.addDemand(key: workKey, priority: priority)
                let installed = sharedWork.withLock { works -> Bool in
                    guard var work = works[workKey], work.id == registration.0,
                          var consumer = work.consumers[consumerID] else { return false }
                    consumer.globalDemand = global; consumer.localDemand = local
                    work.consumers[consumerID] = consumer; works[workKey] = work
                    return true
                }
                if !installed {
                    await ThumbnailDemandScheduler.shared.releaseDemand(key: workKey, id: global)
                    await Self.localSlots.releaseDemand(key: workKey, id: local)
                }
            }
            guard registration.1 else { return }
            let producer = Task.detached(priority: priority == .visible ? .userInitiated : .utility) { [self] in
                await demand.value
                guard !Task.isCancelled else { return }
                for await delivery in providerDeliveries(localIdentifier: localIdentifier, targetPixelSize: targetPixelSize,
                    contentMode: contentMode, coversTarget: coversTarget, allowsNetwork: allowsNetwork,
                    cacheScope: cacheScope, priority: priority, demandKey: workKey) {
                    publish(delivery, key: workKey, workID: registration.0)
                }
                finishSharedWork(key: workKey, workID: registration.0)
            }
            let installed = sharedWork.withLock { works -> Bool in
                guard var work = works[workKey], work.id == registration.0 else { return false }
                work.producer = producer; works[workKey] = work; return true
            }
            if !installed { producer.cancel() }
        }
    }

    private func removeConsumer(_ consumerID: UUID, key: String, workID: UUID) {
        let removed = sharedWork.withLock { works -> (Consumer?, Task<Void, Never>?) in
            guard var work = works[key], work.id == workID else { return (nil, nil) }
            let consumer = work.consumers.removeValue(forKey: consumerID)
            if work.consumers.isEmpty { works[key] = nil; return (consumer, work.producer) }
            works[key] = work; return (consumer, nil)
        }
        removed.1?.cancel()
        releaseDemands(removed.0, key: key)
    }

    private func releaseDemands(_ consumer: Consumer?, key: String) {
        guard let consumer else { return }
        Task {
            if let id = consumer.globalDemand { await ThumbnailDemandScheduler.shared.releaseDemand(key: key, id: id) }
            if let id = consumer.localDemand { await Self.localSlots.releaseDemand(key: key, id: id) }
        }
    }

    private func publish(_ delivery: LocalImageDelivery, key: String, workID: UUID) {
        let continuations = sharedWork.withLock { works -> [AsyncStream<LocalImageDelivery>.Continuation] in
            guard var work = works[key], work.id == workID else { return [] }
            work.latest = delivery; works[key] = work
            return work.consumers.values.map(\.continuation)
        }
        for continuation in continuations { continuation.yield(delivery) }
    }

    private func finishSharedWork(key: String, workID: UUID) {
        let consumers = sharedWork.withLock { works -> [Consumer] in
            guard let work = works[key], work.id == workID else { return [] }
            works[key] = nil; return Array(work.consumers.values)
        }
        for consumer in consumers { consumer.continuation.finish(); releaseDemands(consumer, key: key) }
    }

    private func providerDeliveries(
        localIdentifier: String, targetPixelSize: CGFloat, contentMode: PHImageContentMode,
        coversTarget: Bool, allowsNetwork: Bool, cacheScope: String,
        priority: ThumbnailDemandPriority, demandKey: String
    ) -> AsyncStream<LocalImageDelivery> {
        let generation = libraryGeneration.withLock { $0 }
        let request = ImageRequestBox()
        let manager = manager
        return AsyncStream { continuation in
            continuation.onTermination = { _ in request.cancel(manager) }
            // the library lookup is synchronous photokit work, kept off the
            // caller's actor like the single-image path.
            let work = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try await ThumbnailProviderStart.run(acquireCapacity: {
                        let localPermit = try await Self.localSlots.acquire(priority: priority, key: demandKey)
                        request.registerLocalPermit(localPermit)
                        let permit = try await ThumbnailLoadLimiter.shared.acquire(priority: priority, key: demandKey)
                        request.registerPermit(permit)
                    }, startProvider: {
                        guard !request.isCancelled else {
                            continuation.finish()
                            return
                        }
                        guard let asset = fetchAsset(localIdentifier) else {
                            continuation.yield(.terminal(.missing))
                            continuation.finish()
                            return
                        }
                        let permission = self.permissionGeneration
                        let sourceRevision = asset.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) }
                        let size = Self.targetSize(
                            for: asset,
                            pixels: targetPixelSize,
                            contentMode: contentMode,
                            coversTarget: coversTarget
                        )
                        let requestID = manager.requestImage(
                            for: asset,
                            targetSize: size,
                            contentMode: contentMode,
                            options: Self.requestOptions(allowsNetwork: allowsNetwork)
                        ) { image, info in
                            guard !request.isCancelled else { return }
                            guard self.libraryGeneration.withLock({ $0 }) == generation else {
                                continuation.yield(.terminal(.missing))
                                continuation.finish()
                                return
                            }
                            switch LocalImageResult.classify(
                                hasImage: image != nil,
                                isDegraded: Self.isDegraded(info),
                                isCancelled: Self.isCancelled(info),
                                hasError: info?[PHImageErrorKey] != nil,
                                isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false,
                                allowsNetwork: allowsNetwork
                            ) {
                            case .waiting:
                                return
                            case .preview:
                                if let image {
                                    self.storePreview(image, localIdentifier: localIdentifier, cacheScope: cacheScope)
                                    continuation.yield(.preview(image))
                                }
                                return
                            case .final:
                                break
                            case let outcome:
                                continuation.yield(.terminal(outcome))
                                continuation.finish()
                                return
                            }
                            guard let image else { return }
                            let actual = coversTarget
                                ? min(image.size.width, image.size.height) * image.scale
                                : max(image.size.width, image.size.height) * image.scale
                            let original = CGFloat(coversTarget
                                ? min(asset.pixelWidth, asset.pixelHeight)
                                : max(asset.pixelWidth, asset.pixelHeight))
                            if actual < min(targetPixelSize, original) * 0.95 {
                                self.storePreview(image, localIdentifier: localIdentifier, cacheScope: cacheScope)
                                continuation.yield(.preview(image))
                                continuation.yield(.terminal(.insufficient))
                                continuation.finish()
                                return
                            }
                            let revision = sourceRevision.flatMap {
                                self.permissionGeneration == permission && Self.currentModificationRevision(localIdentifier) == $0 ? $0 : nil
                            }
                            self.store(
                                image,
                                localIdentifier: localIdentifier,
                                targetPixelSize: targetPixelSize,
                                contentMode: contentMode,
                                coversTarget: coversTarget,
                                cacheScope: cacheScope,
                                modificationRevision: revision
                            )
                            continuation.yield(.final(image))
                            continuation.finish()
                        }
                        request.register(requestID, manager: manager)
                    }, armDeadline: {
                        let timeout = Task.detached {
                            do { try await Task.sleep(for: .seconds(8)) } catch { return }
                            continuation.yield(.terminal(.failed))
                            continuation.finish()
                        }
                        request.registerTimeout(timeout)
                    })
                } catch {
                    continuation.finish()
                }
            }
            request.registerWork(work)
        }
    }

    /// an uncropped picture of the asset right now, on the calling thread:
    /// the library's stored thumbnail, fitted to the target. the opening
    /// transition asks for this when the tile's render has left the cache,
    /// because a snapshot of the square tile would hand the viewer a crop to
    /// zoom out of. fast format and no network keep the block to a decode of
    /// the thumbnail, a few milliseconds at most.
    func immediateImage(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode,
        coversTarget: Bool
    ) -> UIImage? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        let size = Self.targetSize(
            for: asset,
            pixels: targetPixelSize,
            contentMode: contentMode,
            coversTarget: coversTarget
        )
        var delivered: UIImage?
        manager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: options) { image, _ in
            delivered = image
        }
        if let delivered { storePreview(delivered, localIdentifier: localIdentifier) }
        return delivered
    }

    // MARK: - prefetching

    /// `allowsNetwork` has to match what the tiles will ask with, or the
    /// caching manager treats their requests as strangers to its cache.
    func startCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        coversTarget: Bool = false,
        allowsNetwork: Bool = true,
        cacheScopes: [String: String] = [:],
        ownerID: UUID? = nil
    ) {
        cachingQueue.async { [self] in
            setCaching(
                true,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode,
                coversTarget: coversTarget,
                allowsNetwork: allowsNetwork,
                cacheScopes: cacheScopes,
                ownerID: ownerID
            )
        }
    }

    func stopCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        coversTarget: Bool = false,
        allowsNetwork: Bool = true,
        cacheScopes: [String: String] = [:],
        ownerID: UUID? = nil
    ) {
        cachingQueue.async { [self] in
            setCaching(
                false,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode,
                coversTarget: coversTarget,
                allowsNetwork: allowsNetwork,
                cacheScopes: cacheScopes,
                ownerID: ownerID
            )
        }
    }

    /// a covering fit gives every asset its own target, and the caching
    /// manager takes one target per call, so the batch is split by target.
    private func setCaching(
        _ caching: Bool,
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode,
        coversTarget: Bool,
        allowsNetwork: Bool,
        cacheScopes: [String: String],
        ownerID: UUID?
    ) {
        // PhotoKit's bulk cache API has no concurrency bound. Warm through
        // the same cancellable render lane as visible tiles instead.
        for identifier in localIdentifiers {
            let scope = cacheScopes[identifier] ?? ""
            let cacheKey = "\(ownerID?.uuidString ?? "default")|\(key(identifier, targetPixelSize, contentMode, coversTarget: coversTarget, cacheScope: scope))|network:\(allowsNetwork)"
            if caching {
                guard prefetchTasks[cacheKey] == nil else { continue }
                prefetchTasks[cacheKey] = Task.detached(priority: .utility) { [self] in
                    _ = await image(localIdentifier: identifier, targetPixelSize: targetPixelSize,
                                    contentMode: contentMode, coversTarget: coversTarget, allowsNetwork: allowsNetwork, cacheScope: scope,
                                    priority: .adjacent)
                }
            } else {
                prefetchTasks.removeValue(forKey: cacheKey)?.cancel()
            }
        }
    }

    /// `allowsNetwork` is false when the caller has a server copy to fall back
    /// on: pulling the original down from icloud would be the slower of the
    /// two, and "available on device" should mean actually on the device.
    func playerItem(localIdentifier: String, allowsNetwork: Bool = true) async -> AVPlayerItem? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        let request = ImageRequestBox()
        let manager = manager
        let items = AsyncStream<AVPlayerItem> { continuation in
            continuation.onTermination = { _ in request.cancel(manager) }
            let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                if let item { continuation.yield(item) }
                continuation.finish()
            }
            request.register(requestID, manager: manager)
        }
        for await item in items { return Task.isCancelled ? nil : item }
        return nil
    }

    // MARK: - live photo motion

    /// exported motion halves, newest last. the viewer seeks through these, so
    /// they outlive a single page, but browsing a library of live photos would
    /// otherwise fill the temp directory a few megabytes at a time.
    private static let motionCacheLimit = 24

    private var motionDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "live-photo-motion")
    }

    /// motion half of a device live photo as a seekable item. photokit only
    /// vends live photos as `PHLivePhoto`, which plays as an opaque unit and
    /// cannot be scrubbed, so the paired video resource is exported instead.
    func motionPlayerItem(localIdentifier: String, allowsNetwork: Bool = true) async -> AVPlayerItem? {
        guard let url = await motionFile(localIdentifier: localIdentifier, allowsNetwork: allowsNetwork)
        else { return nil }
        return AVPlayerItem(url: url)
    }

    /// concurrent for the same reason as `image`: the resource lookup and the
    /// export are both blocking photokit work.
    @concurrent
    private func motionFile(localIdentifier: String, allowsNetwork: Bool) async -> URL? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              !asset.isHidden, asset.mediaSubtypes.contains(.photoLive),
              let modified = asset.modificationDate else { return nil }
        let directory = motionDirectory
        // localidentifiers carry a "uuid/L0/001" shape that cannot be a path.
        let name = localIdentifier.replacingOccurrences(of: "/", with: "_") + "-\(modified.timeIntervalSinceReferenceDate.bitPattern)"
        let destination = directory.appending(path: "\(name).mov")
        if FileManager.default.fileExists(atPath: destination.path) {
            noteMotionUse(destination)
            return destination
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo })
        else { return nil }

        // written to a unique path first: an interrupted write would otherwise
        // leave a truncated file that every later play would trust.
        var staging: URL?
        do {
            let exported = try await PhotoLibraryService.export(resource, to: directory, form: nil,
                progress: nil, onResourceProgress: nil, allowsNetwork: allowsNetwork)
            staging = exported.fileURL
            try Task.checkCancellation()
            guard Self.currentModificationRevision(localIdentifier) == String(modified.timeIntervalSinceReferenceDate.bitPattern)
            else { throw CancellationError() }
            // a concurrent export of the same asset may have landed first.
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: exported.fileURL)
            } else {
                try FileManager.default.moveItem(at: exported.fileURL, to: destination)
            }
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            return nil
        }
        noteMotionUse(destination)
        return destination
    }

    /// keeps the export directory bounded, evicting whatever was touched least
    /// recently rather than whatever happens to be on screen.
    private func noteMotionUse(_ url: URL) {
        let evicted = motionFiles.withLock { files -> URL? in
            files.removeAll { $0 == url }
            files.append(url)
            guard files.count > Self.motionCacheLimit else { return nil }
            return files.removeFirst()
        }
        if let evicted { try? FileManager.default.removeItem(at: evicted) }
    }
}

/// lock-guarded handle on one photokit image request, shared between the
/// stream's termination handler and the task that starts the request. covers
/// the race where the consumer gives up before the request id exists.
private nonisolated final class ImageRequestBox: @unchecked Sendable {
    private struct State {
        var requestID: PHImageRequestID?
        var cancelled = false
        var permit: UUID?
        var localPermit: UUID?
        var work: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool {
        lock.withLock { $0.cancelled }
    }

    func register(_ requestID: PHImageRequestID, manager: PHImageManager) {
        let cancelNow = lock.withLock { state in
            state.requestID = requestID
            return state.cancelled
        }
        if cancelNow { manager.cancelImageRequest(requestID) }
    }

    func registerWork(_ task: Task<Void, Never>) {
        if lock.withLock({ state in state.work = task; return state.cancelled }) { task.cancel() }
    }

    func registerTimeout(_ task: Task<Void, Never>) {
        if lock.withLock({ state in state.timeout = task; return state.cancelled }) { task.cancel() }
    }

    func registerLocalPermit(_ permit: UUID) {
        let releaseNow = lock.withLock { state in
            if state.cancelled { return true }
            state.localPermit = permit
            return false
        }
        if releaseNow { Task { await LocalImageLoader.releaseLocalPermit(permit) } }
    }

    func registerPermit(_ permit: UUID) {
        let releaseNow = lock.withLock { state in
            if state.cancelled { return true }
            state.permit = permit
            return false
        }
        if releaseNow { Task { await ThumbnailLoadLimiter.shared.release(permit) } }
    }

    func cancel(_ manager: PHImageManager) {
        let requestID = lock.withLock { state -> PHImageRequestID? in
            state.cancelled = true
            state.work?.cancel()
            state.timeout?.cancel()
            if let localPermit = state.localPermit {
                state.localPermit = nil
                Task { await LocalImageLoader.releaseLocalPermit(localPermit) }
            }
            if let permit = state.permit {
                state.permit = nil
                Task { await ThumbnailLoadLimiter.shared.release(permit) }
            }
            return state.requestID
        }
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}
