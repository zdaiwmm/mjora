import ImageIO
import Nuke
import Synchronization
import UIKit

/// downloads and caches asset thumbnails on top of a nuke pipeline. beyond the
/// memory and disk caches, the library brings request coalescing, a rate
/// limiter tuned for fast scrolling, resumable downloads and the prefetcher
/// the grids use to load tiles before they come on screen.
nonisolated final class ImageLoader: Sendable {
    static let shared = ImageLoader()

    private let pipeline: ImagePipeline
    private let visibleTasks = Mutex<[UUID: ImageTask]>([:])
    private let authorization = AuthorizingDelegate()
    private let prefetcher: ImagePrefetcher
    /// fills the disk cache only. a fling usually races past what sits far
    /// ahead, so those tiles are fetched but never decoded until they show.
    private let diskPrefetcher: ImagePrefetcher
    /// held directly so storage settings can measure and wipe it.
    private let dataCache: DataCache?

    private init() {
        // an aggressive data cache instead of urlcache: immich thumbnails are
        // immutable per cache key, so revalidating them is wasted latency.
        let dataCache = try? DataCache(name: "imora-images")
        dataCache?.sizeLimit = 1 << 30
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
        prefetcher = ImagePrefetcher(pipeline: pipeline, maxConcurrentRequestCount: 4)
        diskPrefetcher = ImagePrefetcher(pipeline: pipeline, destination: .diskCache, maxConcurrentRequestCount: 2)
    }

    /// call after login so image requests carry the token.
    func configure(client: ImoraClient?) {
        authorization.client.withLock { $0 = nil }
        sweepTask.withLock { current in current?.cancel(); current = nil }
        prefetcher.stopPrefetching()
        diskPrefetcher.stopPrefetching()
        visibleTasks.withLock { tasks in tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
        authorization.networkTasks.withLock { tasks in
            tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        }
        pipeline.cache.removeAll()
        authorization.ephemeralAssetIDs.withLock { $0.removeAll() }
        authorization.client.withLock { $0 = client }
    }

    /// keeps these assets' bytes out of the disk cache from now on. the
    /// locked folder registers its assets so the pin protects them at rest.
    func markEphemeral(assetIDs: [String]) {
        authorization.ephemeralAssetIDs.withLock { $0.formUnion(assetIDs) }
    }

    func requestKey(for url: URL, targetPixelSize: CGFloat) -> String {
        "\(url.absoluteString)#\(Self.normalizedPixelSize(targetPixelSize, for: url))"
    }

    func cachedImage(for url: URL, targetPixelSize: CGFloat) -> UIImage? {
        pipeline.cache[request(for: url, targetPixelSize: targetPixelSize)]?.image
    }

    func image(for url: URL, targetPixelSize: CGFloat) async throws -> UIImage {
        var request = request(for: url, targetPixelSize: targetPixelSize)
        // a tile on screen beats every prefetch and sweep request queued
        // ahead of it; those run low and very low.
        request.priority = .high
        guard let client = authorization.client.withLock({ $0 }) else { throw ServerTrustError.sessionExpired }
        _ = try client.authorizedRequest(url: url)
        let id = UUID()
        let task = pipeline.imageTask(with: request)
        visibleTasks.withLock { $0[id] = task }
        defer { visibleTasks.withLock { _ = $0.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            let image = try await task.image
            guard client.context.isActive, authorization.client.withLock({ $0 === client }) else { throw ServerTrustError.sessionExpired }
            return image
        } onCancel: { task.cancel() }
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
        var state = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: Double(targetPixelSize))
        let ratio = max(0.01, aspectRatio)
        for (url, isPreview) in [(thumbnailURL, false), (previewURL, true)] {
            try Task.checkCancellation()
            guard initialClient.context.isActive, authorization.client.withLock({ $0 === initialClient }) else {
                throw ServerTrustError.sessionExpired
            }
            let size = isPreview ? targetPixelSize * max(ratio, 1 / ratio) : targetPixelSize
            do {
                let loaded = try await image(for: url, targetPixelSize: size)
                try Task.checkCancellation()
                let pixels = Double(min(loaded.size.width, loaded.size.height) * loaded.scale)
                if state.remoteResult(pixels: pixels, isPreview: isPreview) == .finished { return loaded }
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
    func startPrefetching(urls: [URL], targetPixelSize: CGFloat) {
        prefetcher.startPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    func stopPrefetching(urls: [URL], targetPixelSize: CGFloat) {
        prefetcher.stopPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    /// downloads to the disk cache without decoding, for tiles further out.
    func startPrefetchingData(urls: [URL]) {
        diskPrefetcher.startPrefetching(with: urls)
    }

    func stopPrefetchingData(urls: [URL]) {
        diskPrefetcher.stopPrefetching(with: urls)
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
                        var request = ImageRequest(url: url)
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

    /// decoding straight to a thumbnail keeps memory flat while scrolling -
    /// the full-size bitmap never exists.
    private func request(for url: URL, targetPixelSize: CGFloat) -> ImageRequest {
        var request = ImageRequest(url: url)
        let maxPixelSize = Self.normalizedPixelSize(targetPixelSize, for: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: Float(maxPixelSize))
        request.userInfo[FittingThumbnailDecoder.maxPixelSizeKey] = maxPixelSize
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
    let networkTasks = Mutex<[UUID: Task<Void, Never>]>([:])

    nonisolated func dataLoader(for request: ImageRequest, pipeline: ImagePipeline) -> any DataLoading {
        AccountImageDataLoader(client: client.withLock { $0 }, owner: self)
    }

    /// nuke asks before every disk read and write; nil keeps a locked asset
    /// memory only.
    nonisolated func dataCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any DataCaching)? {
        if let id = Self.assetID(in: request.url), ephemeralAssetIDs.withLock({ $0.contains(id) }) {
            return nil
        }
        return pipeline.configuration.dataCache
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
        var urlRequest = urlRequest
        urlRequest.url = urlRequest.url.map(ServerRoute.resolve)
        guard let client = client.withLock({ $0 }), let url = urlRequest.url else { throw ServerTrustError.sessionExpired }
        return try client.authorizedRequest(url: url)
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
    init(client: ImoraClient?, owner: AuthorizingDelegate) { self.client = client; self.owner = owner }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        let id = UUID(), owner = owner, client = client
        let task = owner.networkTasks.withLock { values in
            let task = Task {
                defer { owner.networkTasks.withLock { _ = $0.removeValue(forKey: id) } }
                do {
                    try Task.checkCancellation()
                    guard let client, owner.client.withLock({ $0 === client }),
                          request.value(forHTTPHeaderField: "Authorization") == "Bearer \(client.accessToken)" else {
                        throw ServerTrustError.sessionExpired
                    }
                    let permit = try await ThumbnailLoadLimiter.shared.acquire()
                    defer { Task { await ThumbnailLoadLimiter.shared.release(permit) } }
                    try Task.checkCancellation()
                    let (data, response) = try await client.imageData(for: request)
                    guard owner.client.withLock({ $0 === client }) else { throw ServerTrustError.sessionExpired }
                    didReceiveData(data, response)
                    completion(nil)
                } catch { completion(error) }
            }
            values[id] = task
            return task
        }
        return ImageTransfer(task: task)
    }

    private struct ImageTransfer: Cancellable {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}
