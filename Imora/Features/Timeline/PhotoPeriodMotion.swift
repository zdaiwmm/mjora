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
        let prepared: CommittedGridSurface
        init(_ view: PeriodPhotoImageView, prepared: CommittedGridSurface) {
            self.view = view; self.prepared = prepared
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
        guard self.assetID == assetID, targetMode == mode else { return }
        let ticket = transitionID
        Task { [weak self, weak view] in
            await Task.yield()
            guard let self, let view, self.transitionID == ticket else { return }
            self.arrive(at: view, mode: mode)
        }
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
            guard let current = entry.view?.registeredSurface, current.image === entry.prepared.image,
                  Self.matches(current, entry.prepared) else { return nil }
            return entry.prepared
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
        let animator = UIViewPropertyAnimator(duration: 0.32, curve: .easeOut) {
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
    let asset: Asset
    let mode: PhotoBrowseMode
    let session: SessionStore
    let motion: PhotoPeriodMotion

    func makeUIView(context: Context) -> PeriodPhotoImageView { PeriodPhotoImageView(frame: .zero) }
    func updateUIView(_ view: PeriodPhotoImageView, context: Context) {
        view.configure(asset: asset, mode: mode, session: session, motion: motion)
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
    private var load: Task<Void, Never>?
    private var key: String?
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
        guard let surface = registeredSurface, surface.isCurrent() else { return nil }
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
        configure(asset: asset, mode: mode, session: session, motion: motion)
    }

    func configure(asset: Asset, mode: PhotoBrowseMode, session: SessionStore, motion: PhotoPeriodMotion) {
        self.asset = asset
        self.mode = mode
        self.motion = motion
        self.session = session
        let client = session.client
        let privateGeneration = asset.visibility == .locked ? session.lockedFolder?.publicationGeneration : nil
        let key = "\(client?.context.id.uuidString ?? "none")|\(asset.id)|\(asset.localImageVersion ?? asset.thumbhash ?? "")|\(asset.visibility.rawValue)|\(String(describing: asset.isEdited))|\(ImageLoadRecovery.shared.generation)|\(privateGeneration.map(String.init) ?? "")"
        let localScope = AssetThumbnailSource.localCacheScope(accountKey: client?.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: 900)
        defer { motion.register(self, assetID: asset.id, mode: mode) }
        guard self.key != key else { return }
        cancelLoad()
        lifetime.current = false; lifetime = Lifetime()
        self.key = key
        image = nil; boundSurface = nil
        setNeedsUpdateProperties()
        guard let client else { return }
        if let localID = asset.localIdentifier, asset.visibility != .locked {
            if let cached = LocalImageLoader.shared.cachedBoundImage(localIdentifier: localID, targetPixelSize: 900,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: localScope),
               bindLocal(cached, asset: asset, client: client, session: session, scope: localScope) { return }
        } else if asset.localIdentifier == nil {
            let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
            if let cached = ImageLoader.shared.cachedBoundImage(for: url, targetPixelSize: 900),
               bindRemote(cached, asset: asset, client: client, session: session) { return }
        }
        load = Task { [weak self] in
            if let localID = asset.localIdentifier, asset.visibility != .locked {
                let loaded = await LocalImageLoader.shared.image(localIdentifier: localID, targetPixelSize: 900,
                    contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                    allowsNetwork: false, cacheScope: localScope)
                guard !Task.isCancelled, let self, self.key == key, session.client === client,
                      let loaded, let bound = LocalImageLoader.shared.cachedBoundImage(localIdentifier: localID,
                        targetPixelSize: 900, contentMode: DeviceTileRender.contentMode,
                        coversTarget: DeviceTileRender.coversTile, cacheScope: localScope),
                      bound.image === loaded else { return }
                _ = self.bindLocal(bound, asset: asset, client: client, session: session, scope: localScope)
                motion.register(self, assetID: asset.id, mode: mode)
            } else if asset.localIdentifier == nil {
                let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                guard let bound = try? await ImageLoader.shared.boundImage(for: url, targetPixelSize: 900),
                      !Task.isCancelled, let self, self.key == key, session.client === client else { return }
                _ = self.bindRemote(bound, asset: asset, client: client, session: session)
                motion.register(self, assetID: asset.id, mode: mode)
            }
        }
    }

    private func bindRemote(_ delivery: BoundRemoteImage, asset: Asset, client: ImoraClient, session: SessionStore) -> Bool {
        guard !asset.isTrashed, delivery.isCurrent, session.client === client else { return false }
        let expected = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 900)
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
                           session: SessionStore, scope: String) -> Bool {
        let access = MediaPresentationCoordinator.access(for: client)
        let expected = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 900)
        guard !asset.isTrashed, asset.visibility != .locked, session.client === client,
              asset.localIdentifier == delivery.localIdentifier, asset.localImageVersion == delivery.modificationRevision,
              delivery.cacheScope == scope, delivery.contentMode == DeviceTileRender.contentMode,
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
