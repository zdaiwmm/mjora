import Foundation
import Photos
import SwiftUI

/// async image with thumbhash placeholder and downsampled decoding.
/// memory-cached images render on the first frame, and fast loads skip the
/// fade so cells never flicker when they scroll back into view.
struct RemoteImage: View {
    @Environment(SessionStore.self) private var session: SessionStore?
    let url: URL
    var targetPixelSize: CGFloat = 320
    var thumbhash: String?
    var placeholderImage: UIImage?
    var fallbackURL: URL?
    var fallbackTargetPixelSize: CGFloat?
    var upgradeURL: URL?
    var assetAspectRatio: Double = 1
    var contentMode: ContentMode = .fill
    /// false while the grid moves too fast for a fade per arriving tile to
    /// read as anything but flicker. the thumbhash step goes with it.
    var animatesLoads = true
    var onImage: ((UIImage) -> Void)?
    var onReady: (() -> Void)?
    var onBoundImage: ((BoundRemoteImage) -> Void)?

    @State private var image: KeyedImage?
    @State private var placeholder: KeyedImage?
    @State private var fallbackImage: KeyedImage?
    @State private var failedKey: String?
    @State private var retryAttempt = 0

    private struct KeyedImage {
        let key: String
        let image: UIImage
        var bound: BoundRemoteImage? = nil
    }

    private var requestKey: String {
        ImageLoader.shared.requestKey(for: url, targetPixelSize: targetPixelSize)
    }

    private var fallbackPixelSize: CGFloat {
        fallbackTargetPixelSize ?? targetPixelSize
    }

