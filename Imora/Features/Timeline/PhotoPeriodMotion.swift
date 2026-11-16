import Photos
import SwiftUI
import UIKit

/// A single image travels between real card/tile frames. It adds no recognizers,
/// so the grid's continuous pinch and the viewer keep their gesture ownership.
@MainActor
final class PhotoPeriodMotion {
    static let replicaTag = 0xF0123
    private final class Surface {
        weak var view: PeriodPhotoImageView?
        weak var image: UIImage?
        let key: MediaDisplayKeyV1
        let access: MediaAccessGeneration
        init(_ view: PeriodPhotoImageView, prepared: CommittedGridSurface) {
            self.view = view; image = prepared.image; key = prepared.key; access = prepared.access
        }
    }
    var reducesMotion = false
    private var surfaces: [PhotoBrowseMode: [String: Surface]] = [:]
    private var animator: UIViewPropertyAnimator?
    private var replica: UIView?
    private var activeSurface: CommittedGridSurface?
    private weak var source: UIView?
    private weak var destination: UIView?
    private var sourceAlpha: CGFloat = 1
    private var destinationAlpha: CGFloat = 1
    private var timeout: Task<Void, Never>?
    private(set) var transitionID: UUID?
    private(set) var assetID: String?
    private var targetMode: PhotoBrowseMode?

    func register(_ view: PeriodPhotoImageView, assetID: String, mode: PhotoBrowseMode) {
        guard let prepared = view.registeredSurface else {
            if surfaces[mode]?[assetID]?.view === view { surfaces[mode]?[assetID] = nil }
            return
        }
        surfaces[mode, default: [:]][assetID] = Surface(view, prepared: prepared)
        guard self.assetID == assetID, targetMode == mode, animator == nil else { return }
        let ticket = transitionID
        Task { [weak self, weak view] in
            await Task.yield()
            guard let self, let view, self.transitionID == ticket else { return }
            self.arrive(at: view, mode: mode)
        }
    }

    func carriedSurface(for assetID: String) -> CommittedGridSurface? {
        guard self.assetID == assetID, activeSurface?.isCurrent() == true else { return nil }
        return activeSurface
    }

    func begin(assetID: String, from: PhotoBrowseMode, to: PhotoBrowseMode,
               gridSource: TimelineTileView?, session: SessionStore, reduceMotion: Bool) {
        // Carry the in-flight photo at its presentation frame into a reversal.
        let carriedSurface = self.assetID == assetID && activeSurface?.isCurrent() == true ? activeSurface : nil
        let carried = carriedSurface == nil ? nil : replica
        let carriedFrame = carried?.layer.presentation()?.frame ?? carried?.frame
        let carriedWindow = carried?.window
        if let carriedFrame { carried?.frame = carriedFrame }
        if let carried { carried.removeFromSuperview() }
        cancel()
        guard !reduceMotion else { return }
        let sourceView: UIView? = from == .all ? gridSource : surfaces[from]?[assetID]?.view
        let periodEntry = surfaces[from]?[assetID]
        let periodSurface = periodEntry.flatMap { entry -> CommittedGridSurface? in
            guard let image = entry.image, let current = entry.view?.preparedSurfaceForMotion(),
                  current.image === image, current.key == entry.key, current.access == entry.access else { return nil }
            return current
        }
        let prepared = carriedSurface ?? (from == .all ? gridSource?.preparedSurfaceForMotion() : periodSurface)
        guard let prepared, prepared.isCurrent(), let window = carriedWindow ?? sourceView?.window else { return }
        let imageView = carried ?? AssetViewerBoundImageView(surface: prepared, session: session,
            isPrivate: prepared.key.visibilityPolicy == "locked")
        let start = carriedFrame ?? sourceView.map { $0.convert($0.bounds, to: window) } ?? .zero
        guard start.width > 0, start.height > 0 else { return }
        let ticket = UUID()
        transitionID = ticket
        self.assetID = assetID
        targetMode = to
        replica = imageView
        activeSurface = prepared
        (imageView as? AssetViewerBoundImageView)?.onRetired = { [weak self, weak imageView] in
            guard let self, self.replica === imageView else { return }
            self.cancel()
        }
        source = sourceView
        sourceAlpha = sourceView?.alpha ?? 1
        sourceView?.alpha = 0
        imageView.frame = start
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = from == .all ? 2 : 10
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityElementsHidden = true
        imageView.tag = Self.replicaTag
        window.addSubview(imageView)
        timeout = Task { [self] in
            // Keep cleanup alive even if SwiftUI replaces the period owner.
            // cancel() breaks this bounded lifetime and removes the window view.
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard !Task.isCancelled, transitionID == ticket else { return }
            cancel()
        }
        if to != .all, let target = surfaces[to]?[assetID]?.view { register(target, assetID: assetID, mode: to) }
    }

