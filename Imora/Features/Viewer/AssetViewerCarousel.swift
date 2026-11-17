import SwiftUI
import UIKit

struct AssetViewerCarousel: UIViewRepresentable {
    let assets: [Asset]
    let indexByAssetID: [String: Int]
    @Binding var selection: String?
    let aspectRatio: (Asset) -> Double
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> AssetViewerCarouselCollectionView {
        AssetViewerCarouselCollectionView()
    }

    func updateUIView(_ view: AssetViewerCarouselCollectionView, context: Context) {
        view.onSelection = { selection = $0 }
        view.apply(assets: assets, indexByID: indexByAssetID, selection: selection,
                   session: session, reduceMotion: reduceMotion, aspectRatio: aspectRatio)
    }

    static func dismantleUIView(_ view: AssetViewerCarouselCollectionView, coordinator: ()) {
        view.cancelThumbnailLoads()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AssetViewerCarouselCollectionView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: AssetViewerCarouselGeometry.height)
    }
}

/// Known sliver widths let a distant selection and the visible interval be
/// located without laying out the photos that precede them in the library.
nonisolated struct AssetViewerCarouselGeometry: Equatable {
    static let height: CGFloat = 52
    static let imageHeight: CGFloat = 30
    static let collapsedWidth: CGFloat = 18
    static let spacing: CGFloat = 2
    static let expandedMargin: CGFloat = 10
    let count: Int
    let expandedIndex: Int?
    let expandedAspectRatio: Double
    var viewportWidth: CGFloat
    var isRightToLeft = false

    private var step: CGFloat { Self.collapsedWidth + Self.spacing }
    private var expandedWidth: CGFloat {
        let ratio = expandedAspectRatio.isFinite ? min(1.6, max(1, expandedAspectRatio)) : 1
        return Self.imageHeight * CGFloat(ratio) + Self.expandedMargin * 2
    }
    private var extraWidth: CGFloat { expandedIndex == nil ? 0 : expandedWidth - Self.collapsedWidth }
    private var leading: CGFloat { max(0, (viewportWidth - width(at: 0)) / 2) }
    private var trailing: CGFloat { max(0, (viewportWidth - width(at: count - 1)) / 2) }

    var contentSize: CGSize {
        CGSize(width: count > 0 ? leading + CGFloat(count) * step - Self.spacing + extraWidth + trailing : viewportWidth,
               height: Self.height)
    }

    func width(at index: Int) -> CGFloat {
        index == expandedIndex ? expandedWidth : Self.collapsedWidth
    }

    func frame(at index: Int) -> CGRect {
        let x = leading + CGFloat(index) * step + (expandedIndex.map { index > $0 } == true ? extraWidth : 0)
        let width = width(at: index)
        return CGRect(x: isRightToLeft ? contentSize.width - x - width : x,
                      y: 0, width: width, height: Self.height)
    }

    func offset(centering index: Int) -> CGFloat {
        min(max(0, frame(at: index).midX - viewportWidth / 2), max(0, contentSize.width - viewportWidth))
    }

    func index(nearest x: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        var relative = (isRightToLeft ? contentSize.width - x : x) - leading
        if let expandedIndex {
            let start = CGFloat(expandedIndex) * step
            if relative >= start, relative <= start + expandedWidth { return expandedIndex }
            if relative > start { relative -= extraWidth }
        }
        return min(count - 1, max(0, Int(((relative - Self.collapsedWidth / 2) / step).rounded())))
    }

    func indices(intersecting rect: CGRect) -> Range<Int> {
        guard let first = index(nearest: rect.minX), let last = index(nearest: rect.maxX) else { return 0..<0 }
        return max(0, min(first, last) - 1)..<min(count, max(first, last) + 2)
    }
}

final class AssetViewerCarouselLayout: UICollectionViewLayout {
    var geometry = AssetViewerCarouselGeometry(count: 0, expandedIndex: nil, expandedAspectRatio: 1, viewportWidth: 0)

