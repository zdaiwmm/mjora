import Foundation
import SwiftUI
import UIKit

/// what a tile row hands back to its screen. one set per row, each taking the
/// asset, rather than a fresh set of closures copied into every tile.
struct TimelineTileActions {
    /// one-shot picker: a tap hands the photo back, nothing else responds.
    var pick: ((Asset) -> Void)?
    var toggleSelection: (Asset) -> Void
    var menu: (Asset) -> UIMenu
    var makeViewer: (_ asset: Asset, _ startsAsContextPreview: Bool, _ bounds: CGSize) -> AssetViewerHostingController?
}

struct TimelineReflowTile {
    let view: TimelineTileView
    let frame: CGRect
}

/// everything one row of tiles is drawn from. tiles are plain views placed
/// by column arithmetic, and the row owns the one tap recognizer and menu
/// interaction, finding the tile under the finger by its frame.
struct TimelineTileRowConfiguration {
    let session: SessionStore
    let runs: [TileRun]
    let rowIndex: Int
    let side: CGFloat
    let targetPixelSize: CGFloat
    let showsBackupBadge: Bool
    var showsAllBackupStatuses = false
    let usesOriginalAspectRatio: Bool
    let isSelecting: Bool
    let selection: Set<String>
    let projectedRemovalIDs: Set<String>
    let isSelectable: (Asset) -> Bool
    let reduceMotion: Bool
    let registry: AssetTileRegistry
    let motion: GridMotion
    let actions: TimelineTileActions
}

final class TimelineTileRowView: UIView, UIContextMenuInteractionDelegate {
    private var row: TimelineTileRowConfiguration?
    private var tiles: [TimelineTileView] = []
    /// the column of each tile, in the same order.
    private var columns: [Int] = []
    var zoomTiles: [TimelineTileView] { tiles }
    private var side: CGFloat = 0
    private let tap = UITapGestureRecognizer()
    private weak var pinch: UIGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// two fingers of a pinch can land on two rows, and each row would read
    /// its one finger as a tap.
    func waitForPinch(_ pinch: UIGestureRecognizer) {
        guard self.pinch !== pinch else { return }
        self.pinch = pinch
        tap.require(toFail: pinch)
    }

    func apply(_ row: TimelineTileRowConfiguration, animated: Bool) {
        var reusable: [String: TimelineReflowTile] = [:]
        apply(row, animated: animated, reusing: &reusable)
    }

    func takeTilesForReflow(in grid: UIView) -> [TimelineReflowTile] {
        let result = tiles.map { tile in
            let frame = tile.layer.presentation()?.frame ?? tile.frame
            let visible = tile.superview?.convert(frame, to: grid) ?? tile.convert(tile.bounds, to: grid)
            tile.layer.removeAllAnimations()
            return TimelineReflowTile(view: tile, frame: visible)
        }
        tiles = []
        columns = []
        return result
    }

    func apply(_ row: TimelineTileRowConfiguration, animated: Bool,
               reusing reusable: inout [String: TimelineReflowTile]) {
        self.row = row
        side = row.side

        var leftovers = tiles
        var nextTiles: [TimelineTileView] = []
        var nextColumns: [Int] = []
        var inserted: [TimelineTileView] = []
        for run in row.runs {
            for (offset, asset) in run.assets.enumerated() {
                let column = run.colStart + offset
                let tile: TimelineTileView
                if let retained = reusable.removeValue(forKey: asset.id) {
                    tile = retained.view
                    UIView.performWithoutAnimation {
                        let start = superview.map { convert(retained.frame, from: $0) } ?? retained.frame
                        addSubview(tile)
                        tile.frame = start
                    }
                } else if let index = leftovers.firstIndex(where: { $0.asset?.id == asset.id }) {
                    tile = leftovers.remove(at: index)
                } else if !animated, !leftovers.isEmpty {
                    // a row reused for other photos, e.g. a bucket landing
                    // above: repaint in place instead of building views.
                    tile = leftovers.removeFirst()
                } else {
                    tile = TimelineTileView.dequeue()
                    UIView.performWithoutAnimation {
                        addSubview(tile)
                        tile.frame = frame(forColumn: column)
                        // plain crossfade: an uploaded photo swaps its local
                        // tile for the server twin with identical pixels.
                        if animated { tile.alpha = 0 }
                    }
                    inserted.append(tile)
                }
                tile.configure(
                    asset: asset,
                    session: row.session,
                    motion: row.motion,
                    showsBackupBadge: row.showsBackupBadge,
                    showsAllBackupStatuses: row.showsAllBackupStatuses,
                    targetPixelSize: row.targetPixelSize,
                    registry: row.registry,
                    usesOriginalAspectRatio: row.usesOriginalAspectRatio
                )
                tile.isSelectable = row.isSelectable(asset)
                tile.isSelected = row.selection.contains(asset.id)
                tile.selectionPosition = SelectionGridPosition(row: row.rowIndex, column: column)
                tile.updateSelectionAppearance(isSelecting: row.isSelecting && row.actions.pick == nil)
                tile.setProjectedRemoved(
                    row.projectedRemovalIDs.contains(asset.id),
                    animated: !row.reduceMotion
                )
                nextTiles.append(tile)
                nextColumns.append(column)
            }
        }

        for tile in leftovers {
            tile.unregister()
            if animated {
                UIView.animate(withDuration: PhotosMotion.removalDuration, animations: {
                    tile.alpha = 0
                }, completion: { _ in
                    tile.recycle()
                })
            } else {
                tile.recycle()
            }
        }
        tiles = nextTiles
        columns = nextColumns

        setNeedsLayout()
        if animated {
            layoutIfNeeded()
            for tile in inserted { tile.alpha = 1 }
        }
    }

    /// the row is leaving the window, its tiles go back to the pool.
    func unregisterTiles() {
        for tile in tiles {
            tile.unregister()
            tile.recycle()
        }
        tiles = []
        columns = []
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (tile, column) in zip(tiles, columns) {
            tile.frame = frame(forColumn: column)
        }
    }