    func arrive(at view: UIView, mode: PhotoBrowseMode) {
        guard targetMode == mode, animator == nil, let ticket = transitionID,
              let replica, let window = replica.window, view.window === window,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        let destinationSurface = (view as? TimelineTileView)?.preparedSurfaceForMotion()
            ?? (view as? PeriodPhotoImageView)?.preparedSurfaceForMotion()
        guard let sourceSurface = activeSurface, sourceSurface.isCurrent(),
              let destinationSurface, destinationSurface.isCurrent(),
              Self.matches(sourceSurface, destinationSurface) else { cancel(); return }
        view.superview?.layoutIfNeeded()
        let target = view.convert(view.bounds, to: window)
        guard target.intersects(window.bounds) else { return }
        destination = view
        destinationAlpha = view.alpha
        view.alpha = 0
        // Keep the same crop while the bounds change. UIImageView's default
        // scaleToFill stretched the travelling photo until the final handoff.
        replica.contentMode = .scaleAspectFill
        let animator = PhotosMotion.springAnimator(duration: PhotosMotion.layoutDuration) {
            replica.frame = target
            replica.layer.cornerRadius = mode == .all ? 2 : 10
        }
        self.animator = animator
        animator.addCompletion { [weak self] _ in
            guard self?.transitionID == ticket else { return }
            self?.cancel()
        }
        animator.startAnimation()
    }

    private static func matches(_ source: CommittedGridSurface, _ destination: CommittedGridSurface) -> Bool {
        let a = source.key, b = destination.key
        return source.access == destination.access && a.scope == b.scope && a.subject == b.subject
            && a.sourceRevision == b.sourceRevision && a.presentationRevision == b.presentationRevision
            && a.contentGeneration == b.contentGeneration && a.visibilityPolicy == b.visibilityPolicy
            && a.variant == b.variant && a.fitMode == b.fitMode
            && a.orientationRevision == b.orientationRevision && a.colorProfile == b.colorProfile
    }

    func cancel() {
        transitionID = nil
        timeout?.cancel()
        timeout = nil
        animator?.stopAnimation(true)
        animator = nil
        source?.alpha = sourceAlpha
        destination?.alpha = destinationAlpha
        source = nil
        destination = nil
        replica?.removeFromSuperview()
        replica = nil
        activeSurface = nil
        assetID = nil
        targetMode = nil
    }
}

struct PhotoPeriodCoverSurface: UIViewRepresentable {
    @Environment(\.displayScale) private var displayScale
    let asset: Asset
    let mode: PhotoBrowseMode
    let session: SessionStore
    let motion: PhotoPeriodMotion
    let size: CGSize
    var gridViewportWidth: CGFloat = 393
    var gridColumns = 3