    /// walked in priority order and stopped at the first hit, so a tile already
    /// holding its image never touches the pipeline cache: the lookup builds a
    /// request and takes the cache's lock, and a grid runs it once per tile per
    /// pass.
    private func readyImage(key: String) -> UIImage? {
        if let image, image.key == key { return image.image }
        if let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) {
            return cached
        }
        if let fallbackImage, fallbackImage.key == key { return fallbackImage.image }
        if let fallbackURL,
           let cached = ImageLoader.shared.cachedImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) {
            return cached
        }
        return nil
    }

    private func displayImage(key: String, allowsExternalPlaceholder: Bool) -> UIImage? {
        if let ready = readyImage(key: key) { return ready }
        if allowsExternalPlaceholder, let placeholderImage { return placeholderImage }
        if let placeholder, placeholder.key == key { return placeholder.image }
        return nil
    }

    private func readyBoundImage(key: String) -> BoundRemoteImage? {
        if let image, image.key == key { return image.bound }
        if let cached = ImageLoader.shared.cachedBoundImage(for: url, targetPixelSize: targetPixelSize) { return cached }
        if let fallbackImage, fallbackImage.key == key { return fallbackImage.bound }
        if let fallbackURL { return ImageLoader.shared.cachedBoundImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) }
        return nil
    }

    /// the smaller render of the same photo is on screen, so the full one
    /// replaces a picture rather than a placeholder.
    private func showsFallback(key: String) -> Bool {
        if placeholderImage != nil { return true }
        if let fallbackImage, fallbackImage.key == key { return true }
        guard let fallbackURL else { return false }
        return ImageLoader.shared.cachedImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) != nil
    }

    private func signalReady(_ image: UIImage) {
        onImage?(image)
        onReady?()
    }

    var body: some View {
        // one string build per pass instead of the five the computed keys used
        // to cost; a grid tile's key is a full url and this is its hot path.
        let isPrivate = ImageLoader.shared.requiresPrivateLease(for: url, targetPixelSize: targetPixelSize)
        // Only private images observe this generation. A newer independent
        // status must invalidate a mounted E1 image even if its denial's
        // notification was superseded by the E2 producer.
        let privateGeneration = isPrivate ? session?.lockedFolder?.publicationGeneration : nil
        let lease = isPrivate ? session?.client?.lockedMediaLease : nil
        let mayPresent = !isPrivate || lease != nil
        let key = requestKey
        let taskID = "\(key)|\(thumbhash ?? "")|\(ImageLoadRecovery.shared.generation)|\(retryAttempt)|\(privateGeneration.map(String.init) ?? "")"

        ZStack {
            if mayPresent, let displayImage = displayImage(key: key, allowsExternalPlaceholder: !isPrivate) {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // swiftui does not animate an image content swap on its
                    // own, so without this the slow-path fade below lands as
                    // a hard cut when the sharper render arrives.
                    .contentTransition(.opacity)
                    .onChange(of: ObjectIdentifier(displayImage), initial: true) { _, _ in
                        guard let bound = readyBoundImage(key: key), bound.image === displayImage, bound.isCurrent else { return }
                        onBoundImage?(bound)
                    }
            } else {
                Color(.secondarySystemFill)
            }
        }
        .overlay {
            if failedKey == key {
                Button { failedKey = nil; retryAttempt &+= 1 } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(String(localized: "Retry"))
            }
        }
        .onAppear {
            if mayPresent, let image = readyImage(key: key) { signalReady(image) }
        }
        .task(id: taskID) {
            guard mayPresent else { return }
            guard image?.key != key else { return }
            if upgradeURL == nil, let cached = ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) {
                let bound = onBoundImage == nil ? nil : ImageLoader.shared.cachedBoundImage(for: url, targetPixelSize: targetPixelSize)
                image = KeyedImage(key: requestKey, image: cached, bound: bound?.image === cached ? bound : nil)
                signalReady(cached)
                return
            }

            let key = requestKey
            let start = ContinuousClock.now
            let loaded: UIImage
            var bound: BoundRemoteImage?
            do {
                if let upgradeURL {
                    loaded = try await ImageLoader.shared.gridThumbnail(
                        thumbnailURL: url, previewURL: upgradeURL,
                        targetPixelSize: targetPixelSize, aspectRatio: assetAspectRatio
                    ) { preview in
                        guard key == requestKey, !isPrivate || lease?.isCurrent == true else { return }
                        fallbackImage = KeyedImage(key: key, image: preview)
                    }
                } else {
                    if onBoundImage != nil {
                        let result = try await ImageLoader.shared.boundImage(for: url, targetPixelSize: targetPixelSize)
                        loaded = result.image; bound = result
                    } else {
                        loaded = try await ImageLoader.shared.image(for: url, targetPixelSize: targetPixelSize)
                    }
                }
            } catch {
                if !Task.isCancelled { failedKey = key }
                return
            }
            guard !Task.isCancelled, key == requestKey, !isPrivate || lease?.isCurrent == true else { return }
            failedKey = nil
            let keyed = KeyedImage(key: key, image: loaded, bound: bound)

            // a fade only earns its place over a flat placeholder: over the
            // smaller render of the same photo it reads as a pulse, and in a
            // fast fling every arriving tile pulsing reads as flicker.
            if !animatesLoads
                || showsFallback(key: key)
                || ContinuousClock.now - start < .milliseconds(120) {
                image = keyed
                signalReady(loaded)
            } else {
                withAnimation(
                    .easeIn(duration: 0.15),
                    completionCriteria: .logicallyComplete
                ) {
                    image = keyed
                } completion: {
                    signalReady(loaded)
                }
            }
        }
        .task(id: taskID) {
            guard mayPresent, !isPrivate, animatesLoads, let thumbhash, placeholder?.key != key else { return }
            // disk hits normally finish before this delay, avoiding placeholder
            // work for images that would never display it.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled,
                  image?.key != key,
                  ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) == nil
            else { return }
            let decodeTask = Task.detached(priority: .utility) {
                Thumbhash.image(fromBase64: thumbhash)
            }
            let decoded = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard !Task.isCancelled, image?.key != key, let decoded else { return }
            placeholder = KeyedImage(key: key, image: decoded)
        }
        // the smaller render of the same photo - the one the grid showed - is
        // usually a disk cache hit, so it paints the view while the full size
        // is still on the wire instead of leaving a flat placeholder.
        .task(id: taskID) {
            guard mayPresent, let fallbackURL, image?.key != requestKey else { return }
            let key = requestKey
            guard ImageLoader.shared.cachedImage(for: url, targetPixelSize: targetPixelSize) == nil,
                  ImageLoader.shared.cachedImage(for: fallbackURL, targetPixelSize: fallbackPixelSize) == nil
            else { return }
            let bound = onBoundImage == nil ? nil : (try? await ImageLoader.shared.boundImage(for: fallbackURL, targetPixelSize: fallbackPixelSize))
            let loaded: UIImage?
            if onBoundImage != nil { loaded = bound?.image }
            else { loaded = try? await ImageLoader.shared.image(for: fallbackURL, targetPixelSize: fallbackPixelSize) }
            guard !Task.isCancelled, key == requestKey, !isPrivate || lease?.isCurrent == true,
                  let loaded, image?.key != key else { return }
            fallbackImage = KeyedImage(key: key, image: loaded, bound: bound)
            signalReady(loaded)
        }
    }
}