    /// leading padding in the swiftui grid, so right to left mirrors it.
    private func frame(forColumn column: Int) -> CGRect {
        var x = CGFloat(column) * (side + 2)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            x = bounds.width - x - side
        }
        return CGRect(x: x, y: 0, width: side, height: side)
    }

    private func tile(at point: CGPoint) -> TimelineTileView? {
        tiles.first { $0.frame.contains(point) && !$0.isProjectedRemoved }
    }

    private func tile(withAssetID id: String) -> TimelineTileView? {
        tiles.first { $0.asset?.id == id }
    }

    // MARK: - interaction

    private var isPinchReflowActive: Bool {
        (superview as? TimelineGridView)?.zoomTransition.isPrepared == true
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !isPinchReflowActive, let row,
              let tile = tile(at: recognizer.location(in: self)),
              tile.isUserInteractionEnabled,
              let asset = tile.asset
        else { return }
        if tile.retryIfNeeded(at: recognizer.location(in: tile)) { return }
        if let pick = row.actions.pick {
            pick(asset)
            return
        }
        if row.isSelecting {
            if tile.isSelectable { row.actions.toggleSelection(asset) }
            return
        }
        guard let bounds = window?.bounds.size,
              let presenter = presentationAnchor(),
              let viewer = row.actions.makeViewer(asset, false, bounds)
        else { return }
        viewer.presentDirectly(from: presenter)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isPinchReflowActive, let row,
              row.actions.pick == nil,
              let tile = tile(at: location),
              tile.isUserInteractionEnabled,
              let asset = tile.asset,
              let bounds = window?.bounds.size
        else { return nil }
        let viewer = row.actions.makeViewer(asset, true, bounds)
        let menu = row.actions.menu
        return UIContextMenuConfiguration(
            identifier: asset.id as NSString,
            previewProvider: { viewer },
            actionProvider: { _ in menu(asset) }
        )
    }

    /// the interaction sits on the row, so the lift is pointed at the tile.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        targetedPreview(for: identifier)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        targetedPreview(for: identifier)
    }

    private func targetedPreview(for identifier: any NSCopying) -> UITargetedPreview? {
        guard let id = identifier as? NSString,
              let tile = tile(withAssetID: id as String),
              tile.window != nil
        else { return nil }
        return UITargetedPreview(view: tile)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let row,
              let id = configuration.identifier as? NSString,
              let asset = tile(withAssetID: id as String)?.asset,
              let bounds = window?.bounds.size,
              let presenter = presentationAnchor(),
              let viewer = row.actions.makeViewer(asset, false, bounds)
        else { return }

        // `.pop` owns the visual expansion. its disposable preview is
        // replaced by a prepared full viewer only after uikit releases it.
        viewer.prepareViewerContentForContextCommit()
        animator.preferredCommitStyle = .pop
        animator.addCompletion {
            viewer.presentAfterContextCommit(from: presenter)
        }
    }

    /// Presents from the stable container above SwiftUI's hosting child.
    /// The context-menu presentation itself is transient and has completed
    /// by the time the captured controller is asked to attach the viewer.
    private func presentationAnchor() -> UIViewController? {
        var responder: UIResponder? = self
        var controller: UIViewController?
        while let current = responder {
            if let current = current as? UIViewController {
                controller = current
                break
            }
            responder = current.next
        }
        guard var controller else { return nil }
        while let parent = controller.parent {
            controller = parent
        }
        return controller
    }
}

/// one grid tile in plain uikit: the image, the corner badges, the backup
/// state and the selection mark. backup state and load recovery are read in
/// `updateProperties`, where uikit tracks observable reads, so a change in
/// either reaches only the tiles that read it.
final class TimelineTileView: UIView {
    /// A lightweight render surface sharing the decoded image with the tile.
    /// Never re-encode a thumbnail merely to animate it between row parents.
    func zoomReplicaFactory() -> (() -> UIView)? {
        guard let image = imageView.image else { return nil }
        let color = imageView.backgroundColor
        let contentMode = imageView.contentMode
        return {
            let replica = UIImageView(image: image)
            replica.backgroundColor = color
            replica.contentMode = contentMode
            replica.clipsToBounds = true
            return replica
        }
    }
    /// read by the selection slide's hit test.
    var isSelected = false
    var isSelectable = false
    var selectionPosition = SelectionGridPosition(row: 0, column: 0)

    private(set) var asset: Asset?
    private weak var session: SessionStore?
    private weak var motion: GridMotion?
    private weak var registry: AssetTileRegistry?
    private var showsBackupBadge = false
    private var showsMediaBadges = true
    private var showsAllBackupStatuses = false
    private var targetPixelSize: CGFloat = 0
    private var registeredAsset: Asset?
    private var registeredTargetPixelSize: CGFloat?

    private let content = UIView()
    private let imageView = UIImageView()
    private var topTrailingBadge: UIView?
    private var durationBadge: UILabel?
    private var topLeadingBadge: UIView?
    private var favoriteBadge: UIView?
    private var backupBadge: TileGlyphBadge?
    private var backupBadgeName: String?
    private var selectionIndicator: UIImageView?
    private var selectionAppearance: (isSelecting: Bool, isSelected: Bool, isSelectable: Bool)?
    private(set) var isProjectedRemoved = false

    /// the request the image on screen answers, and the one in flight.
    private var loadKey: String?
    private var loadGeneration = -1
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?
    private var placeholderTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var thumbnailState = ThumbnailLoadState(hasLocal: false, hasRemote: false, targetPixels: 1)
    private let retryButton = UIButton(type: .system)
    /// a picture of the same photo is on screen, so the sharp render lands in
    /// place: fading one rendition into another reads as a pulse.
    private var showsPicture = false
    private var activeDisplayKey: MediaDisplayKeyV1?
    private var shownDisplayKey: MediaDisplayKeyV1?
    private struct SurfaceBinding {
        let key: MediaDisplayKeyV1
        let access: MediaAccessGeneration
        let client: ImoraClient
        let privateLease: LockedMediaLease?
        let requiresElevation: Bool
        var isCurrent: Bool {
            client.context.isActive && key.isCurrentContent
                && access == MediaPresentationCoordinator.access(for: client)
                && (!requiresElevation || privateLease?.isCurrent == true)
        }
    }
    private var requestBinding: SurfaceBinding?
    private var boundSurface: CommittedGridSurface?
    private var boundSurfaceID: UUID?
    #if DEBUG && targetEnvironment(simulator)
    private var phase4OracleTask: Task<Void, Never>?
    #endif
    private weak var projectionClient: ImoraClient?
    private var projectionSource: AssetThumbnailSource?
    private var visibleLocalIdentifier: String?
    private var visibleLocalRevision: String?
    /// photokit could not serve the paired device copy, so the tile renders
    /// the server thumbnail instead until the next recovery.
    private var unavailableLocalIdentifier: String?
    private var unavailableGeneration = -1

    /// tiles of rows that left the window, handed to the rows coming in so a
    /// fling moves views around instead of building and freeing them.
    private static var pool: [TimelineTileView] = []
    private static let poolLimit = 96

    static func dequeue() -> TimelineTileView {
        pool.popLast() ?? TimelineTileView()
    }

    func recycle() {
        removeFromSuperview()
        prepareForReuse()
        guard Self.pool.count < Self.poolLimit else { return }
        alpha = 1
        isUserInteractionEnabled = true
        setProjectedRemoved(false, animated: false)
        Self.pool.append(self)
    }