    override func prepare() {
        super.prepare()
        geometry.viewportWidth = collectionView?.bounds.width ?? 0
    }
    override var collectionViewContentSize: CGSize { geometry.contentSize }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.indices(intersecting: rect).compactMap {
            let attributes = layoutAttributesForItem(at: IndexPath(item: $0, section: 0))!
            return attributes.frame.intersects(rect) ? attributes : nil
        }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard (0..<geometry.count).contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(at: indexPath.item)
        return attributes
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != geometry.viewportWidth
    }
}

private final class AssetViewerCarouselCell: UICollectionViewCell {
    var onActivate: (() -> Void)?
    private let thumbnail = TimelineTileView(frame: .zero)
    private let motion = GridMotion()
    private var asset: Asset?
    private var expanded = false
    private weak var session: SessionStore?

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.isUserInteractionEnabled = false
        thumbnail.isAccessibilityElement = false
        thumbnail.accessibilityElementsHidden = true
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerCurve = .continuous
        contentView.addSubview(thumbnail)
        isAccessibilityElement = true
        accessibilityIdentifier = "asset-tile"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearThumbnail()
    }

    func clearThumbnail() {
        thumbnail.prepareForReuse()
        onActivate = nil
        asset = nil
        session = nil
    }

    func retryIfNeeded() -> Bool {
        thumbnail.retryIfNeeded(at: CGPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY))
    }

    override func accessibilityActivate() -> Bool {
        if retryIfNeeded() { return true }
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    func configure(asset: Asset, expanded: Bool, selected: Bool, session: SessionStore) {
        if self.asset != asset || self.session !== session {
            self.asset = asset
            self.session = session
            thumbnail.configure(asset: asset, session: session, motion: motion,
                showsBackupBadge: false, targetPixelSize: 120, registry: nil, showsMediaBadges: false)
        }
        if self.expanded != expanded {
            self.expanded = expanded
            setNeedsLayout()
        }
        thumbnail.layer.cornerRadius = expanded ? 5 : 3
        accessibilityTraits = selected ? [.button, .selected] : [.button]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = expanded ? AssetViewerCarouselGeometry.expandedMargin : 0
        thumbnail.frame = CGRect(x: margin, y: (bounds.height - AssetViewerCarouselGeometry.imageHeight) / 2,
            width: max(0, bounds.width - margin * 2), height: AssetViewerCarouselGeometry.imageHeight)
    }

    override var accessibilityLabel: String? {
        get { thumbnail.accessibilityLabel }
        set {}
    }
    override var accessibilityValue: String? {
        get { thumbnail.accessibilityValue }
        set {}
    }
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { thumbnail.accessibilityCustomActions }
        set {}
    }
}