/// async device-library thumbnail, the photokit sibling of remoteimage.
struct LocalPhotoImage: View {
    let localIdentifier: String
    var targetPixelSize: CGFloat = 640
    var cacheScope: String = ""
    /// smaller render of the same asset, taken from the cache only. the viewer
    /// points it at the grid's size so a page opens on the tile's pixels
    /// instead of a placeholder while photokit produces the big one.
    var fallbackTargetPixelSize: CGFloat?
    var fallbackRequestContentMode: PHImageContentMode = .aspectFill
    var loadsFallbackIfNeeded = false
    var requestContentMode: PHImageContentMode = .aspectFill
    /// true for grid tiles: the fit render is asked for at the tile's size on
    /// its short side, so it still fills the square without a crop.
    var coversTarget = false
    var contentMode: ContentMode = .fill
    /// false when the host has a server copy to fall back on: a paired asset
    /// whose sharp render sits in icloud then shows the server thumbnail
    /// instead of pulling the original down in the middle of a scroll.
    var allowsNetwork = true
    /// the asset's own aspect ratio, for hosts that frame the image by it.
    /// photokit's stored preview can be a different crop of the picture, and
    /// filling such a frame with one reads as a zoom that snaps back when the
    /// render lands, so a preview that disagrees with it is skipped.
    var expectedAspectRatio: Double?
    /// false while the grid moves too fast for a fade per arriving tile to
    /// read as anything but flicker.
    var animatesLoads = true
    /// a picture of the same asset the host already had on screen - the
    /// server thumbnail a tile painted before the backup index paired it -
    /// shown until photokit answers, so the swap never passes through grey.
    var placeholderImage: UIImage?
    /// photokit could not produce the asset - it was deleted from the library
    /// behind our back, or is an icloud original that will not download. hosts
    /// use this to fall back to the server copy instead of showing nothing.
    var onUnavailable: (() -> Void)?
    var onImage: ((UIImage) -> Void)?
    var onReady: (() -> Void)?

    @State private var failedKey: String?
    @State private var retryAttempt = 0
    @State private var image: KeyedImage?
    @State private var fallbackImage: KeyedImage?
    /// photokit's stored thumbnail, on screen only until something sharper is
    /// held for the same key.
    @State private var previewImage: KeyedImage?

    private struct KeyedImage {
        let key: String
        let image: UIImage
    }

    private var requestKey: String {
        "\(cacheScope)|\(localIdentifier)#\(Int(targetPixelSize))#\(requestContentMode.rawValue)\(coversTarget ? "#cover" : "")"
    }

    private var fallbackKey: String? {
        guard let fallbackTargetPixelSize else { return nil }
        return "\(cacheScope)|\(localIdentifier)#\(Int(fallbackTargetPixelSize))#\(fallbackRequestContentMode.rawValue)"
    }