    static func targetPixels(asset: Asset, size: CGSize, scale: CGFloat) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0,
              asset.ratio.isFinite, asset.ratio > 0 else { return 900 }
        let ratio = CGFloat(asset.ratio)
        let height = max(size.height, size.width / ratio) * scale
        let width = height * ratio
        // The local provider's covering target describes the short side;
        // ImageIO's remote thumbnail target describes the longest side.
        let dimension = asset.localIdentifier != nil && asset.visibility != .locked
            ? min(width, height) : max(width, height)
        return min(4096, max(32, (dimension / 32).rounded(.up) * 32))
    }

    func makeUIView(context: Context) -> PeriodPhotoImageView { PeriodPhotoImageView(frame: .zero) }
    func updateUIView(_ view: PeriodPhotoImageView, context: Context) {
        let gridSide = AssetGridLayout.tileSide(viewportWidth: gridViewportWidth, columns: gridColumns)
        let fallbackPixels = min(1280, (max(1, gridSide * displayScale) / 32).rounded(.up) * 32)
        view.configure(asset: asset, mode: mode, session: session, motion: motion,
                       targetPixelSize: Self.targetPixels(asset: asset, size: size, scale: displayScale),
                       fallbackPixelSize: fallbackPixels)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PeriodPhotoImageView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        // A decoded UIImage has its own intrinsic size. The real UIKit
        // transition surface and AX bounds must stay inside the day card.
        return CGSize(width: width, height: height)
    }
    static func dismantleUIView(_ view: PeriodPhotoImageView, coordinator: ()) { view.cancelLoad() }
}

final class PeriodPhotoImageView: UIImageView {
    private final class Lifetime { var current = true }
    private struct SourceIdentity: Equatable {
        let session: UUID?
        let assetID: String
        let localID: String?
        let localRevision: String?
        let thumbnailRevision: String?
        let visibility: String
        let isEdited: Bool?
        let isTrashed: Bool
        let ratio: UInt64
    }
    private struct Attempt: Equatable {
        let source: SourceIdentity
        let pixels: Int
        let recovery: Int
        let privateGeneration: Int?
    }
    private var load: Task<Void, Never>?
    private var key: Attempt?
    private var sourceIdentity: SourceIdentity?
    private var targetPixelSize: CGFloat = 900
    private var fallbackPixelSize: CGFloat?
    private var asset: Asset?
    private var mode: PhotoBrowseMode = .years
    private weak var motion: PhotoPeriodMotion?
    private weak var session: SessionStore?
    private var lifetime = Lifetime()
    private var boundSurface: CommittedGridSurface?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemBackground
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func cancelLoad() { load?.cancel(); load = nil }

    var registeredSurface: CommittedGridSurface? {
        guard let surface = boundSurface, image === surface.image else { return nil }
        return surface
    }

    func preparedSurfaceForMotion() -> CommittedGridSurface? {
        guard let asset, let surface = registeredSurface, surface.isCurrent(),
              bounds.width > 0, bounds.height > 0, AssetTileRegistry.aspectMatches(surface.image, asset: asset) else { return nil }
        let scale = window?.traitCollection.displayScale ?? traitCollection.displayScale
        guard surface.image.size.width * surface.image.scale >= bounds.width * scale - 1,
              surface.image.size.height * surface.image.scale >= bounds.height * scale - 1 else { return nil }
        return surface
    }

    override func updateProperties() {
        super.updateProperties()
        _ = ImageLoadRecovery.shared.generation
        _ = session?.client
        if asset?.visibility == .locked { _ = session?.lockedFolder?.publicationGeneration }
        guard let asset, let session, let motion else { return }
        if let surface = boundSurface, !surface.isCurrent() {
            lifetime.current = false
            boundSurface = nil; image = nil; key = nil
        }
        configure(asset: asset, mode: mode, session: session, motion: motion, targetPixelSize: targetPixelSize,
                  fallbackPixelSize: fallbackPixelSize)
    }