final class AssetViewerCarouselCollectionView: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onSelection: (String) -> Void = { _ in }
    private let stripLayout = AssetViewerCarouselLayout()
    private var assets: [Asset] = []
    private var indexByID: [String: Int] = [:]
    private var selectedID: String?
    private var session: SessionStore?
    private var reduceMotion = false
    private var aspectRatio: (Asset) -> Double = { $0.ratio }
    private var isScrubbing = false
    private var isPositioning = false
    private var didPosition = false
    private var lastWidth: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private let feedback = UISelectionFeedbackGenerator()

    init() {
        super.init(frame: .zero, collectionViewLayout: stripLayout)
        dataSource = self
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        register(AssetViewerCarouselCell.self, forCellWithReuseIdentifier: "thumbnail")
        accessibilityLabel = String(localized: "Thumbnails")
        accessibilityIdentifier = "viewer-carousel"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancelThumbnailLoads() {
        animator?.stopAnimation(true)
        animator = nil
        for case let cell as AssetViewerCarouselCell in visibleCells { cell.clearThumbnail() }
    }

    func apply(assets: [Asset], indexByID: [String: Int], selection: String?, session: SessionStore,
               reduceMotion: Bool, aspectRatio: @escaping (Asset) -> Double) {
        let contentChanged = self.assets != assets || self.session !== session
        let selectionChanged = selectedID != selection
        let expandedID = stripLayout.geometry.expandedIndex.flatMap {
            self.assets.indices.contains($0) ? self.assets[$0].id : nil
        }
        if contentChanged, isScrubbing,
           self.assets.count != assets.count || !zip(self.assets, assets).allSatisfy({ $0.id == $1.id }) {
            isScrubbing = false
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
        }
        self.assets = assets
        self.indexByID = indexByID
        selectedID = selection
        self.session = session
        self.reduceMotion = reduceMotion
        self.aspectRatio = aspectRatio
        if contentChanged {
            let expanded = index(for: isScrubbing ? expandedID : selectedID)
            stripLayout.geometry = AssetViewerCarouselGeometry(count: assets.count, expandedIndex: expanded,
                expandedAspectRatio: expanded.map { aspectRatio(assets[$0]) } ?? 1, viewportWidth: bounds.width,
                isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
            stripLayout.invalidateLayout()
            reloadData()
        }
        guard !isScrubbing else { return }
        positionSelection(animated: didPosition && selectionChanged && !contentChanged)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        positionSelection(animated: false)
    }
    private func index(for id: String?) -> Int? {
        guard let id, let index = indexByID[id], assets.indices.contains(index), assets[index].id == id else { return nil }
        return index
    }
    private func positionSelection(animated: Bool) {
        guard bounds.width > 0 else { return }
        let index = index(for: selectedID)
        let geometry = AssetViewerCarouselGeometry(count: assets.count, expandedIndex: index,
            expandedAspectRatio: index.map { aspectRatio(assets[$0]) } ?? 1, viewportWidth: bounds.width,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
        let needsLayout = geometry != stripLayout.geometry
        let target = index.map { CGPoint(x: geometry.offset(centering: $0), y: 0) } ?? .zero
        guard needsLayout || target != contentOffset || !didPosition else { return }
        animator?.stopAnimation(true)
        animator = nil
        isPositioning = true
        let updates = { [weak self] in
            guard let self else { return }
            if needsLayout {
                self.stripLayout.geometry = geometry
                self.stripLayout.invalidateLayout()
            }
            self.contentOffset = target
            self.layoutIfNeeded()
            self.configureVisibleCells()
        }
        if animated && !reduceMotion {
            let animator = PhotosMotion.springAnimator(duration: PhotosMotion.layoutDuration, animations: updates)
            self.animator = animator
            animator.startAnimation()
        } else {
            UIView.performWithoutAnimation(updates)
        }
        didPosition = true
        isPositioning = false
    }
    private func configureVisibleCells() {
        guard let session else { return }
        for case let cell as AssetViewerCarouselCell in visibleCells {
            guard let index = indexPath(for: cell)?.item, assets.indices.contains(index) else { continue }
            cell.configure(asset: assets[index], expanded: index == stripLayout.geometry.expandedIndex,
                           selected: assets[index].id == selectedID, session: session)
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "thumbnail", for: indexPath) as! AssetViewerCarouselCell
        if let session {
            cell.configure(asset: assets[indexPath.item], expanded: indexPath.item == stripLayout.geometry.expandedIndex,
                           selected: assets[indexPath.item].id == selectedID, session: session)
        }
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell, let index = self.indexPath(for: cell)?.item else { return }
            self.select(index: index)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let cell = cellForItem(at: indexPath) as? AssetViewerCarouselCell, cell.retryIfNeeded() { return }
        select(index: indexPath.item)
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? AssetViewerCarouselCell)?.clearThumbnail()
    }
    private func select(index: Int) {
        guard assets.indices.contains(index), assets[index].id != selectedID else { return }
        selectedID = assets[index].id
        onSelection(assets[index].id)
        positionSelection(animated: true)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        animator?.stopAnimation(true)
        animator = nil
        isScrubbing = true
        feedback.prepare()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isScrubbing, !isPositioning,
              let index = stripLayout.geometry.index(nearest: contentOffset.x + bounds.width / 2),
              assets.indices.contains(index), selectedID != assets[index].id else { return }
        selectedID = assets[index].id
        onSelection(assets[index].id)
        configureVisibleCells()
        feedback.selectionChanged()
        feedback.prepare()
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let index = stripLayout.geometry.index(nearest: targetContentOffset.pointee.x + bounds.width / 2) else { return }
        targetContentOffset.pointee.x = stripLayout.geometry.offset(centering: index)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { endScrubbing() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endScrubbing() }
    private func endScrubbing() {
        isScrubbing = false
        positionSelection(animated: true)
    }
}