    private var cachedFallback: UIImage? {
        guard let fallbackTargetPixelSize else { return nil }
        return LocalImageLoader.shared.cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: fallbackTargetPixelSize,
            contentMode: fallbackRequestContentMode,
            cacheScope: cacheScope
        )
    }

    /// a preview or a smaller render of the same picture is on screen, so the
    /// sharp render replaces a picture rather than a placeholder.
    private func showsSamePicture(key: String) -> Bool {
        if previewImage?.key == key || placeholderImage != nil { return true }
        if let fallbackKey, fallbackImage?.key == fallbackKey { return true }
        return cachedFallback != nil
    }

    private func readyImage(key: String) -> UIImage? {
        if let image, image.key == key { return image.image }
        if let cached = LocalImageLoader.shared.cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: targetPixelSize,
            contentMode: requestContentMode,
            coversTarget: coversTarget,
            cacheScope: cacheScope
        ) {
            return cached
        }
        if let fallbackKey, let fallbackImage, fallbackImage.key == fallbackKey {
            return fallbackImage.image
        }
        return cachedFallback
    }

    private func signalReady(_ image: UIImage) {
        onImage?(image)
        onReady?()
    }

    private func availablePreview(key: String) -> UIImage? {
        if let previewImage, previewImage.key == key { return previewImage.image }
        guard let cached = LocalImageLoader.shared.cachedPreview(localIdentifier: localIdentifier, cacheScope: cacheScope),
              Self.accepts(cached, aspectRatio: expectedAspectRatio) else { return nil }
        return cached
    }

    private static func accepts(_ preview: UIImage, aspectRatio: Double?) -> Bool {
        guard let aspectRatio, aspectRatio > 0, preview.size.height > 0 else { return true }
        let previewRatio = Double(preview.size.width / preview.size.height)
        return abs(previewRatio - aspectRatio) <= aspectRatio * 0.03
    }

    var body: some View {
        let key = requestKey
        let recoveryGeneration = ImageLoadRecovery.shared.generation
        // the photokit cache is only consulted when this view is not already
        // holding the render, the same short circuit remoteimage takes.
        let display = (image?.key == key ? image?.image : nil)
            ?? LocalImageLoader.shared.cachedImage(
                localIdentifier: localIdentifier,
                targetPixelSize: targetPixelSize,
                contentMode: requestContentMode,
                coversTarget: coversTarget,
            cacheScope: cacheScope
            )
            ?? (fallbackImage?.key == fallbackKey ? fallbackImage?.image : nil)
            ?? cachedFallback
            ?? placeholderImage
            ?? availablePreview(key: key)
        ZStack {
            if let display {
                Image(uiImage: display)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // same as remoteimage: makes the slow-path fade real
                    // instead of a hard cut on the content swap.
                    .contentTransition(.opacity)
            } else {
                Color(.secondarySystemFill)
            }
        }
        .overlay {
            if failedKey == key {
                Button { failedKey = nil; retryAttempt &+= 1 } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(String(localized: "Retry"))
            }
        }
        .onAppear {
            if display != nil { onReady?() }
            if let image = readyImage(key: key) { onImage?(image) }
        }
        .task(id: "\(key)|\(allowsNetwork)|\(recoveryGeneration)|\(retryAttempt)") {
            guard image?.key != key else { return }
            let start = ContinuousClock.now
            var receivedFinal = false
            var shouldTryAlternateSource = false
            let deliveries = LocalImageLoader.shared.deliveries(
                localIdentifier: localIdentifier,
                targetPixelSize: targetPixelSize,
                contentMode: requestContentMode,
                coversTarget: coversTarget,
                allowsNetwork: allowsNetwork,
                cacheScope: cacheScope
            )
            for await delivery in deliveries {
                guard !Task.isCancelled else { return }
                switch delivery {
                case .terminal(let outcome):
                    shouldTryAlternateSource = outcome.shouldTryAlternateSource
                case .preview(let preview):
                    // the library's own thumbnail: paints at once, no fade,
                    // and never counts as ready - hosts wait for the render.
                    if Self.accepts(preview, aspectRatio: expectedAspectRatio) {
                        previewImage = KeyedImage(key: key, image: preview)
                    }
                case .final(let loaded):
                    failedKey = nil
                    receivedFinal = true
                    let keyed = KeyedImage(key: key, image: loaded)
                    // the render lands in place whenever it replaces the same
                    // picture: fading one rendition into another reads as a
                    // glow. only a flat placeholder earns the fade, and only
                    // while the grid is slow enough for fades to read.
                    if !animatesLoads
                        || showsSamePicture(key: key)
                        || ContinuousClock.now - start < .milliseconds(120) {
                        image = keyed
                        signalReady(loaded)
                    } else {
                        withAnimation(
                            .easeIn(duration: 0.15),
                            completionCriteria: .logicallyComplete
                        ) {
                            image = keyed
                        } completion: {
                            signalReady(loaded)
                        }
                    }
                }
            }
            guard !Task.isCancelled, !receivedFinal, shouldTryAlternateSource else { return }
            failedKey = key
            onUnavailable?()
        }
        .task(id: "\(fallbackKey ?? "")|\(recoveryGeneration)") {
            guard loadsFallbackIfNeeded,
                  let fallbackTargetPixelSize,
                  let fallbackKey,
                  image?.key != key,
                  fallbackImage?.key != fallbackKey,
                  LocalImageLoader.shared.cachedImage(
                      localIdentifier: localIdentifier,
                      targetPixelSize: targetPixelSize,
                      contentMode: requestContentMode,
                      coversTarget: coversTarget,
            cacheScope: cacheScope
                  ) == nil,
                  LocalImageLoader.shared.cachedImage(
                      localIdentifier: localIdentifier,
                      targetPixelSize: fallbackTargetPixelSize,
                      contentMode: fallbackRequestContentMode,
            cacheScope: cacheScope
                  ) == nil
            else { return }
            let loaded = await LocalImageLoader.shared.image(
                localIdentifier: localIdentifier,
                targetPixelSize: fallbackTargetPixelSize,
                contentMode: fallbackRequestContentMode,
            cacheScope: cacheScope
            )
            guard !Task.isCancelled, let loaded, image?.key != key else { return }
            fallbackImage = KeyedImage(key: fallbackKey, image: loaded)
            signalReady(loaded)
        }
    }
}