    func configure(asset: Asset, mode: PhotoBrowseMode, session: SessionStore, motion: PhotoPeriodMotion,
                   targetPixelSize: CGFloat = 900, fallbackPixelSize: CGFloat? = nil) {
        self.asset = asset
        self.mode = mode
        self.motion = motion
        self.session = session
        self.targetPixelSize = targetPixelSize
        self.fallbackPixelSize = fallbackPixelSize
        let client = session.client
        let privateGeneration = asset.visibility == .locked ? session.lockedFolder?.publicationGeneration : nil
        let identity = SourceIdentity(session: client?.context.id, assetID: asset.id, localID: asset.localIdentifier,
            localRevision: asset.localImageVersion, thumbnailRevision: asset.thumbhash, visibility: asset.visibility.rawValue,
            isEdited: asset.isEdited, isTrashed: asset.isTrashed, ratio: asset.ratio.bitPattern)
        let key = Attempt(source: identity, pixels: Int(targetPixelSize.rounded(.up)),
                          recovery: ImageLoadRecovery.shared.generation, privateGeneration: privateGeneration)
        let localScope = AssetThumbnailSource.localCacheScope(accountKey: client?.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize)
        defer { motion.register(self, assetID: asset.id, mode: mode) }
        guard self.key != key else { return }
        let current = sourceIdentity == identity ? registeredSurface : nil
        let keepCurrent = current?.isCurrent() == true
        if keepCurrent, current?.key.pixelBucket == key.pixels {
            self.key = key
            return
        }
        cancelLoad()
        if !keepCurrent {
            lifetime.current = false; lifetime = Lifetime()
            image = nil; boundSurface = nil
        }
        sourceIdentity = identity
        self.key = key
        setNeedsUpdateProperties()
        guard let client else { return }
        if let localID = asset.localIdentifier, asset.visibility != .locked {
            if let cached = LocalImageLoader.shared.cachedBoundImage(localIdentifier: localID, targetPixelSize: targetPixelSize,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: localScope),
               bindLocal(cached, asset: asset, client: client, session: session, scope: localScope, pixels: targetPixelSize) { return }
        } else if asset.localIdentifier == nil {
            let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
            if let cached = ImageLoader.shared.cachedBoundImage(for: url, targetPixelSize: targetPixelSize),
               bindRemote(cached, asset: asset, client: client, session: session, pixels: targetPixelSize) { return }
        }
        if image == nil, let carried = motion.carriedSurface(for: asset.id) {
            boundSurface = carried
            image = carried.image
        }
        if image == nil, let pixels = fallbackPixelSize {
            if let localID = asset.localIdentifier, asset.visibility != .locked {
                let scope = AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey,
                    version: asset.localImageVersion ?? asset.thumbhash, pixels: pixels)
                if let cached = LocalImageLoader.shared.cachedBoundImage(localIdentifier: localID, targetPixelSize: pixels,
                    contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: scope) {
                    _ = bindLocal(cached, asset: asset, client: client, session: session, scope: scope, pixels: pixels)
                }
            } else if asset.localIdentifier == nil {
                let url = client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
                if let cached = ImageLoader.shared.cachedBoundImage(for: url, targetPixelSize: pixels) {
                    _ = bindRemote(cached, asset: asset, client: client, session: session, pixels: pixels)
                }
            }
        }
        load = Task { [weak self] in
            if let localID = asset.localIdentifier, asset.visibility != .locked {
                let loaded = await LocalImageLoader.shared.image(localIdentifier: localID, targetPixelSize: targetPixelSize,
                    contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                    allowsNetwork: false, cacheScope: localScope)
                guard !Task.isCancelled, let self, self.key == key, session.client === client,
                      let loaded, let bound = LocalImageLoader.shared.cachedBoundImage(localIdentifier: localID,
                        targetPixelSize: targetPixelSize, contentMode: DeviceTileRender.contentMode,
                        coversTarget: DeviceTileRender.coversTile, cacheScope: localScope),
                      bound.image === loaded else { return }
                _ = self.bindLocal(bound, asset: asset, client: client, session: session, scope: localScope, pixels: targetPixelSize)
                motion.register(self, assetID: asset.id, mode: mode)
            } else if asset.localIdentifier == nil {
                let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                guard let bound = try? await ImageLoader.shared.boundImage(for: url, targetPixelSize: targetPixelSize),
                      !Task.isCancelled, let self, self.key == key, session.client === client else { return }
                _ = self.bindRemote(bound, asset: asset, client: client, session: session, pixels: targetPixelSize)
                motion.register(self, assetID: asset.id, mode: mode)
            }
        }
    }

    private func bindRemote(_ delivery: BoundRemoteImage, asset: Asset, client: ImoraClient, session: SessionStore, pixels: CGFloat) -> Bool {
        guard !asset.isTrashed, delivery.isCurrent, session.client === client else { return false }
        let expected = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: pixels)
        let actual = delivery.key, paired = session.backup?.localIdentifierByRemoteId[asset.id]
        guard expected.isCurrentContent, actual.scope == expected.scope, actual.subject == expected.subject,
              actual.sourceRevision == expected.sourceRevision, actual.presentationRevision == expected.presentationRevision,
              actual.variant == expected.variant, actual.pixelBucket == expected.pixelBucket, actual.fitMode == expected.fitMode,
              actual.orientationRevision == expected.orientationRevision, actual.colorProfile == expected.colorProfile,
              actual.contentGeneration == expected.contentGeneration,
              actual.visibilityPolicy == nil || actual.visibilityPolicy == expected.visibilityPolicy else { return false }
        if let provenance = delivery.localProvenance {
            guard asset.isEdited != true, provenance.remoteIdentifier == asset.id,
                  paired == provenance.localIdentifier else { return false }
        }
        let lifetime = lifetime
        boundSurface = .init(image: delivery.image, key: expected, access: delivery.access,
            localProvenance: delivery.localProvenance, isCurrent: { [weak session, weak client] in
                guard lifetime.current, let session, let client, session.client === client,
                      delivery.isCurrent, expected.isCurrentContent,
                      session.backup?.localIdentifierByRemoteId[asset.id] == paired else { return false }
                if let provenance = delivery.localProvenance {
                    return asset.isEdited != true && provenance.remoteIdentifier == asset.id
                        && session.backup?.localIdentifierByRemoteId[asset.id] == provenance.localIdentifier
                }
                return true
            })
        image = delivery.image; setNeedsUpdateProperties()
        return true
    }

    private func bindLocal(_ delivery: BoundLocalImage, asset: Asset, client: ImoraClient,
                           session: SessionStore, scope: String, pixels: CGFloat) -> Bool {
        let access = MediaPresentationCoordinator.access(for: client)
        let expected = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: pixels)
        guard !asset.isTrashed, asset.visibility != .locked, session.client === client,
              asset.localIdentifier == delivery.localIdentifier, asset.localImageVersion == delivery.modificationRevision,
              delivery.cacheScope == scope, delivery.targetPixelSize == pixels, delivery.contentMode == DeviceTileRender.contentMode,
              delivery.coversTarget == DeviceTileRender.coversTile,
              delivery.permission == access.permission, delivery.isCurrent, expected.isCurrentContent else { return false }
        let provenance = LocalSurfaceProvenance(localIdentifier: delivery.localIdentifier,
            modificationRevision: delivery.modificationRevision, remoteIdentifier: nil)
        let lifetime = lifetime
        boundSurface = .init(image: delivery.image, key: expected, access: access, localProvenance: provenance,
            isCurrent: { [weak session, weak client] in
                guard lifetime.current, let session, let client, session.client === client,
                      access == MediaPresentationCoordinator.access(for: client), delivery.isCurrent,
                      expected.isCurrentContent else { return false }
                return true
            })
        image = delivery.image; setNeedsUpdateProperties()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let asset { motion?.register(self, assetID: asset.id, mode: mode) }
    }
}
