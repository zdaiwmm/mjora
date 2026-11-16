import SwiftUI
import UIKit

/// A single image travels between real card/tile frames. It adds no recognizers,
/// so the grid's continuous pinch and the viewer keep their gesture ownership.
@MainActor
final class PhotoPeriodMotion {
    static let replicaTag = 0xF0123
    private final class Surface {
        weak var view: UIImageView?
        init(_ view: UIImageView) { self.view = view }
    }
    var reducesMotion = false
    private var surfaces: [PhotoBrowseMode: [String: Surface]] = [:]
    private var animator: UIViewPropertyAnimator?
    private var replica: UIView?
    private weak var source: UIView?
    private weak var destination: UIView?
    private var sourceAlpha: CGFloat = 1
    private var destinationAlpha: CGFloat = 1
    private var timeout: Task<Void, Never>?
    private(set) var transitionID: UUID?
    private(set) var assetID: String?
    private var targetMode: PhotoBrowseMode?

    func register(_ view: UIImageView, assetID: String, mode: PhotoBrowseMode) {
        surfaces[mode, default: [:]][assetID] = Surface(view)
        guard self.assetID == assetID, targetMode == mode else { return }
        let ticket = transitionID
        Task { [weak self, weak view] in
            await Task.yield()
            guard let self, let view, self.transitionID == ticket else { return }
            self.arrive(at: view, mode: mode)
        }
    }

    func begin(assetID: String, from: PhotoBrowseMode, to: PhotoBrowseMode,
               gridSource: TimelineTileView?, reduceMotion: Bool) {
        // Carry the in-flight photo at its presentation frame into a reversal.
        let carried = self.assetID == assetID ? replica : nil
        let carriedFrame = carried?.layer.presentation()?.frame ?? carried?.frame
        let carriedWindow = carried?.window
        if let carriedFrame { carried?.frame = carriedFrame }
        if let carried { carried.removeFromSuperview() }
        cancel()
        guard !reduceMotion else { return }
        let sourceView: UIView? = from == .all ? gridSource : surfaces[from]?[assetID]?.view
        let imageView: UIView?
        if let carried { imageView = carried }
        else if let tile = sourceView as? TimelineTileView { imageView = tile.makeZoomReplica() }
        else if let photo = sourceView as? UIImageView, let image = photo.image {
            let copy = UIImageView(image: image)
            copy.contentMode = .scaleAspectFill
            imageView = copy
        } else { imageView = nil }
        guard let imageView, let window = carriedWindow ?? sourceView?.window else { return }
        let start = carriedFrame ?? sourceView.map { $0.convert($0.bounds, to: window) } ?? .zero
        guard start.width > 0, start.height > 0 else { return }
        let ticket = UUID()
        transitionID = ticket
        self.assetID = assetID
        targetMode = to
        replica = imageView
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
    private var load: Task<Void, Never>?
    private var key: String?
    private var assetID: String?
    private var mode: PhotoBrowseMode = .years
    private weak var motion: PhotoPeriodMotion?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemBackground
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func cancelLoad() { load?.cancel(); load = nil }
    func configure(asset: Asset, mode: PhotoBrowseMode, session: SessionStore, motion: PhotoPeriodMotion) {
        self.assetID = asset.id
        self.mode = mode
        self.motion = motion
        let client = session.client
        let key = "\(client?.offlineAccountKey ?? "device")|\(asset.id)|\(asset.localImageVersion ?? asset.thumbhash ?? "")"
        let localScope = AssetThumbnailSource.localCacheScope(accountKey: client?.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: 900)
        defer { if image != nil { motion.register(self, assetID: asset.id, mode: mode) } }
        guard self.key != key else { return }
        cancelLoad()
        self.key = key
        image = nil
        if let localID = asset.localIdentifier {
            image = LocalImageLoader.shared.cachedPreview(localIdentifier: localID, cacheScope: localScope)
        } else if let client {
            image = ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash), targetPixelSize: 900)
        }
        load = Task { [weak self] in
            let loaded: UIImage?
            if let localID = asset.localIdentifier {
                loaded = await LocalImageLoader.shared.image(localIdentifier: localID, targetPixelSize: 900, cacheScope: localScope)
            } else if let client {
                loaded = try? await ImageLoader.shared.image(for: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash), targetPixelSize: 900)
            } else { loaded = nil }
            guard !Task.isCancelled, let self, self.key == key, session.client === client else { return }
            if let loaded { self.image = loaded }
            motion.register(self, assetID: asset.id, mode: mode)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if image != nil, let assetID { motion?.register(self, assetID: assetID, mode: mode) }
    }
}