/// what a grid is doing, for its tiles: a fling fast enough that a fade per
/// arriving thumbnail reads as flicker turns the fades off. observable so only
/// the tiles re-render when it flips, a couple of times per fling.
@Observable @MainActor
final class GridMotion {
    var isFast = false
}

private struct SquareTileFrame: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.aspectRatio(1, contentMode: .fit)
        } else {
            content
        }
    }
}

/// square grid tile for an asset, with video, favorite and backup badges.
struct AssetTile: View {
    @Environment(SessionStore.self) private var session
    /// present inside grids that report their motion; other hosts fade as
    /// usual.
    @Environment(GridMotion.self) private var motion: GridMotion?
    let asset: Asset
    /// backup status in the corner plus the upload progress overlay. only
    /// the main timeline shows these, matching the official client.
    var showsBackupBadge = false
    var showsAllBackupStatuses = false
    var targetPixelSize: CGFloat = 640
    /// false lets the host pick the frame and drops the corner badges, for
    /// strips too small to carry them.
    var isGridTile = true

    /// set when photokit cannot serve the paired device copy, so the tile
    /// stops asking and renders the server thumbnail instead.
    @State private var unavailableLocalIdentifier: String?
    @State private var unavailableGeneration = -1
    @State private var remoteFallbackVisible = false
    @State private var localReady = false

    /// the device copy is free, already decoded by photokit and needs no
    /// network, so it wins whenever the backup index pairs one with this
    /// asset. edited server copies are excluded from that map.
    private var thumbnailSource: AssetThumbnailSource {
        AssetThumbnailSource(
            assetID: asset.id,
            localIdentifier: asset.localIdentifier,
            pairedLocalIdentifier: session.backup?.localIdentifierByRemoteId[asset.id],
            pairedRemoteIdentifier: asset.localIdentifier.flatMap {
                session.backup?.remoteIdentifierByLocalId[$0]
            },
            unavailableLocalIdentifier: unavailableGeneration == ImageLoadRecovery.shared.generation
                ? unavailableLocalIdentifier : nil,
            isEdited: asset.isEdited == true
        )
    }

