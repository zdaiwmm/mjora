import ImageIO
import Nuke
import Synchronization
import UIKit

private nonisolated struct MediaRequestBinding: Sendable {
    static let userInfoKey = ImageRequest.UserInfoKey("imora.contentBinding")
    let key: MediaDisplayKeyV1
    /// Original session-scoped endpoint, before the local Nuke work suffix.
    let endpointURL: URL
    let runtimeSession: UUID
    let requiresElevation: Bool
    let privateLease: LockedMediaLease?
    var isCurrent: Bool { key.isCurrentContent && (!requiresElevation || privateLease?.isCurrent == true) }
}

/// Pixels and the authority captured for the request that actually produced
/// them. The viewer may carry this proof across its detached transition.
nonisolated struct BoundRemoteImage: @unchecked Sendable {
    let image: UIImage
    let key: MediaDisplayKeyV1
    let access: MediaAccessGeneration
    let localProvenance: LocalSurfaceProvenance?
    fileprivate let validate: @Sendable () -> Bool
    var isCurrent: Bool { validate() }
}

/// downloads and caches asset thumbnails on top of a nuke pipeline. beyond the
/// memory and disk caches, the library brings request coalescing, a rate
/// limiter tuned for fast scrolling, resumable downloads and the prefetcher
/// the grids use to load tiles before they come on screen.
nonisolated final class ImageLoader: Sendable {
    static let shared = ImageLoader()

    private let pipeline: ImagePipeline
    private let visibleTasks = Mutex<[UUID: ImageTask]>([:])
    private let observedRequests = Mutex<[String: ImageRequest]>([:])
    private let authorization = AuthorizingDelegate()
    private struct PrefetchPair: Sendable {
        let decoded: ImagePrefetcher
        let data: ImagePrefetcher
    }
    /// Each screen owns its Nuke subscriptions. The pipeline itself still
    /// coalesces the underlying request across screens and visible consumers.
    private let prefetchers = Mutex<[UUID: PrefetchPair]>([:])
    /// held directly so storage settings can measure and wipe it.
    private let dataCache: DataCache?

    private init() {
        // an aggressive data cache instead of urlcache: immich thumbnails are
        // immutable per cache key, so revalidating them is wasted latency.
        let dataCache = try? DataCache(name: "imora-images")
        // Reserve the protected W0 pack inside the existing 1 GiB budget.
        dataCache?.sizeLimit = (1 << 30) - LaunchPreviewStore.budget
        self.dataCache = dataCache

        let authorization = self.authorization
        var configuration = ImagePipeline.Configuration()
        configuration.dataCache = dataCache
        configuration.imageCache = ImageCache(costLimit: 96 << 20)
        // the sanitized key drops the thumbnail size, so one download serves
        // every pixel size the grid and the viewer ask for.
        configuration.dataCachePolicy = .storeOriginalData
        // Both prefetch lanes and visible requests share four network
        // slots; decoding keeps its existing two-worker bound.
        configuration.dataLoadingQueue.maxConcurrentOperationCount = 4
        configuration.imageDecodingQueue.maxConcurrentOperationCount = 2
        configuration.makeImageDecoder = { context in
            FittingThumbnailDecoder(context: context) ?? ImageDecoderRegistry.shared.decoder(for: context)
        }
        pipeline = ImagePipeline(configuration: configuration, delegate: authorization)
    }

    /// call after login so image requests carry the token.
    func configure(client: ImoraClient?) {
        if client != nil { try? MediaContentGenerations.shared.ensureInitialized() }
        authorization.client.withLock { $0 = nil }
        sweepTask.withLock { current in current?.cancel(); current = nil }
        stopAllPrefetching()
        visibleTasks.withLock { tasks in tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
        authorization.networkTasks.withLock { tasks in
            tasks.values.forEach { $0.task.cancel() }; tasks.removeAll()
        }
        // Pinned Nuke removeAll() clears disk too. Content is scoped below;
        // rotating runtime authorization retires tasks and memory, not valid bytes.
        pipeline.cache.removeAll(caches: [.memory])
        authorization.ephemeralAssetIDs.withLock { $0.removeAll() }
        authorization.client.withLock { $0 = client }
        observedRequests.withLock { $0.removeAll() }
    }

    /// keeps these assets' bytes out of the disk cache from now on. the
    /// locked folder registers its assets so the pin protects them at rest.
    @MainActor func markEphemeral(assetIDs: [String]) {
        let newlyLocked = authorization.ephemeralAssetIDs.withLock { ids in
            let added = Set(assetIDs).subtracting(ids); ids.formUnion(assetIDs); return added
        }
        if !newlyLocked.isEmpty, let client = authorization.client.withLock({ $0 }) {
            let unconfirmed = newlyLocked.filter {
                MediaContentGenerations.shared.presentationNamespace(scope: client.mediaDisplayScope,
                    subject: .remoteAsset($0)).visibilityPolicy != "locked"
            }
            if !unconfirmed.isEmpty, let failure = invalidateSubjects(client: client,
                subjects: unconfirmed.map { .remoteAsset($0) }, retiresSourceRevisions: false, blocksAccess: true) {
                MediaCacheRecovery.handle(client: client, failure: failure)
            }
        }
    }

    func revokePrivateImages(client: ImoraClient, leaseIdentity: String) {
        let requests = observedRequests.withLock { values in
            let privateRequests = values.filter { _, request in
                guard let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding else { return false }
                return binding.key.scope == client.mediaDisplayScope && binding.requiresElevation
                    && binding.privateLease?.identity == leaseIdentity
            }
            for key in privateRequests.keys { values[key] = nil }
            return Array(privateRequests.values)
        }
        for request in requests { pipeline.cache.removeCachedImage(for: request) }
        visibleTasks.withLock { values in
            for task in values.values {
                guard let binding = task.request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding,
                      binding.key.scope == client.mediaDisplayScope, binding.requiresElevation,
                      binding.privateLease?.identity == leaseIdentity else { continue }
                task.cancel()
            }
        }
        authorization.networkTasks.withLock { values in
            for transfer in values.values where transfer.binding?.key.scope == client.mediaDisplayScope
                && transfer.binding?.requiresElevation == true
                && transfer.binding?.privateLease?.identity == leaseIdentity { transfer.task.cancel() }
        }
    }

    func requestKey(for url: URL, targetPixelSize: CGFloat) -> String {
        let binding = binding(for: url, pixels: targetPixelSize)
        let generation = binding?.key.contentGeneration ?? ""
        let privateSuffix = binding?.requiresElevation == true ? "#elevation:\(binding?.privateLease?.identity ?? "denied")" : ""
        return "\(url.absoluteString)#\(Self.normalizedPixelSize(targetPixelSize, for: url))#\(generation)\(privateSuffix)"
    }

    func requiresPrivateLease(for url: URL, targetPixelSize: CGFloat) -> Bool {
        binding(for: url, pixels: targetPixelSize)?.requiresElevation == true
    }

    func cachedImage(for url: URL, targetPixelSize: CGFloat) -> UIImage? {
        cachedSurface(for: url, targetPixelSize: targetPixelSize)?.image
    }

    func cachedSurface(for url: URL, targetPixelSize: CGFloat) -> (image: UIImage, localProvenance: LocalSurfaceProvenance?)? {
        guard let client = authorization.client.withLock({ $0 }),
              (try? client.authorizedRequest(url: url)) != nil else { return nil }
        let request = request(for: url, targetPixelSize: targetPixelSize)
        guard Self.isCurrent(request) else { return nil }
        let container = pipeline.cache[request]
        if let provenance = container?.userInfo["imora.local-provenance"] as? LocalSurfaceProvenance {
            guard container?.userInfo["imora.local-permission"] as? Int == LocalImageLoader.shared.permissionGeneration,
                  LocalImageLoader.currentModificationRevision(provenance.localIdentifier) == provenance.modificationRevision else {
                pipeline.cache[request] = nil
                return nil
            }
        }
        guard let container else { return nil }
        guard client.context.isActive, authorization.client.withLock({ $0 === client }), Self.isCurrent(request) else { return nil }
        return (container.image, container.userInfo["imora.local-provenance"] as? LocalSurfaceProvenance)
    }

    @concurrent
    func diskImage(for url: URL, targetPixelSize: CGFloat) async -> UIImage? {
        guard let client = authorization.client.withLock({ $0 }),
              (try? client.authorizedRequest(url: url)) != nil else { return nil }
        let request = request(for: url, targetPixelSize: targetPixelSize)
        guard Self.isCurrent(request) else { return nil }
        // storeOriginalData persists endpoint bytes without thumbnail options.
        // Match TaskLoadImage's fallback, while decoding with the original
        // sized request and its captured authorization/content binding.
        var original = request
        original.thumbnail = nil
        original.processors = []
        guard let data = pipeline.cache.cachedData(for: request) ?? pipeline.cache.cachedData(for: original) else { return nil }
        let context = ImageDecodingContext(request: request, data: data, cacheType: .disk)
        let image = try? pipeline.configuration.makeImageDecoder(context)?.decode(data).image
        guard client.context.isActive, authorization.client.withLock({ $0 === client }), !Task.isCancelled, Self.isCurrent(request) else { return nil }
        return image
    }

    func installPrepared(_ image: UIImage, url: URL, targetPixelSize: CGFloat, client: ImoraClient,
                         localProvenance: LocalSurfaceProvenance? = nil) {
        guard authorization.client.withLock({ $0 === client }),
              (try? client.authorizedRequest(url: url)) != nil else { return }
        let request = request(for: url, targetPixelSize: targetPixelSize)
        guard Self.isCurrent(request) else { return }
        var container = ImageContainer(image: image)
        if let localProvenance {
            guard LocalImageLoader.currentModificationRevision(localProvenance.localIdentifier) == localProvenance.modificationRevision else { return }
            container.userInfo["imora.local-provenance"] = localProvenance
            container.userInfo["imora.local-permission"] = LocalImageLoader.shared.permissionGeneration
        }
        pipeline.cache[request] = container
    }

    func cachedGridImage(thumbnailURL: URL, previewURL: URL, targetPixelSize: CGFloat, aspectRatio: Double) -> UIImage? {
        cachedGridSurface(thumbnailURL: thumbnailURL, previewURL: previewURL, targetPixelSize: targetPixelSize, aspectRatio: aspectRatio)?.image
    }

    func cachedGridSurface(thumbnailURL: URL, previewURL: URL, targetPixelSize: CGFloat, aspectRatio: Double)
        -> (image: UIImage, localProvenance: LocalSurfaceProvenance?)? {
        if let surface = cachedSurface(for: thumbnailURL, targetPixelSize: targetPixelSize),
           min(surface.image.size.width, surface.image.size.height) * surface.image.scale >= targetPixelSize { return surface }
        let ratio = max(0.01, aspectRatio)
        guard let surface = cachedSurface(for: previewURL, targetPixelSize: targetPixelSize * max(ratio, 1 / ratio)),
              min(surface.image.size.width, surface.image.size.height) * surface.image.scale >= targetPixelSize else { return nil }
        return surface
    }

    @MainActor func invalidate(asset: Asset, client: ImoraClient, retiresSourceRevisions: Bool = true, blocksAccess: Bool = false) {
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 1)
        if let failure = invalidateSubjects(client: client, subjects: [key.subject], keys: [key],
            retiresSourceRevisions: retiresSourceRevisions, blocksAccess: blocksAccess) {
            MediaCacheRecovery.handle(client: client, failure: failure)
        }
    }

    /// A durable generation retires every size, revision and late callback,
    /// including variants not retained in the bounded observed-request index.
    @discardableResult
    func invalidateSubjects(client: ImoraClient, subjects: [MediaDisplayKeyV1.Subject]?, keys: [MediaDisplayKeyV1] = [],
                            retiresSourceRevisions: Bool = true, blocksAccess: Bool = false) -> MediaContentGenerations.RetirementFailure? {
        var persistenceFailure: MediaContentGenerations.RetirementFailure?
        var scopeTransition = false
        let scope = client.mediaDisplayScope
        let observed = observedRequests.withLock { requests in
            let matching = requests.filter { _, request in
                guard let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding else { return false }
                return binding.key.scope == scope && (subjects == nil || subjects!.contains(binding.key.subject))
            }
            matching.keys.forEach { requests[$0] = nil }
            return Array(matching.values)
        }
        let knownKeys = observed.compactMap { ($0.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding)?.key }
        do { scopeTransition = try MediaContentGenerations.shared.retire(scope: scope, subjects: subjects,
            keys: retiresSourceRevisions ? keys + knownKeys : [], retiresSourceRevisions: retiresSourceRevisions, blocksAccess: blocksAccess) }
        catch {
            // A failed retirement cannot leave the previous namespace usable.
            // Purge derivative layers only, and retire this runtime authorization.
            pipeline.cache.removeAll(); dataCache?.flush()
            persistenceFailure = error as? MediaContentGenerations.RetirementFailure ?? .init(journalRemovalSucceeded: false)
            scopeTransition = persistenceFailure?.durableScopeDenied == true
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            if let bytes = try? encoder.encode(scope) {
                try? FileManager.default.removeItem(at: LaunchPreviewStore.rootDirectory.appending(path: MediaDisplayKeyV1.digest(bytes)))
            }
        }
        if scopeTransition {
            // Only a scope-wide epoch transition invalidates otherwise stable
            // mounted subjects. Ordinary subject retirement adds no global churn.
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, client.context.isActive,
                      self.authorization.client.withLock({ $0 === client }) else { return }
                ImageLoadRecovery.shared.contentChanged()
            }
        }
        for request in observed { pipeline.cache.removeCachedImage(for: request) }
        visibleTasks.withLock { tasks in
            for task in tasks.values {
                guard let binding = task.request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding,
                      binding.key.scope == scope, subjects == nil || subjects!.contains(binding.key.subject) else { continue }
                task.cancel()
            }
        }
        authorization.networkTasks.withLock { tasks in
            for entry in tasks.values where entry.binding?.key.scope == scope
                && (subjects == nil || entry.binding.map { subjects!.contains($0.key.subject) } == true) { entry.task.cancel() }
        }
        stopAllPrefetching()
        sweepTask.withLock { task in task?.cancel(); task = nil }
        return persistenceFailure
    }

    @MainActor
    func authorizePresentation(asset: Asset, client: ImoraClient, captured: MediaContentGenerations.CapturedAccess) -> Bool {
        guard client.context.isActive, authorization.client.withLock({ $0 === client }),
              client.mediaDisplayScope == captured.scope else { return false }
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 1)
        do {
            let changed = try MediaContentGenerations.shared.authorize(scope: key.scope, subject: key.subject,
                sourceRevision: key.sourceRevision, captured: captured, visibilityPolicy: asset.visibility.rawValue)
            if changed, asset.visibility == .timeline || asset.visibility == .archive {
                _ = authorization.ephemeralAssetIDs.withLock { $0.remove(asset.id) }
            }
            return changed
        }
        catch { return false } // Failed positive publication leaves access blocked.
    }

    func image(for url: URL, targetPixelSize: CGFloat) async throws -> UIImage {
        try await loadImage(for: url, targetPixelSize: targetPixelSize).0
    }

    /// The binding is captured before the request, never reconstructed from
    /// an arbitrary image after a later authorization change.
    func boundImage(for url: URL, targetPixelSize: CGFloat) async throws -> BoundRemoteImage {
        guard let captured = presentationBinding(for: url, pixels: targetPixelSize) else { throw CancellationError() }
        let (image, provenance) = try await loadImage(for: url, targetPixelSize: targetPixelSize)
        guard captured.isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return captured.attach(image, provenance: provenance)
    }

    func cachedBoundImage(for url: URL, targetPixelSize: CGFloat) -> BoundRemoteImage? {
        guard let captured = presentationBinding(for: url, pixels: targetPixelSize),
              let surface = cachedSurface(for: url, targetPixelSize: targetPixelSize),
              captured.isCurrent() else { return nil }
        return captured.attach(surface.image, provenance: surface.localProvenance)
    }

    private struct PresentationBinding: Sendable {
        let key: MediaDisplayKeyV1
        let access: MediaAccessGeneration
        let isCurrent: @Sendable () -> Bool
        func attach(_ image: UIImage, provenance: LocalSurfaceProvenance?) -> BoundRemoteImage {
            BoundRemoteImage(image: image, key: key, access: access, localProvenance: provenance, validate: {
                guard isCurrent() else { return false }
                guard let provenance else { return true }
                return LocalImageLoader.currentModificationRevision(provenance.localIdentifier) == provenance.modificationRevision
            })
        }
    }

    private func presentationBinding(for url: URL, pixels: CGFloat) -> PresentationBinding? {
        guard let client = authorization.client.withLock({ $0 }),
              let binding = binding(for: url, pixels: pixels), binding.isCurrent else { return nil }
        let access = MediaPresentationCoordinator.access(for: client)
        return PresentationBinding(key: binding.key, access: access, isCurrent: { [weak self, weak client] in
            guard let self, let client else { return false }
            return client.context.isActive && self.authorization.client.withLock({ $0 === client })
                && client.context.id == binding.runtimeSession && client.mediaDisplayScope == binding.key.scope
                && MediaPresentationCoordinator.access(for: client) == access && binding.isCurrent
        })
    }

    private func loadImage(for url: URL, targetPixelSize: CGFloat) async throws -> (UIImage, LocalSurfaceProvenance?) {
        guard let client = authorization.client.withLock({ $0 }) else { throw ServerTrustError.sessionExpired }
        _ = try client.authorizedRequest(url: url)
        var request = request(for: url, targetPixelSize: targetPixelSize)
        guard Self.isCurrent(request) else { throw CancellationError() }
        // A raw remote-result API must not strip the proof attached to a
        // restored local-derived alias. Such aliases use cachedSurface;
        // ordinary pipeline results come from real endpoint bytes.
        if pipeline.cache[request]?.userInfo["imora.local-provenance"] != nil {
            request.options.insert(.disableMemoryCacheReads)
        }
        migrateCredentialData(to: request, client: client)
        // a tile on screen beats every prefetch and sweep request queued
        // ahead of it; those run low and very low.
        request.priority = .high
        let demandKey = Self.demandKey(for: request, client: client)
        let demand = await ThumbnailDemandScheduler.shared.addDemand(key: demandKey, priority: .visible)
        let id = UUID()
        let task = pipeline.imageTask(with: request)
        visibleTasks.withLock { $0[id] = task }
        defer { visibleTasks.withLock { _ = $0.removeValue(forKey: id) } }
        do {
            let image = try await withTaskCancellationHandler {
                let response = try await task.response
                guard client.context.isActive, authorization.client.withLock({ $0 === client }), Self.isCurrent(request) else { throw ServerTrustError.sessionExpired }
                if let provenance = response.container.userInfo["imora.local-provenance"] as? LocalSurfaceProvenance {
                    guard response.container.userInfo["imora.local-permission"] as? Int == LocalImageLoader.shared.permissionGeneration,
                          LocalImageLoader.currentModificationRevision(provenance.localIdentifier) == provenance.modificationRevision else {
                        pipeline.cache[request] = nil
                        throw CancellationError()
                    }
                }
                return (response.image, response.container.userInfo["imora.local-provenance"] as? LocalSurfaceProvenance)
            } onCancel: { task.cancel() }
            await ThumbnailDemandScheduler.shared.releaseDemand(key: demandKey, id: demand)
            return image
        } catch {
            await ThumbnailDemandScheduler.shared.releaseDemand(key: demandKey, id: demand)
            throw error
        }
    }

    /// Bounded grid-only derivative loading. An error is propagated after
    /// the single preview attempt, so a tile remains retryable.
    func gridThumbnail(
        thumbnailURL: URL,
        previewURL: URL,
        targetPixelSize: CGFloat,
        aspectRatio: Double = 1,
        onPreview: @escaping @MainActor @Sendable (UIImage) -> Void = { _ in }
    ) async throws -> UIImage {
        guard let initialClient = authorization.client.withLock({ $0 }) else { throw ServerTrustError.sessionExpired }
        guard let initialKey = binding(for: thumbnailURL, pixels: targetPixelSize)?.key, initialKey.isCurrentContent else { throw CancellationError() }
        var state = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: Double(targetPixelSize))
        let ratio = max(0.01, aspectRatio)
        for (url, isPreview) in [(thumbnailURL, false), (previewURL, true)] {
            try Task.checkCancellation()
            guard initialClient.context.isActive, authorization.client.withLock({ $0 === initialClient }) else {
                throw ServerTrustError.sessionExpired
            }
            let size = isPreview ? targetPixelSize * max(ratio, 1 / ratio) : targetPixelSize
            guard let requested = binding(for: url, pixels: size)?.key,
                  requested.scope == initialKey.scope, requested.subject == initialKey.subject,
                  requested.sourceRevision == initialKey.sourceRevision,
                  requested.presentationRevision == initialKey.presentationRevision,
                  requested.contentGeneration == initialKey.contentGeneration else { throw CancellationError() }
            do {
                let loaded = try await image(for: url, targetPixelSize: size)
                try Task.checkCancellation()
                let pixels = Double(min(loaded.size.width, loaded.size.height) * loaded.scale)
                if state.remoteResult(pixels: pixels, isPreview: isPreview) == .finished {
                    guard initialKey.isCurrentContent else { throw CancellationError() }
                    if isPreview, pixels >= Double(targetPixelSize) {
                        // The same committed asset's adequate decoded preview
                        // also fulfils the grid demand. Do not cache 333×250 raw
                        // thumbnail bytes as though they covered a416px tile.
                        let gridRequest = request(for: thumbnailURL, targetPixelSize: targetPixelSize)
                        guard let binding = gridRequest.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding,
                              binding.key.contentGeneration == initialKey.contentGeneration, binding.isCurrent else { throw CancellationError() }
                        pipeline.cache[gridRequest] = ImageContainer(image: loaded)
                    }
                    guard initialKey.isCurrentContent else { throw CancellationError() }
                    return loaded
                }
                await onPreview(loaded)
            } catch {
                try Task.checkCancellation()
                if isPreview { throw error }
                _ = state.remoteResult(pixels: nil, isPreview: false)
            }
        }
        throw URLError(.cannotDecodeContentData)
    }

    // MARK: - prefetching

    /// warms the caches for tiles about to scroll into view. prefetches run at
    /// a lower priority than visible requests and coalesce with them, so a tile
    /// that appears mid-flight reuses the download already in progress.
    private func prefetchPair(for ownerID: UUID) -> PrefetchPair {
        prefetchers.withLock { pairs in
            if let pair = pairs[ownerID] { return pair }
            let decoded = ImagePrefetcher(pipeline: pipeline, maxConcurrentRequestCount: 4)
            let data = ImagePrefetcher(pipeline: pipeline, destination: .diskCache, maxConcurrentRequestCount: 2)
            data.priority = .veryLow
            let pair = PrefetchPair(decoded: decoded, data: data)
            pairs[ownerID] = pair
            return pair
        }
    }

    private func stopAllPrefetching() {
        let pairs = prefetchers.withLock { values in
            let previous = Array(values.values)
            values.removeAll()
            return previous
        }
        for pair in pairs { pair.decoded.stopPrefetching(); pair.data.stopPrefetching() }
    }

    func releasePrefetchOwner(_ ownerID: UUID) {
        guard let pair = prefetchers.withLock({ $0.removeValue(forKey: ownerID) }) else { return }
        pair.decoded.stopPrefetching(); pair.data.stopPrefetching()
    }

    func startPrefetching(urls: [URL], targetPixelSize: CGFloat, ownerID: UUID) {
        prefetchPair(for: ownerID).decoded.startPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    func stopPrefetching(urls: [URL], targetPixelSize: CGFloat, ownerID: UUID) {
        guard let pair = prefetchers.withLock({ $0[ownerID] }) else { return }
        pair.decoded.stopPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    /// downloads to the disk cache without decoding, for tiles further out.
    func startPrefetchingData(urls: [URL], ownerID: UUID) {
        prefetchPair(for: ownerID).data.startPrefetching(with: requests(for: urls, targetPixelSize: 512))
    }

    func stopPrefetchingData(urls: [URL], ownerID: UUID) {
        guard let pair = prefetchers.withLock({ $0[ownerID] }) else { return }
        pair.data.stopPrefetching(with: requests(for: urls, targetPixelSize: 512))
    }

    // MARK: - offline sweep

    /// tail of thumbnails a sweep will fetch; roughly what fits the disk cache.
    private static let sweepLimit = 20_000

    /// background pass that fills the disk cache with every thumbnail not yet
    /// stored, so offline browsing shows photos beyond the regions already
    /// visited. bytes land on disk without decoding, at a priority visible
    /// tiles always beat. best effort: failures are skipped and a new sweep
    /// replaces the previous one.
    func sweepThumbnails(urls: [URL]) {
        let pipeline = pipeline
        let task = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.prefix(Self.sweepLimit).makeIterator()
                func nextRequest() -> ImageRequest? {
                    while let url = iterator.next() {
                        var request = self.request(for: url, targetPixelSize: 512)
                        request.priority = .veryLow
                        if !pipeline.cache.containsData(for: request) { return request }
                    }
                    return nil
                }
                // two lanes are slow enough to never crowd out visible tiles
                // and still cover a large library over a session.
                for _ in 0..<2 {
                    guard let request = nextRequest() else { break }
                    group.addTask { _ = try? await pipeline.data(for: request) }
                }
                for await _ in group {
                    guard !Task.isCancelled else { continue }
                    // held while a grid scrolls: the lanes would otherwise take
                    // bandwidth from the tiles coming on screen.
                    await self.waitWhileSweepPaused()
                    guard !Task.isCancelled, let request = nextRequest() else { continue }
                    group.addTask { _ = try? await pipeline.data(for: request) }
                }
            }
        }
        sweepTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    private let sweepTask = Mutex<Task<Void, Never>?>(nil)
    private let sweepPaused = Mutex<Bool>(false)

    /// grids pause the sweep for the length of a scroll, so its lanes never
    /// compete with tiles the user is about to look at.
    func setSweepPaused(_ paused: Bool) {
        sweepPaused.withLock { $0 = paused }
    }

    private func waitWhileSweepPaused() async {
        while sweepPaused.withLock({ $0 }), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - storage

    /// bytes the downloaded images occupy on disk. disk io, keep off main.
    func diskUsage() -> Int64 {
        Int64(dataCache?.totalAllocatedSize ?? 0)
    }

    /// wipes downloaded images from memory and disk. cancels a running sweep
    /// first, otherwise it would quietly refill what was just reclaimed.
    func clearCache() {
        sweepTask.withLock { current in
            current?.cancel()
            current = nil
        }
        pipeline.cache.removeAll()
        // deletions are queued; waiting makes the recount deterministic.
        dataCache?.flush()
    }

    // MARK: - requests

    /// Import only a requested, revisioned derivative from the *same* verified
    /// credential. Old UUID-fragment-only cache entries cannot be proven and
    /// are intentionally left to normal eviction, never bulk-copied.
    private func migrateCredentialData(to request: ImageRequest, client: ImoraClient) {
        guard client.mediaDisplayScope.accountID != nil, let credential = client.offlineAccountKey,
              let url = request.url, url.lastPathComponent == "thumbnail",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "c" && $0.value?.isEmpty == false }) == true,
              let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding,
              binding.isCurrent,
              MediaContentGenerations.shared.canMigrateLegacy(scope: binding.key.scope, subject: binding.key.subject),
              !pipeline.cache.containsData(for: request) else { return }
        var legacy = request
        legacy.imageID = Self.contentID(scope: .credential(credential, server: client.serverKey), components: components)
        if let bytes = pipeline.cache.cachedData(for: legacy), client.context.isActive,
           authorization.client.withLock({ $0 === client }) {
            pipeline.cache.storeCachedData(bytes, for: request)
        }
    }

    private static func contentID(scope: StableMediaScope, components: URLComponents) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(scope) else { return nil }
        return "media-v1|\(MediaDisplayKeyV1.digest(encoded))|\(components.percentEncodedPath)|\(components.percentEncodedQuery ?? "")"
    }

    private static func isCurrent(_ request: ImageRequest) -> Bool {
        (request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding)?.isCurrent ?? true
    }

    fileprivate static func demandKey(for request: ImageRequest, client: ImoraClient) -> String {
        // The content ID includes the content generation and private lease;
        // the runtime context keeps a retired session from sharing admission.
        "\(client.context.id.uuidString)|\(request.imageID ?? request.url?.absoluteString ?? "")"
    }

    private func binding(for url: URL, pixels: CGFloat) -> MediaRequestBinding? {
        guard let client = authorization.client.withLock({ $0 }),
              (try? client.authorizedRequest(url: url)) != nil,
              let index = url.pathComponents.firstIndex(of: "assets"), url.pathComponents.indices.contains(index + 1) else { return nil }
        let revision = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value ?? ""
        let scope = client.mediaDisplayScope, subject = MediaDisplayKeyV1.Subject.remoteAsset(url.pathComponents[index + 1])
        let namespace = MediaContentGenerations.shared.presentationNamespace(scope: scope, subject: subject)
        let requiresElevation = namespace.visibilityPolicy == "locked"
            || authorization.ephemeralAssetIDs.withLock { $0.contains(url.pathComponents[index + 1]) }
        return .init(key: .init(scope: scope, subject: subject,
            sourceRevision: revision, presentationRevision: "committed:\(revision)", variant: .grid,
            pixelBucket: max(1, Int(pixels.rounded(.up))), fitMode: "fit-cover", orientationRevision: "source", colorProfile: "source",
            contentGeneration: namespace.generation, visibilityPolicy: namespace.visibilityPolicy),
            endpointURL: url, runtimeSession: client.context.id,
            requiresElevation: requiresElevation, privateLease: requiresElevation ? client.lockedMediaLease : nil)
    }

    /// decoding straight to a thumbnail keeps memory flat while scrolling -
    /// the full-size bitmap never exists.
    private func request(for url: URL, targetPixelSize: CGFloat) -> ImageRequest {
        let binding = binding(for: url, pixels: targetPixelSize)
        var workURL = url
        if let binding {
            // Nuke keys its original-data task by the initializer URL, not
            // imageID. The local fragment carries the captured generation and
            // runtime authority before Nuke coalesces data; the authenticated
            // endpoint below remains unchanged. Compatible sizes still share.
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return ImageRequest(url: nil)
            }
            let sessionFragment = components.fragment ?? ""
            let generation = MediaDisplayKeyV1.digest(Data(binding.key.contentGeneration.utf8))
            let privateSuffix = binding.requiresElevation
                ? "&imora-private-producer=\(binding.privateLease?.identity ?? "denied")" : ""
            components.fragment = "\(sessionFragment)&imora-work-session=\(binding.runtimeSession.uuidString)&imora-content-generation=\(generation)\(privateSuffix)"
            guard let scoped = components.url else { return ImageRequest(url: nil) }
            workURL = scoped
        }
        var request = ImageRequest(url: workURL)
        if let client = authorization.client.withLock({ $0 }),
           (try? client.authorizedRequest(url: url)) != nil {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                // Trust policy validates host/context first. Only then may a LAN/WAN
                // route share content; query preserves edited/size/revision semantics.
                if let key = Self.contentID(scope: client.mediaDisplayScope, components: components) {
                    let privateSuffix = binding?.requiresElevation == true ? "|elevation:\(binding?.privateLease?.identity ?? "denied")" : ""
                    request.imageID = key + "|generation:\(binding?.key.contentGeneration ?? "")" + privateSuffix
                }
            }
        }
        let maxPixelSize = Self.normalizedPixelSize(targetPixelSize, for: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: Float(maxPixelSize))
        request.userInfo[FittingThumbnailDecoder.maxPixelSizeKey] = maxPixelSize
        if let binding { request.userInfo[MediaRequestBinding.userInfoKey] = binding }
        observedRequests.withLock { requests in
            if requests.count >= 2048, let oldest = requests.keys.first { requests[oldest] = nil }
            requests["\(request.imageID ?? url.absoluteString)|\(maxPixelSize)"] = request
        }
        return request
    }

    private func requests(for urls: [URL], targetPixelSize: CGFloat) -> [ImageRequest] {
        urls.map { request(for: $0, targetPixelSize: targetPixelSize) }
    }

    /// server thumbnails are a few hundred pixels, smaller than any grid tile
    /// asks for, so every size up to the floor decodes to the same bitmap. one
    /// key for all of them lets the grid at any column count, the filmstrip
    /// and the zoom source share a single decode.
    private static let serverThumbnailFloor = 512

    private static func normalizedPixelSize(_ value: CGFloat, for url: URL) -> Int {
        let size = max(1, Int(value.rounded(.up)))
        guard size < serverThumbnailFloor,
              url.lastPathComponent == "thumbnail",
              url.query()?.contains("size=thumbnail") == true
        else { return size }
        return serverThumbnailFloor
    }
}