    /// A non-grid host reuses its own tile without putting it in the grid pool.
    func prepareForReuse() {
        cancelLoads()
        // a pooled tile must not keep a bitmap alive outside nuke's budget.
        imageView.image = nil
        boundSurface = nil
        boundSurfaceID = nil
        requestBinding = nil
        activeDisplayKey = nil
        shownDisplayKey = nil
        visibleLocalIdentifier = nil
        visibleLocalRevision = nil
        loadKey = nil
        loadedKey = nil
        showsPicture = false
        // forgets the photo too, so a tile handed it back loads it again.
        asset = nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // pointer feedback on ipad, the same highlight photos gives its grid.
        hoverStyle = UIHoverStyle(effect: .highlight)
        content.isUserInteractionEnabled = false
        content.clipsToBounds = true
        content.layer.cornerRadius = 2
        addSubview(content)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        content.addSubview(imageView)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise.circle.fill"), for: .normal)
        retryButton.tintColor = .white
        retryButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        retryButton.layer.cornerRadius = 18
        retryButton.accessibilityLabel = String(localized: "Retry")
        retryButton.accessibilityIdentifier = "thumbnail-retry"
        retryButton.addTarget(self, action: #selector(retryThumbnail), for: .touchUpInside)
        retryButton.isHidden = true
        addSubview(retryButton)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "asset-tile"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        asset: Asset,
        session: SessionStore,
        motion: GridMotion,
        showsBackupBadge: Bool,
        showsAllBackupStatuses: Bool = false,
        targetPixelSize: CGFloat,
        registry: AssetTileRegistry?,
        usesOriginalAspectRatio: Bool = false,
        showsMediaBadges: Bool = true
    ) {
        imageView.contentMode = usesOriginalAspectRatio ? .scaleAspectFit : .scaleAspectFill
        let accountChanged = self.session !== session
        self.session = session
        self.motion = motion
        let changed = accountChanged || self.asset != asset
            || self.showsMediaBadges != showsMediaBadges
            || self.showsBackupBadge != showsBackupBadge
            || self.showsAllBackupStatuses != showsAllBackupStatuses
            || self.targetPixelSize != targetPixelSize
        if self.asset?.id != asset.id {
            unavailableLocalIdentifier = nil
        }
        self.asset = asset
        self.showsMediaBadges = showsMediaBadges
        self.showsBackupBadge = showsBackupBadge
        self.showsAllBackupStatuses = showsAllBackupStatuses
        self.targetPixelSize = targetPixelSize
        if changed {
            updateAssetBadges(for: asset)
            setNeedsUpdateProperties()
        }
        if let registry { register(in: registry) }
        // Bind the source before this row's first UIKit layout can display it.
        updatePropertiesIfNeeded()
    }

    // MARK: - registry

    private func register(in registry: AssetTileRegistry) {
        guard let asset, let session else { return }
        if let registered = registeredAsset,
           self.registry !== registry || registered.id != asset.id {
            self.registry?.unregister(self, for: registered.id)
        }
        guard self.registry !== registry
                || registeredAsset != asset
                || registeredTargetPixelSize != targetPixelSize
        else { return }
        self.registry = registry
        registeredAsset = asset
        registeredTargetPixelSize = targetPixelSize
        registry.register(self, asset: asset, session: session, targetPixelSize: targetPixelSize)
    }

    func unregister() {
        cancelLoads()
        guard let registered = registeredAsset else { return }
        registry?.unregister(self, for: registered.id)
        registeredAsset = nil
        registeredTargetPixelSize = nil
    }

    // MARK: - observed state

    override func updateProperties() {
        super.updateProperties()
        guard let asset, let session else { return }
        let generation = ImageLoadRecovery.shared.generation
        if asset.visibility == .locked { _ = session.lockedFolder?.publicationGeneration }
        let backup = session.backup
        // the device copy is free, already decoded by photokit and needs no
        // network, so it wins whenever the backup index pairs one with this
        // asset. edited server copies are excluded from that map.
        let source = AssetThumbnailSource(
            assetID: asset.id,
            localIdentifier: asset.localIdentifier,
            pairedLocalIdentifier: backup?.localIdentifierByRemoteId[asset.id],
            pairedRemoteIdentifier: asset.localIdentifier.flatMap {
                backup?.remoteIdentifierByLocalId[$0]
            },
            unavailableLocalIdentifier: unavailableGeneration == generation ? unavailableLocalIdentifier : nil,
            isEdited: asset.isEdited == true
        )
        projectImage(asset: asset, source: source, client: session.client, generation: generation, targetPixelSize: targetPixelSize)
        updateBackupState(asset: asset, backup: showsBackupBadge ? backup : nil)
    }

    // MARK: - image

    func projectImage(asset: Asset, source: AssetThumbnailSource, client: ImoraClient?, generation: Int,
                      targetPixelSize: CGFloat) {
        let resizingPreview: CommittedGridSurface?
        if let previous = boundSurface, previous.key.pixelBucket != Int(targetPixelSize.rounded(.up)),
           let client, projectionClient === client,
           previous.key == MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: CGFloat(previous.key.pixelBucket)),
           previous.isCurrent() {
            resizingPreview = previous
        } else { resizingPreview = nil }
        self.asset = asset
        self.targetPixelSize = targetPixelSize
        if let client {
            let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: targetPixelSize)
            if !key.isCurrentContent || (asset.visibility == .locked && client.lockedMediaLease == nil) {
                cancelLoads()
                imageView.image = nil; showsPicture = false; shownDisplayKey = nil
                boundSurface = nil; boundSurfaceID = nil
                loadKey = nil; loadedKey = nil
                projectionClient = client; projectionSource = source; activeDisplayKey = key
                thumbnailState = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: Double(targetPixelSize))
                _ = thumbnailState.remoteResult(pixels: nil, isPreview: true)
                updateThumbnailStatus()
                return
            }
        }
        // A bound surface checks its captured local revision in isCurrent().
        // Unbound previews still need their own fresh access check here.
        if boundSurface == nil, let visibleLocalIdentifier {
            applyLocalAccessRevision(LocalImageLoader.currentModificationRevision(visibleLocalIdentifier))
        }
        if let previous = boundSurface {
            let expected = client.map { MediaPresentationCoordinator.gridKey(asset: asset, client: $0, pixels: targetPixelSize) }
            if previous.key != expected || !previous.isCurrent() || projectionClient !== client || requestBinding?.isCurrent != true {
                imageView.image = nil
                showsPicture = false
                shownDisplayKey = nil
                boundSurface = nil
                boundSurfaceID = nil
                loadKey = nil; loadedKey = nil
            }
        }
        projectionClient = client
        // A server edit's committed rendition cannot come from its old paired original.
        let selected = asset.localIdentifier == nil && asset.isEdited == true
            ? AssetThumbnailSource(assetID: asset.id, localIdentifier: nil, pairedLocalIdentifier: nil,
                pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil) : source
        projectionSource = selected
        updateImage(asset: asset, source: selected, client: client, generation: generation, resizingPreview: resizingPreview)
    }

    func checkpointSurface(for key: MediaDisplayKeyV1, client: ImoraClient) -> CommittedGridSurface? {
        guard let surface = boundSurface, surface.key == key, surface.isCurrent(),
              projectionClient === client else { return nil }
        return surface
    }

    func preparedSurfaceForMotion() -> CommittedGridSurface? {
        guard let surface = boundSurface, surface.isCurrent(), imageView.image === surface.image else { return nil }
        return surface
    }

    /// A viewer can hand its displayed bitmap to the matching destination
    /// before detaching. The captured proof remains part of the tile proof.
    func prepareReturnSurface(_ surface: CommittedGridSurface, client: ImoraClient) -> Bool {
        guard let asset, projectionClient === client, let binding = requestBinding, let loadKey,
              binding.isCurrent, surface.isCurrent(), surface.access == binding.access,
              surface.key.scope == binding.key.scope, surface.key.subject == binding.key.subject,
              surface.key.sourceRevision == binding.key.sourceRevision,
              surface.key.presentationRevision == binding.key.presentationRevision,
              surface.key.contentGeneration == binding.key.contentGeneration,
              surface.key.visibilityPolicy == binding.key.visibilityPolicy,
              surface.key.variant == binding.key.variant, surface.key.fitMode == binding.key.fitMode,
              surface.key.orientationRevision == binding.key.orientationRevision,
              surface.key.colorProfile == binding.key.colorProfile,
              AssetTileRegistry.aspectMatches(surface.image, asset: asset),
              min(surface.image.size.width, surface.image.size.height) * surface.image.scale >= targetPixelSize * 0.95
        else { return false }
        if let local = projectionSource?.preferredLocalIdentifier {
            guard surface.localProvenance?.localIdentifier == local else { return false }
        } else if surface.localProvenance != nil {
            return false
        }
        cancelLoads()
        thumbnailState = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: Double(targetPixelSize))
        _ = thumbnailState.remoteResult(pixels: Double(targetPixelSize), isPreview: true)
        show(surface.image, key: loadKey, fading: false, binding: binding,
            localProvenance: surface.localProvenance, inheritedSurface: surface)
        return boundSurface?.isCurrent() == true
    }

    /// This boundary can only revoke a displayed local surface, never grant access.
    func applyLocalAccessRevision(_ currentRevision: String?) {
        guard visibleLocalIdentifier != nil,
              currentRevision == nil || (visibleLocalRevision != nil && currentRevision != visibleLocalRevision) else { return }
        cancelLoads()
        imageView.image = nil
        showsPicture = false
        shownDisplayKey = nil
        boundSurface = nil
        boundSurfaceID = nil
        visibleLocalIdentifier = nil
        visibleLocalRevision = nil
        loadKey = nil
        loadedKey = nil
    }

    private func updateImage(
        asset: Asset,
        source: AssetThumbnailSource,
        client: ImoraClient?,
        generation: Int,
        resizingPreview: CommittedGridSurface?
    ) {
        activeDisplayKey = client.map { MediaPresentationCoordinator.gridKey(asset: asset, client: $0, pixels: targetPixelSize) }
        if let localIdentifier = source.preferredLocalIdentifier {
            // a device-only photo has nowhere else to come from; a paired one
            // falls back to the server thumbnail rather than downloading its
            // original from icloud.
            let allowsNetwork = false
            let scope = AssetThumbnailSource.localCacheScope(accountKey: client?.offlineAccountKey, version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize)
            let key = "local|\(scope)|\(localIdentifier)#\(Int(targetPixelSize))"
            guard needsLoad(key: key, generation: generation) else { return }
            let serverThumbnail = client.flatMap { client in
                source.remoteIdentifier.flatMap { remoteIdentifier in
                    ImageLoader.shared.cachedSurface(
                        for: client.thumbnailURL(assetID: remoteIdentifier, cacheKey: asset.thumbhash),
                        targetPixelSize: targetPixelSize
                    )
                }
            }
            loadLocal(
                localIdentifier,
                key: key,
                generation: generation,
                allowsNetwork: allowsNetwork,
                placeholder: resizingPreview.map { (image: $0.image, localProvenance: $0.localProvenance) } ?? serverThumbnail,
                cacheScope: scope,
                remoteURL: source.remoteIdentifier.flatMap { client?.thumbnailURL(assetID: $0, cacheKey: asset.thumbhash) },
                previewURL: source.remoteIdentifier.flatMap { client?.thumbnailURL(assetID: $0, size: "preview", cacheKey: asset.thumbhash) }
            )
        } else if let client, let remoteIdentifier = source.remoteIdentifier {
            let url = client.thumbnailURL(assetID: remoteIdentifier, cacheKey: asset.thumbhash)
            let key = ImageLoader.shared.requestKey(for: url, targetPixelSize: targetPixelSize)
            guard needsLoad(key: key, generation: generation) else { return }
            loadRemote(
                url,
                previewURL: client.thumbnailURL(assetID: remoteIdentifier, size: "preview", cacheKey: asset.thumbhash),
                key: key,
                generation: generation,
                thumbhash: asset.thumbhash,
                placeholder: (resizingPreview?.localProvenance == nil ? resizingPreview?.image : nil) ?? source.localIdentifier.flatMap {
                    LocalImageLoader.shared.cachedPreview(localIdentifier: $0, cacheScope: AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey, version: asset.localImageVersion ?? asset.thumbhash, pixels: targetPixelSize))
                }
            )
        } else {
            cancelLoads()
            loadKey = nil
            loadedKey = nil
            imageView.image = nil
            showsPicture = false
        }
    }

    /// a new source loads; a recovery retries only what never arrived.
    private func needsLoad(key: String, generation: Int) -> Bool {
        if requestBinding?.key != activeDisplayKey { return true }
        if let client = projectionClient, requestBinding?.access != MediaPresentationCoordinator.access(for: client) { return true }
        if key != loadKey { return true }
        return generation != loadGeneration && loadedKey != key
    }

    private func cancelLoads() {
        #if DEBUG && targetEnvironment(simulator)
        phase4OracleTask?.cancel(); phase4OracleTask = nil
        #endif
        loadTask?.cancel()
        loadTask = nil
        placeholderTask?.cancel()
        placeholderTask = nil
        remoteTask?.cancel()
        remoteTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        thumbnailState.cancel()
    }

    private func begin(key: String, generation: Int) {
        cancelLoads()
        if loadKey != key {
            loadedKey = nil
            shownDisplayKey = nil
        }
        loadKey = key
        loadGeneration = generation
        retryButton.isHidden = true
        if let client = projectionClient, let key = activeDisplayKey {
            requestBinding = .init(key: key, access: MediaPresentationCoordinator.access(for: client), client: client,
                privateLease: asset?.visibility == .locked ? client.lockedMediaLease : nil,
                requiresElevation: asset?.visibility == .locked)
        } else { requestBinding = nil }
    }

    @objc private func retryThumbnail() {
        loadKey = nil
        loadedKey = nil
        unavailableLocalIdentifier = nil
        setNeedsUpdateProperties()
    }

    func retryIfNeeded(at point: CGPoint) -> Bool {
        guard !retryButton.isHidden, retryButton.frame.contains(point) else { return false }
        retryThumbnail()
        return true
    }

    @objc private func accessibilityRetry() -> Bool {
        retryThumbnail()
        return true
    }

    private func updateThumbnailStatus() {
        accessibilityCustomActions = thumbnailState.phase == .retry
            ? [UIAccessibilityCustomAction(name: String(localized: "Retry"), target: self, selector: #selector(accessibilityRetry))]
            : nil
        retryButton.isHidden = thumbnailState.phase != .retry
        accessibilityValue = thumbnailState.phase == .retry
            ? String(localized: "Image unavailable. Retry")
            : (thumbnailState.phase == .preview ? String(localized: "Loading") : nil)
    }

    private func show(_ image: UIImage, key: String, fading: Bool, binding: SurfaceBinding?,
                      localProvenance: LocalSurfaceProvenance? = nil, inheritedSurface: CommittedGridSurface? = nil) {
        if let binding, binding.access != MediaPresentationCoordinator.access(for: binding.client) {
            reprojectAfterAccessChange(binding: binding, key: key)
            return
        }
        guard let binding, binding.client.context.isActive, projectionClient === binding.client,
              binding.access == MediaPresentationCoordinator.access(for: binding.client), binding.key.isCurrentContent,
              (asset?.visibility != .locked || binding.privateLease?.isCurrent == true),
              let asset, binding.key == MediaPresentationCoordinator.gridKey(asset: asset, client: binding.client, pixels: targetPixelSize),
              loadKey == key else { return }
        if let localProvenance {
            guard projectionSource?.preferredLocalIdentifier == localProvenance.localIdentifier,
                  asset.localIdentifier != nil || asset.isEdited != true,
                  LocalImageLoader.currentModificationRevision(localProvenance.localIdentifier) == localProvenance.modificationRevision else {
                applyLocalAccessRevision(nil)
                return
            }
        }
        placeholderTask?.cancel()
        loadedKey = key
        retryButton.isHidden = true
        accessibilityValue = nil
        accessibilityCustomActions = nil
        showsPicture = true
        imageView.image = image
        visibleLocalIdentifier = localProvenance?.localIdentifier
        visibleLocalRevision = localProvenance?.modificationRevision
        shownDisplayKey = binding.key
        let id = UUID()
        boundSurfaceID = id
        boundSurface = .init(image: image, key: binding.key, access: binding.access, localProvenance: localProvenance,
            isCurrent: { [weak self, weak client = binding.client] in
                guard let self, let client, client.context.isActive, self.projectionClient === client,
                      inheritedSurface?.isCurrent() != false,
                      self.boundSurfaceID == id, binding.key.isCurrentContent,
                      (self.asset?.visibility != .locked || binding.privateLease?.isCurrent == true),
                      binding.access == MediaPresentationCoordinator.access(for: client),
                      let current = self.asset,
                      binding.key == MediaPresentationCoordinator.gridKey(asset: current, client: client, pixels: CGFloat(binding.key.pixelBucket))
                else { return false }
                if let localProvenance {
                    guard self.projectionSource?.preferredLocalIdentifier == localProvenance.localIdentifier,
                          current.localIdentifier != nil || current.isEdited != true,
                          LocalImageLoader.currentModificationRevision(localProvenance.localIdentifier) == localProvenance.modificationRevision else { return false }
                    if let session = self.session, let remote = localProvenance.remoteIdentifier {
                        return session.backup?.localIdentifierByRemoteId[remote] == localProvenance.localIdentifier
                    }
                }
                return true
            })
        MediaPresentationCoordinator.shared.imageArrived(binding.key)
        // Only the initial covered viewport needs another readiness layout.
        var ancestor = superview
        while let view = ancestor {
            if let grid = view as? TimelineGridView {
                if grid.initialPresentationCovered { grid.setNeedsLayout() }
                break
            }
            ancestor = view.superview
        }
        #if DEBUG && targetEnvironment(simulator)
        if phase4InjectOracleFault(key: key, binding: binding) { return }
        #endif
        guard fading else {
            imageView.image = image
            return
        }
        UIView.transition(
            with: imageView,
            duration: PhotosMotion.imageFadeDuration,
            options: [.transitionCrossDissolve, .curveEaseIn, .allowUserInteraction]
        ) {
            self.imageView.image = image
        }
    }

    var hasPreparedInitialImage: Bool {
        guard showsPicture, shownDisplayKey == activeDisplayKey,
              let surface = boundSurface, imageView.image === surface.image,
              let bitmap = surface.image.cgImage else { return false }
        return (min(bitmap.width, bitmap.height) >= Int(targetPixelSize.rounded(.up))
            || thumbnailState.phase == .ready)
    }

    var initialImageIsCurrent: Bool { boundSurface?.isCurrent() == true }

    var initialDisplayIsReady: Bool {
        // One failed derivative must not hide every successfully loaded photo.
        // A failed tile may reveal its retry control once no stale bitmap remains.
        (hasPreparedInitialImage && initialImageIsCurrent)
            || (thumbnailState.phase == .retry && imageView.image == nil)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Calibration only: corrupt the final on-screen pixels after a real,
    /// current entry-fixture binding. Never publish an injected surface.
    private func phase4InjectOracleFault(key: String, binding: SurfaceBinding) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard Phase4OwnedFixture.automaticPreparationName == "entry",
              let kind = env["IMORA_PHASE4_FAULT_KIND"], ["missing", "black", "wrong-subject"].contains(kind),
              let target = env["IMORA_PHASE4_FAULT_ASSET_ID"], target == asset?.id,
              let fixture = try? Phase4OwnedFixture.load("entry"), fixture.assets?.count == 96,
              fixture.assets?.contains(where: { $0.id == target }) == true,
              fixture.ownerID == binding.client.mediaDisplayScope.accountID,
              fixture.apiURL == binding.client.mediaDisplayScope.serverIdentity,
              !binding.requiresElevation, binding.isCurrent else { return false }
        func publish(_ image: UIImage?) {
            guard binding.isCurrent, projectionClient === binding.client, loadKey == key,
                  asset?.id == target, requestBinding?.key == binding.key else { return }
            imageView.image = image
            boundSurface = nil; boundSurfaceID = nil; shownDisplayKey = nil; showsPicture = false
            accessibilityValue = "phase4-oracle-\(kind)"
        }
        switch kind {
        case "missing": publish(nil)
        case "black":
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            publish(image)
        default:
            guard let wrong = env["IMORA_PHASE4_FAULT_WRONG_ID"], wrong != target,
                  fixture.assets?.contains(where: { $0.id == wrong }) == true else { return false }
            phase4OracleTask?.cancel()
            phase4OracleTask = Task { [weak self] in
                let url = binding.client.thumbnailURL(assetID: wrong)
                guard let surface = try? await ImageLoader.shared.boundImage(for: url, targetPixelSize: self?.targetPixelSize ?? 0),
                      !Task.isCancelled, surface.isCurrent, surface.key.scope == binding.key.scope,
                      surface.key.subject == .remoteAsset(wrong), let self else { return }
                guard binding.isCurrent, self.projectionClient === binding.client, self.loadKey == key,
                      self.asset?.id == target, self.requestBinding?.key == binding.key else { return }
                self.imageView.image = surface.image
                self.boundSurface = nil; self.boundSurfaceID = nil; self.shownDisplayKey = nil; self.showsPicture = false
                self.accessibilityValue = "phase4-oracle-\(kind)"
            }
        }
        return true
    }
    #endif

    private func reprojectAfterAccessChange(binding: SurfaceBinding, key: String) {
        guard projectionClient === binding.client, binding.client.context.isActive, loadKey == key,
              binding.access != MediaPresentationCoordinator.access(for: binding.client),
              let asset, let source = projectionSource else { return }
        loadKey = nil
        projectImage(asset: asset, source: source, client: binding.client,
            generation: ImageLoadRecovery.shared.generation, targetPixelSize: targetPixelSize)
    }

    #if DEBUG || PHASE4_PERFORMANCE
    func presentationMeasurement(in grid: UIView) -> GridFrameObservation.Tile? {
        guard let asset else { return nil }
        let rect = convert(bounds, to: grid.window)
        let image = imageView.image
        let width = image?.cgImage?.width ?? 0, height = image?.cgImage?.height ?? 0
        let real = showsPicture && image?.cgImage != nil && shownDisplayKey != nil
            && shownDisplayKey == activeDisplayKey && shownDisplayKey?.isCurrentContent == true
        return .init(assetID: asset.id,
            rect: [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
            bitmapPixels: [width, height], requestedPixels: Int(targetPixelSize.rounded(.up)),
            realBitmap: real, adequatePixels: min(width, height) >= Int(targetPixelSize.rounded(.up)),
            sourceRevision: shownDisplayKey?.sourceRevision ?? activeDisplayKey?.sourceRevision ?? "",
            contentGeneration: shownDisplayKey?.contentGeneration ?? "")
    }
    #endif

    /// a fade only earns its place over a flat placeholder, while the grid is
    /// slow enough for fades to read, and when the load was not instant.
    private func fades(since start: ContinuousClock.Instant) -> Bool {
        false
    }

    private func loadRemote(
        _ url: URL,
        previewURL: URL,
        key: String,
        generation: Int,
        thumbhash: String?,
        placeholder: UIImage?
    ) {
        begin(key: key, generation: generation)
        thumbnailState = ThumbnailLoadState(hasLocal: false, hasRemote: true, targetPixels: Double(targetPixelSize))
        if let cached = ImageLoader.shared.cachedSurface(for: url, targetPixelSize: targetPixelSize),
           min(cached.image.size.width, cached.image.size.height) * cached.image.scale >= targetPixelSize {
            _ = thumbnailState.remoteResult(pixels: Double(targetPixelSize), isPreview: true)
            show(cached.image, key: key, fading: false, binding: requestBinding, localProvenance: cached.localProvenance)
            return
        }
        imageView.image = placeholder
        visibleLocalIdentifier = placeholder == nil ? nil : projectionSource?.localIdentifier
        visibleLocalRevision = nil
        showsPicture = placeholder != nil
        if placeholder != nil { shownDisplayKey = activeDisplayKey }
        startRemote(url, previewURL: previewURL, key: key)
        guard motion?.isFast != true, let thumbhash, placeholder == nil else { return }
        let binding = requestBinding
        placeholderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, binding?.isCurrent == true, let self, self.loadKey == key, self.loadedKey != key else { return }
            let decoded = await Task.detached(priority: .utility) { Thumbhash.image(fromBase64: thumbhash) }.value
            guard !Task.isCancelled, binding?.isCurrent == true, self.loadKey == key, self.loadedKey != key, let decoded else { return }
            self.imageView.image = decoded
        }
    }

    /// Only the two derivative URLs are supplied. The grid has no original
    /// or video URL to accidentally select when either derivative fails.
    private func startRemote(_ url: URL, previewURL: URL, key: String) {
        guard remoteTask == nil else { return }
        let size = targetPixelSize
        let ratio = asset?.ratio ?? 1
        let binding = requestBinding
        remoteTask = Task { [weak self] in
            let start = ContinuousClock.now
            do {
                let loaded = try await ImageLoader.shared.gridThumbnail(
                    thumbnailURL: url, previewURL: previewURL, targetPixelSize: size, aspectRatio: ratio
                ) { [weak self] image in
                    guard binding?.isCurrent == true, let self, self.loadKey == key, self.loadedKey != key else { return }
                    self.imageView.image = image
                    self.showsPicture = true
                    self.shownDisplayKey = binding?.key
                }
                guard !Task.isCancelled, let self, self.loadKey == key, self.thumbnailState.phase != .ready else { return }
                _ = self.thumbnailState.remoteResult(pixels: Double(size), isPreview: true)
                self.show(loaded, key: key, fading: self.fades(since: start), binding: binding)
                self.deadlineTask?.cancel()
                self.loadTask?.cancel()
            } catch {
                guard !Task.isCancelled, let self, self.loadKey == key, self.thumbnailState.phase != .ready else { return }
                _ = self.thumbnailState.remoteResult(pixels: nil, isPreview: true)
                self.updateThumbnailStatus()
            }
        }
    }

    private func loadLocal(
        _ localIdentifier: String,
        key: String,
        generation: Int,
        allowsNetwork: Bool,
        placeholder: (image: UIImage, localProvenance: LocalSurfaceProvenance?)?,
        cacheScope: String,
        remoteURL: URL?,
        previewURL: URL?
    ) {
        begin(key: key, generation: generation)
        thumbnailState = ThumbnailLoadState(hasLocal: true, hasRemote: remoteURL != nil, targetPixels: Double(targetPixelSize))
        accessibilityValue = String(localized: "Loading")
        let size = targetPixelSize
        let binding = requestBinding
        if let binding, asset?.localIdentifier == localIdentifier {
            // A prepared final may outlive its optional preview in the smaller
            // preview cache. Bind the exact final now, under current access and
            // the actual PhotoKit revision, rather than awaiting a new delivery.
            guard let revision = LocalImageLoader.currentModificationRevision(localIdentifier),
                  binding.key.sourceRevision == revision else {
                imageView.image = nil; showsPicture = false; shownDisplayKey = nil
                boundSurface = nil; boundSurfaceID = nil
                visibleLocalIdentifier = nil; visibleLocalRevision = nil
                _ = thumbnailState.localUnavailable()
                updateThumbnailStatus()
                return
            }
            if let final = LocalImageLoader.shared.cachedImage(localIdentifier: localIdentifier, targetPixelSize: size,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: cacheScope) {
                _ = thumbnailState.localFinal(pixels: Double(size), originalPixels: Double(size))
                show(final, key: key, fading: false, binding: binding,
                    localProvenance: .init(localIdentifier: localIdentifier, modificationRevision: revision, remoteIdentifier: nil))
                return
            }
        }
        let shown = placeholder?.image ?? LocalImageLoader.shared.cachedPreview(localIdentifier: localIdentifier, cacheScope: cacheScope)
        imageView.image = shown
        visibleLocalIdentifier = placeholder == nil && shown != nil ? localIdentifier : placeholder?.localProvenance?.localIdentifier
        visibleLocalRevision = placeholder?.localProvenance?.modificationRevision
        showsPicture = shown != nil
        if shown != nil { shownDisplayKey = activeDisplayKey }
        if let placeholder, min(placeholder.image.size.width, placeholder.image.size.height) * placeholder.image.scale >= size {
            show(placeholder.image, key: key, fading: false, binding: binding, localProvenance: placeholder.localProvenance)
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, binding?.isCurrent == true, let self, self.loadKey == key else { return }
            let action = self.thumbnailState.localDeadline()
            self.updateThumbnailStatus()
            if action == .thumbnail, let remoteURL, let previewURL {
                self.startRemote(remoteURL, previewURL: previewURL, key: key)
            }
        }
        loadTask = Task { [weak self] in
            let start = ContinuousClock.now
            let revision = await Task.detached(priority: .userInitiated, operation: {
                LocalImageLoader.currentModificationRevision(localIdentifier)
            }).value
            guard let self, self.loadKey == key, let binding else { return }
            guard binding.access == self.projectionClient.map(MediaPresentationCoordinator.access(for:)) else {
                self.reprojectAfterAccessChange(binding: binding, key: key)
                return
            }
            guard let revision else {
                self.applyLocalAccessRevision(nil)
                if let remoteURL, let previewURL {
                    self.unavailableLocalIdentifier = localIdentifier
                    self.unavailableGeneration = generation
                    // Clearing private pixels revokes their surface, while
                    // the captured current remote request may still proceed.
                    self.loadKey = key
                    self.startRemote(remoteURL, previewURL: previewURL, key: key)
                }
                return
            }
            let provenance = LocalSurfaceProvenance(localIdentifier: localIdentifier, modificationRevision: revision,
                remoteIdentifier: self.asset?.localIdentifier == nil ? self.asset?.id : nil)
            if let backup = self.session?.backup, provenance.remoteIdentifier != nil,
               !(await backup.validatesLaunchSurface(provenance)) {
                self.unavailableLocalIdentifier = localIdentifier
                self.unavailableGeneration = generation
                if let remoteURL, let previewURL { self.startRemote(remoteURL, previewURL: previewURL, key: key) }
                return
            }
            guard binding.access == self.projectionClient.map(MediaPresentationCoordinator.access(for:)) else {
                self.reprojectAfterAccessChange(binding: binding, key: key)
                return
            }
            if let cached = LocalImageLoader.shared.cachedImage(localIdentifier: localIdentifier, targetPixelSize: size,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: cacheScope) {
                _ = self.thumbnailState.localFinal(pixels: Double(size), originalPixels: Double(size))
                self.show(cached, key: key, fading: false, binding: binding, localProvenance: provenance)
                self.deadlineTask?.cancel()
                return
            }
            let deliveries = LocalImageLoader.shared.deliveries(
                localIdentifier: localIdentifier, targetPixelSize: size,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                allowsNetwork: allowsNetwork, cacheScope: cacheScope
            )
            for await delivery in deliveries {
                guard !Task.isCancelled, binding.isCurrent, self.loadKey == key, self.thumbnailState.phase != .ready else { return }
                switch delivery {
                case .terminal(let outcome):
                    guard outcome.shouldTryAlternateSource else { continue }
                    let action = self.thumbnailState.localUnavailable()
                    if action == .thumbnail, let remoteURL, let previewURL {
                        self.startRemote(remoteURL, previewURL: previewURL, key: key)
                    }
                case .preview(let image):
                    self.thumbnailState.localPreview()
                    if placeholder == nil, self.loadedKey != key {
                        self.imageView.image = image
                        self.visibleLocalIdentifier = localIdentifier
                        self.visibleLocalRevision = revision
                        self.showsPicture = true
                        self.shownDisplayKey = binding.key
                    }
                case .final(let image):
                    // LocalImageLoader validates dimensions against the
                    // target and the original before emitting a final image.
                    _ = self.thumbnailState.localFinal(pixels: Double(size), originalPixels: Double(size))
                    guard LocalImageLoader.currentModificationRevision(localIdentifier) == revision else { return }
                    self.show(image, key: key, fading: self.fades(since: start), binding: binding, localProvenance: provenance)
                    self.remoteTask?.cancel()
                    self.deadlineTask?.cancel()
                }
                self.updateThumbnailStatus()
            }
            self.reprojectAfterAccessChange(binding: binding, key: key)
        }
    }

    // MARK: - badges

    private func updateAssetBadges(for asset: Asset) {
        topTrailingBadge?.removeFromSuperview()
        topTrailingBadge = nil
        if showsMediaBadges, asset.isLivePhoto {
            topTrailingBadge = TileGlyphBadge(.livePhoto)
        }
        durationBadge?.removeFromSuperview()
        durationBadge = nil
        if showsMediaBadges, let duration = asset.durationLabel {
            let label = UILabel()
            label.text = duration
            label.font = UIFontMetrics(forTextStyle: .caption2)
                .scaledFont(for: .systemFont(ofSize: 11, weight: .semibold))
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
            durationBadge = label
            content.addSubview(label)
        }

        topLeadingBadge?.removeFromSuperview()
        topLeadingBadge = nil
        if showsMediaBadges, asset.isStacked, let count = asset.stackCount {
            topLeadingBadge = TileCapsuleBadge(symbol: "square.stack.fill", text: "\(count)")
        }

        favoriteBadge?.removeFromSuperview()
        favoriteBadge = nil
        if showsMediaBadges, asset.isFavorite {
            favoriteBadge = TileGlyphBadge(.favorite)
        }

        for badge in [topTrailingBadge, topLeadingBadge, favoriteBadge].compactMap({ $0 }) {
            content.addSubview(badge)
        }
        setNeedsLayout()
    }

    private func updateBackupState(asset: Asset, backup: BackupManager?) {
        guard showsBackupBadge else { setBackupBadge(nil); return }
        let status = PhotoBackupStatus.resolve(asset: asset, backup: backup)
        setBackupBadge(status == .backedUp && !showsAllBackupStatuses ? nil : status.symbol)
    }

    private func setBackupBadge(_ name: String?) {
        guard name != backupBadgeName else { return }
        backupBadgeName = name
        backupBadge?.removeFromSuperview()
        backupBadge = nil
        guard let name else { return }
        let badge = TileGlyphBadge(.backup(name))
        badge.accessibilityIdentifier = "badge-\(name)"
        content.addSubview(badge)
        backupBadge = badge
        setNeedsLayout()
    }

    // MARK: - selection and removal

    func updateSelectionAppearance(isSelecting: Bool) {
        let appearance = (isSelecting: isSelecting, isSelected: isSelected, isSelectable: isSelectable)
        if let current = selectionAppearance, current == appearance { return }
        selectionAppearance = appearance
        setNeedsLayout()
        guard isSelecting, isSelectable, isSelected else {
            selectionIndicator?.isHidden = true
            return
        }
        let indicator = selectionIndicator ?? {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.isUserInteractionEnabled = false
            addSubview(view)
            selectionIndicator = view
            setNeedsLayout()
            return view
        }()
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
        indicator.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: configuration)
        // The first indicator has no frame yet. Lay it out outside the shell's
        // selection animation before revealing it, including on recycled tiles.
        UIView.performWithoutAnimation {
            self.layoutIfNeeded()
            indicator.layer.removeAllAnimations()
            indicator.isHidden = false
        }
    }

    /// projected removals hide in place until the server confirms them. the
    /// content fades rather than the tile, whose alpha the viewer's zoom owns
    /// while it is open.
    func setProjectedRemoved(_ removed: Bool, animated: Bool) {
        guard removed != isProjectedRemoved else { return }
        isProjectedRemoved = removed
        selectionIndicator?.alpha = removed ? 0 : 1
        let apply = { self.content.alpha = removed ? 0 : 1 }
        if animated {
            UIView.animate(withDuration: PhotosMotion.removalDuration, delay: 0, options: [.curveEaseOut], animations: apply)
        } else {
            apply()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isProjectedRemoved else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - layout

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        imageView.frame = bounds
        retryButton.frame = CGRect(x: bounds.midX - 18, y: bounds.midY - 18, width: 36, height: 36)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        func place(_ view: UIView?, leading: Bool, top: Bool, inset: CGFloat) {
            guard let view else { return }
            // glyph art carries room for its shadow around the glyph itself.
            let bleed = (view as? TileGlyphBadge)?.bleed ?? 0
            let size = view.sizeThatFits(bounds.size)
            let isLeft = leading != rightToLeft
            view.frame = CGRect(
                x: isLeft ? inset - bleed : bounds.width - inset - size.width + bleed,
                y: top ? inset - bleed : bounds.height - inset - size.height + bleed,
                width: size.width,
                height: size.height
            )
        }

        place(topTrailingBadge, leading: false, top: true, inset: topTrailingBadge is TileCapsuleBadge ? 5 : 7)
        place(durationBadge, leading: false, top: false, inset: 6)
        place(topLeadingBadge, leading: true, top: true, inset: 5)
        place(favoriteBadge, leading: true, top: false, inset: 6)
        place(backupBadge, leading: true, top: true, inset: 7)
        if let backupBadge, let topLeadingBadge {
            topLeadingBadge.frame.origin.x = rightToLeft
                ? backupBadge.frame.minX - topLeadingBadge.frame.width - 4
                : backupBadge.frame.maxX + 4
        }
        if let selectionIndicator {
            let x = rightToLeft ? 6 : bounds.width - 6 - 24
            selectionIndicator.frame = CGRect(x: x, y: bounds.height - 6 - 24, width: 24, height: 24)
            if selectionAppearance?.isSelected == true, let durationBadge {
                durationBadge.frame.origin.x += rightToLeft ? 30 : -30
            }
        }
    }

    // MARK: - accessibility

    /// built when asked rather than on every update of every tile.
    override var accessibilityLabel: String? {
        get {
            guard let asset else { return nil }
            var parts = [
                asset.isVideo ? String(localized: "Video") : (asset.isLivePhoto ? String(localized: "Live Photo") : String(localized: "Photo")),
                PhotoDatePresentation.dateTime(wallClock: asset.localDate),
            ]
            if let duration = asset.durationLabel { parts.append(duration) }
            if asset.isStacked, let count = asset.stackCount { parts.append(String(localized: "Stack of \(count)")) }
            if asset.isFavorite { parts.append(String(localized: "Favorite")) }
            if showsBackupBadge { parts.append(backupAccessibilitySummary(for: asset)) }
            return parts.joined(separator: ", ")
        }
        set {}
    }

    private func backupAccessibilitySummary(for asset: Asset) -> String {
        switch PhotoBackupStatus.resolve(asset: asset, backup: session?.backup) {
        case .backedUp: String(localized: "Backed up")
        case .notBackedUp: String(localized: "Not backed up")
        case .cloudDeleted: String(localized: "Deleted in Cloud")
        case .failed: String(localized: "Backup failed")
        case .sizeExcluded: String(localized: "Excluded from backup by the upload size limit")
        case .uploading(let fraction): String(localized: "Backing up, \(Int(fraction * 100)) percent")
        }
    }
}

/// a white glyph with a soft shadow, the corner badges of a tile. each kind is
/// drawn once by swiftui, shadow included, and every tile shows that one
/// bitmap: pixel for pixel the swiftui badge, with no symbol lookup, shadow
/// pass or rasterization per tile.
private final class TileGlyphBadge: UIImageView {
    enum Kind: Hashable {
        case livePhoto
        case favorite
        /// backup status, by symbol name.
        case backup(String)
    }

    /// transparent margin around the glyph, room for its shadow.
    static let bleed: CGFloat = 8
    let bleed = TileGlyphBadge.bleed

    private struct Art {
        let image: UIImage
        let sizeCategory: UIContentSizeCategory
    }

    private static var art: [Kind: Art] = [:]

    init(_ kind: Kind) {
        super.init(image: Self.image(for: kind))
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        image?.size ?? .zero
    }

    /// redrawn when the text size changes, since two kinds follow it.
    private static func image(for kind: Kind) -> UIImage? {
        let category = UITraitCollection.current.preferredContentSizeCategory
        if let drawn = art[kind], drawn.sizeCategory == category {
            return drawn.image
        }
        let renderer = ImageRenderer(content: glyph(for: kind).padding(bleed))
        renderer.scale = UITraitCollection.current.displayScale
        guard let image = renderer.uiImage else { return nil }
        art[kind] = Art(image: image, sizeCategory: category)
        return image
    }

    /// the same views the swiftui tile drew in its corners.
    @ViewBuilder
    private static func glyph(for kind: Kind) -> some View {
        switch kind {
        case .livePhoto:
            Image(systemName: "livephoto")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
        case .favorite:
            Image(systemName: "heart.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
        case .backup(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2.5)
        }
    }
}

/// a glyph and a short label on a dark capsule: video length, stack count.
private final class TileCapsuleBadge: UIView {
    private let icon = UIImageView()
    private let label = UILabel()
    /// measured against swiftui's label at caption2, glyph ink to glyph ink.
    private static let spacing: CGFloat = 10.2
    private static let padding = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 5.67)

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.4)
        let font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11, weight: .semibold))
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(font: font)
        )
        icon.tintColor = .white
        label.text = text
        label.font = font
        label.textColor = .white
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let iconSize = icon.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        let padding = Self.padding
        return CGSize(
            width: (padding.left + iconSize.width + Self.spacing + labelSize.width + padding.right).rounded(.up),
            height: (padding.top + max(iconSize.height, labelSize.height) + padding.bottom).rounded(.up)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let iconSize = icon.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var iconX = Self.padding.left
        var labelX = iconX + iconSize.width + Self.spacing
        if rightToLeft {
            labelX = Self.padding.left
            iconX = labelX + labelSize.width + Self.spacing
        }
        icon.frame = CGRect(
            x: iconX,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        label.frame = CGRect(
            x: labelX,
            y: (bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }
}