    /// the server thumbnail already in memory for a paired asset. a tile that
    /// painted it before the backup index landed keeps showing it while
    /// photokit answers, so the swap to the device render never passes
    /// through grey or a fade between two renditions of the same picture.
    private func serverThumbnail(client: ImoraClient, source: AssetThumbnailSource) -> UIImage? {
        guard let serverIdentifier = source.remoteIdentifier else { return nil }
        return ImageLoader.shared.cachedImage(
            for: client.thumbnailURL(assetID: serverIdentifier, cacheKey: asset.thumbhash),
            targetPixelSize: targetPixelSize
        )
    }

    private func localThumbnail(_ localId: String, source: AssetThumbnailSource,
                                animatesLoads: Bool, recoveryGeneration: Int) -> some View {
        LocalPhotoImage(
            localIdentifier: localId,
            targetPixelSize: targetPixelSize,
            cacheScope: AssetThumbnailSource.localCacheScope(accountKey: session.client?.offlineAccountKey, version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize),
            requestContentMode: DeviceTileRender.contentMode,
            coversTarget: DeviceTileRender.coversTile,
            // Grid loads stay on-device; cloud-only originals
            // keep their preview and expose a retry control.
            allowsNetwork: false,
            animatesLoads: animatesLoads,
            placeholderImage: session.client.flatMap { serverThumbnail(client: $0, source: source) },
            onUnavailable: {
                remoteFallbackVisible = source.remoteIdentifier != nil
            },
            onImage: { _ in localReady = true; remoteFallbackVisible = false }
        )
        .overlay {
            if remoteFallbackVisible, !localReady, let client = session.client,
               let remoteID = source.remoteIdentifier {
                RemoteImage(
                    url: client.thumbnailURL(assetID: remoteID, cacheKey: asset.thumbhash),
                    targetPixelSize: targetPixelSize, thumbhash: asset.thumbhash,
                    placeholderImage: LocalImageLoader.shared.cachedPreview(localIdentifier: localId,
                        cacheScope: AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey, version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize)),
                    upgradeURL: client.thumbnailURL(assetID: remoteID, size: "preview", cacheKey: asset.thumbhash),
                    assetAspectRatio: asset.ratio, animatesLoads: animatesLoads
                )
            }
        }
        .task(id: "\(asset.id)|\(localId)|\(Int(targetPixelSize))|\(asset.localImageVersion ?? asset.thumbhash ?? "")|\(session.client?.offlineAccountKey ?? "device")|\(recoveryGeneration)") {
            localReady = LocalImageLoader.shared.cachedImage(
                localIdentifier: localId, targetPixelSize: targetPixelSize,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                cacheScope: AssetThumbnailSource.localCacheScope(accountKey: session.client?.offlineAccountKey, version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize)
            ) != nil
            remoteFallbackVisible = false
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !localReady, source.remoteIdentifier != nil else { return }
            remoteFallbackVisible = true
        }
    }

    var body: some View {
        let animatesLoads = motion?.isFast != true
        let recoveryGeneration = ImageLoadRecovery.shared.generation
        let source = thumbnailSource
        Color.clear
            .modifier(SquareTileFrame(isActive: isGridTile))
            .overlay {
                if let localId = source.preferredLocalIdentifier {
                    // the uncropped render the viewer opens on, cropped by the
                    // tile's own frame, so opening never swaps one crop for
                    // another.
                    localThumbnail(localId, source: source, animatesLoads: animatesLoads,
                                   recoveryGeneration: recoveryGeneration)
                } else if let client = session.client, let serverIdentifier = source.remoteIdentifier {
                    RemoteImage(
                        url: client.thumbnailURL(assetID: serverIdentifier, cacheKey: asset.thumbhash),
                        targetPixelSize: targetPixelSize,
                        thumbhash: asset.thumbhash,
                        placeholderImage: source.localIdentifier.flatMap {
                            LocalImageLoader.shared.cachedPreview(localIdentifier: $0)
                        },
                        upgradeURL: client.thumbnailURL(assetID: serverIdentifier, size: "preview", cacheKey: asset.thumbhash),
                        assetAspectRatio: asset.ratio,
                        animatesLoads: animatesLoads
                    )
                }
            }
            .clipShape(.rect(cornerRadius: isGridTile ? 2 : 0))
            .overlay(alignment: .topTrailing) {
                if isGridTile, let duration = asset.durationLabel {
                    Label(duration, systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: .capsule)
                        .padding(5)
                } else if isGridTile, asset.isLivePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(7)
                }
            }
            .overlay(alignment: .topLeading) {
                if isGridTile, asset.isStacked, let count = asset.stackCount {
                    Label("\(count)", systemImage: "square.stack.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: .capsule)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isGridTile, asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBackupBadge, showsAllBackupStatuses || isCloudDeleted { backupBadge }
            }
            .overlay {
                if showsBackupBadge, showsAllBackupStatuses || uploadState == .failed { uploadOverlay }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("asset-tile")
    }

    private var accessibilitySummary: String {
        var parts = [
            asset.isVideo ? String(localized: "Video") : (asset.isLivePhoto ? String(localized: "Live Photo") : String(localized: "Photo")),
            PhotoDatePresentation.dateTime(wallClock: asset.localDate),
        ]
        if let duration = asset.durationLabel { parts.append(duration) }
        if asset.isStacked, let count = asset.stackCount { parts.append(String(localized: "Stack of \(count)")) }
        if asset.isFavorite { parts.append(String(localized: "Favorite")) }
        if showsBackupBadge { parts.append(backupAccessibilitySummary) }
        return parts.joined(separator: ", ")
    }

    private var backupAccessibilitySummary: String {
        if isCloudDeleted { return String(localized: "Deleted in Cloud") }
        if hasVerifiedLocalBackup { return String(localized: "Backed up") }
        switch uploadState {
        case .uploading(let fraction):
            return String(localized: "Backing up, \(Int(fraction * 100)) percent")
        case .failed:
            return String(localized: "Backup failed")
        case nil:
            if asset.isLocal {
                return isExcludedBySize ? String(localized: "Excluded from backup by the upload size limit") : String(localized: "Not backed up")
            }
            return session.backup?.backedUpRemoteIds.contains(asset.id) == true
                ? String(localized: "Backed up") : String(localized: "Stored in cloud")
        }
    }

    // MARK: - backup status

    private var isCloudDeleted: Bool {
        guard let id = asset.localIdentifier else { return false }
        return session.backup?.remoteRemovedLocalIDs.contains(id) == true
    }

    private var uploadState: LocalUploadState? {
        guard !isCloudDeleted, let localId = asset.localIdentifier else { return nil }
        return session.backup?.uploadStates[localId]
    }

    private var hasVerifiedLocalBackup: Bool {
        guard !isCloudDeleted, asset.isLocal, let localId = asset.localIdentifier else { return false }
        return asset.isLocalBackedUp
            || session.backup?.hasVerifiedBackup(localIdentifier: localId) == true
    }

    private var isExcludedBySize: Bool {
        guard let localId = asset.localIdentifier else { return false }
        return session.backup?.sizeExcludedLocalIdentifiers.contains(localId) == true
    }

    @ViewBuilder private var backupBadge: some View {
        if isCloudDeleted {
            Image(systemName: "icloud.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.gray)
                .shadow(color: .black.opacity(0.6), radius: 2.5)
                .padding(6)
                .accessibilityIdentifier("badge-cloud-deleted")
        } else if hasVerifiedLocalBackup {
            badgeIcon("checkmark.icloud")
        } else if uploadState == nil {
            if asset.isLocal {
                badgeIcon(isExcludedBySize ? "minus.circle" : "icloud.slash")
            } else if session.backup?.backedUpRemoteIds.contains(asset.id) == true {
                badgeIcon("checkmark.icloud")
            } else {
                badgeIcon("icloud")
            }
        }
    }

    private func badgeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2.5)
            .padding(6)
            .accessibilityIdentifier("badge-\(name)")
    }

    @ViewBuilder private var uploadOverlay: some View {
        if !hasVerifiedLocalBackup {
            switch uploadState {
            case .uploading(let fraction):
                ZStack {
                    Color.black.opacity(0.54)
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.24), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: max(0.03, fraction))
                                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: fraction)
                        }
                        .frame(width: 36, height: 36)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
            case .failed:
                ZStack {
                    Color.black.opacity(0.58)
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                        Text("Error")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            case nil:
                EmptyView()
            }
        }
    }
}