/// decodes a thumbnail request at the source's own size when that already
/// fits its target. imageio's thumbnail path costs a third more for the same
/// pixels, and server thumbnails always fit a grid tile. larger, rotated or
/// animated sources keep nuke's downsampling decoder.
private final class FittingThumbnailDecoder: ImageDecoding, @unchecked Sendable {
    static let maxPixelSizeKey = ImageRequest.UserInfoKey("imora.maxPixelSize")

    private let maxPixelSize: Int
    private let scale: CGFloat
    private let context: ImageDecodingContext

    init?(context: ImageDecodingContext) {
        guard context.request.thumbnail != nil,
              let maxPixelSize = context.request.userInfo[Self.maxPixelSizeKey] as? Int
        else { return nil }
        self.maxPixelSize = maxPixelSize
        scale = CGFloat(context.request.scale)
        self.context = context
    }

    func decode(_ data: Data) throws -> ImageContainer {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) <= maxPixelSize,
              (properties[kCGImagePropertyOrientation] as? UInt32 ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else {
            guard let fallback = ImageDecoderRegistry.shared.decoder(for: context) else {
                throw ImageDecodingError.unknown
            }
            return try fallback.decode(data)
        }
        var container = ImageContainer(image: UIImage(cgImage: image, scale: scale, orientation: .up))
        container.type = Nuke.AssetType(data)
        return container
    }
}

/// injects the session token and the local address as the request leaves the
/// pipeline. keeping both out of the request itself means the cache keys never
/// mention them, so signing back in or switching networks still hits a warm
/// cache.
private final class AuthorizingDelegate: ImagePipeline.Delegate {
    let client = Mutex<ImoraClient?>(nil)
    let ephemeralAssetIDs = Mutex<Set<String>>([])
    struct Transfer: Sendable { let task: Task<Void, Never>; let binding: MediaRequestBinding? }
    let networkTasks = Mutex<[UUID: Transfer]>([:])

    nonisolated func dataLoader(for request: ImageRequest, pipeline: ImagePipeline) -> any DataLoading {
        let current = client.withLock { $0 }
        let priority: ThumbnailDemandPriority = request.priority >= .high ? .visible
            : (request.priority == .veryLow ? .background : .adjacent)
        return AccountImageDataLoader(client: current, owner: self,
            binding: request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding,
            demandKey: current.map { ImageLoader.demandKey(for: request, client: $0) }, priority: priority)
    }

    /// nuke asks before every disk read and write; nil keeps a locked asset
    /// memory only.
    nonisolated func dataCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any DataCaching)? {
        let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding
        guard let url = binding?.endpointURL ?? request.url, let client = client.withLock({ $0 }),
              (try? client.authorizedRequest(url: url)) != nil,
              binding?.isCurrent != false else { return nil }
        if binding?.requiresElevation == true { return nil }
        if let id = Self.assetID(in: url), ephemeralAssetIDs.withLock({ $0.contains(id) }) {
            return nil
        }
        return pipeline.configuration.dataCache
    }

    nonisolated func imageCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any ImageCaching)? {
        let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding
        guard let url = binding?.endpointURL ?? request.url, let client = client.withLock({ $0 }),
              (try? client.authorizedRequest(url: url)) != nil,
              binding?.isCurrent != false else { return nil }
        return pipeline.configuration.imageCache
    }

    /// the asset id follows the assets segment in every media url.
    private nonisolated static func assetID(in url: URL?) -> String? {
        guard let components = url?.pathComponents,
              let index = components.firstIndex(of: "assets"),
              components.indices.contains(index + 1)
        else { return nil }
        return components[index + 1]
    }

    @ImagePipelineActor
    func willLoadData(
        for request: ImageRequest,
        urlRequest: URLRequest,
        pipeline: ImagePipeline
    ) async throws -> URLRequest {
        let binding = request.userInfo[MediaRequestBinding.userInfoKey] as? MediaRequestBinding
        guard binding?.isCurrent != false else { throw CancellationError() }
        guard let client = client.withLock({ $0 }), let url = binding?.endpointURL ?? urlRequest.url else { throw ServerTrustError.sessionExpired }
        return try client.authorizedRequest(url: ServerRoute.resolve(url))
    }

    /// a thumbnail that found nobody at the local address moves the rest of
    /// the grid over to the external one.
    nonisolated func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, pipeline: ImagePipeline) {
        guard case .finished(.failure(.dataLoadingFailed(let error))) = event,
              let url = task.request.url
        else { return }
        _ = ServerRoute.fallBack(from: ServerRoute.resolve(url), after: error)
    }
}

/// Capture the account before Nuke's asynchronous authorization hook; a
/// callback from a retired pipeline must never acquire a later account token.
private nonisolated final class AccountImageDataLoader: DataLoading {
    let client: ImoraClient?
    let owner: AuthorizingDelegate
    let binding: MediaRequestBinding?
    let demandKey: String?
    let priority: ThumbnailDemandPriority
    init(client: ImoraClient?, owner: AuthorizingDelegate, binding: MediaRequestBinding?,
         demandKey: String?, priority: ThumbnailDemandPriority) {
        self.client = client; self.owner = owner; self.binding = binding
        self.demandKey = demandKey; self.priority = priority
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        let id = UUID(), owner = owner, client = client, binding = binding, demandKey = demandKey, priority = priority
        let task = owner.networkTasks.withLock { values in
            let task = Task {
                defer { owner.networkTasks.withLock { _ = $0.removeValue(forKey: id) } }
                do {
                    try Task.checkCancellation()
                    guard let client, owner.client.withLock({ $0 === client }),
                          binding?.isCurrent != false,
                          request.value(forHTTPHeaderField: "Authorization") == "Bearer \(client.accessToken)" else {
                        throw ServerTrustError.sessionExpired
                    }
                    let permit = try await ThumbnailDemandScheduler.shared.acquire(priority: priority, key: demandKey)
                    defer { Task { await ThumbnailLoadLimiter.shared.release(permit) } }
                    try Task.checkCancellation()
                    let (data, response) = try await client.imageData(for: request)
                    guard owner.client.withLock({ $0 === client }), binding?.isCurrent != false else { throw ServerTrustError.sessionExpired }
                    didReceiveData(data, response)
                    completion(nil)
                } catch {
                    if case ImoraError.http(let code, _) = error, code == 401 || code == 403,
                       let client, let lease = binding?.privateLease { client.rejectLockedMediaLease(lease) }
                    completion(error)
                }
            }
            values[id] = .init(task: task, binding: binding)
            return task
        }
        return ImageTransfer(task: task)
    }

    private struct ImageTransfer: Cancellable {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}
