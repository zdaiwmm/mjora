import Foundation
import SwiftUI
import UIKit

/// exact top offset of every row, in row space. deterministic row heights
/// make this a plain prefix sum, rebuilt only when the rows or the tile side
/// change.
struct TimelineRowLayout {
    let version: Int
    let side: CGFloat
    let starts: [CGFloat]
    let total: CGFloat

    static let empty = TimelineRowLayout(version: -1, side: 0, starts: [], total: 0)

    static func build(rows: [TimelineRow], side: CGFloat, version: Int) -> TimelineRowLayout {
        var starts: [CGFloat] = []
        starts.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for row in rows {
            starts.append(y)
            y += row.height(tileSide: side)
        }
        return TimelineRowLayout(version: version, side: side, starts: starts, total: y)
    }

    /// index of the row whose span contains `y`, clamped to the ends.
    func index(at y: CGFloat) -> Int {
        var low = 0
        var high = starts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= y {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

/// the one copy of the layout above, shared by the screen and its grid.
@MainActor
final class TimelineRowLayoutBox {
    private var cached = TimelineRowLayout.empty

    func layout(for model: TimelineModel, side: CGFloat) -> TimelineRowLayout {
        if cached.version != model.rowsLayoutVersion || cached.side != side {
            cached = .build(rows: model.rows, side: side, version: model.rowsLayoutVersion)
        }
        return cached
    }
}

/// what the grid reports on every scroll, layout or inset change.
struct TimelineGridScroll: Equatable {
    /// distance scrolled past the rest position.
    let offsetY: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    /// the scroll view's height inside its insets.
    let containerHeight: CGFloat
}

/// everything the rows are drawn from beyond the rows themselves.
struct TimelineGridRowContext {
    let session: SessionStore
    let columns: Int
    let targetPixelSize: CGFloat
    let showsBackupBadge: Bool
    let usesOriginalAspectRatio: Bool
    let isSelecting: Bool
    let selection: Set<String>
    let reduceMotion: Bool
    let registry: AssetTileRegistry
    let motion: GridMotion
    let isSelectable: (Asset) -> Bool
    let isSelectableAssetID: (String) -> Bool
    let actions: TimelineTileActions
    let toggleDay: (_ ids: [String], _ selects: Bool) -> Void

    /// the inputs a mounted row draws differently for. the closures are
    /// rebuilt on every screen update but answer the same.
    func looksSame(as other: TimelineGridRowContext) -> Bool {
        columns == other.columns
            && targetPixelSize == other.targetPixelSize
            && showsBackupBadge == other.showsBackupBadge
            && usesOriginalAspectRatio == other.usesOriginalAspectRatio
            && isSelecting == other.isSelecting
            && reduceMotion == other.reduceMotion
            && (actions.pick == nil) == (other.actions.pick == nil)
            && session === other.session
            && registry === other.registry
            && selection == other.selection
    }
}

struct TimelineGridEvents {
    var onScroll: (TimelineGridScroll) -> Void = { _ in }
    var onIdleChanged: (Bool) -> Void = { _ in }
    var onHeaderHeight: (CGFloat) -> Void = { _ in }
    var onFooterHeight: (CGFloat) -> Void = { _ in }
    var onPlaceholder: (_ bucketID: String) -> Void = { _ in }
    var onPinch: (_ magnification: CGFloat) -> Void = { _ in }
    var onPinchEnded: () -> Void = {}
    /// runs on every update with the scroll view, for the gestures riding it.
    var configureScrollView: (UIScrollView) -> Void = { _ in }
    var onDismantle: () -> Void = {}
}

/// the screen's handle on its grid, for what swiftui used to do through
/// ScrollPosition. plain, nothing here is observed.
@MainActor
final class TimelineGridController {
    var scrollOffset: CGFloat { grid?.offsetY ?? 0 }
    var endOffset: CGFloat {
        guard let grid else { return 0 }
        return max(0, grid.contentSize.height - grid.bounds.height
                   + grid.adjustedContentInset.top + grid.adjustedContentInset.bottom)
    }
    fileprivate weak var grid: TimelineGridView?

    /// 1 towards the bottom, -1 towards the top, 0 while slow or at rest.
    /// leans the mounted rows the way the grid is going.
    var direction = 0 {
        didSet {
            if direction != oldValue { grid?.setNeedsLayout() }
        }
    }

    /// distance past the rest position, like ScrollPosition's scrollTo(y:).
    func scrollTo(y: CGFloat) {
        guard let grid else { return }
        grid.layoutIfNeeded()
        let end = max(0, grid.contentSize.height - grid.bounds.height
                      + grid.adjustedContentInset.top + grid.adjustedContentInset.bottom)
        grid.scroll(toOffsetY: min(max(0, y), end))
    }

    func scrollToTop() {
        grid?.scroll(toOffsetY: 0)
    }

    func scrollToEnd() {
        guard let grid else { return }
        grid.layoutIfNeeded()
        let lastOffset = max(0, grid.contentSize.height - grid.bounds.height
                             + grid.adjustedContentInset.top + grid.adjustedContentInset.bottom)
        grid.scroll(toOffsetY: lastOffset)
    }

    /// lays the model's rows out right away instead of at the next pass, so
    /// a swap and the offset that compensates it land in one frame. inside an
    /// animation block, rows that move animate there.
    func reloadRows(animated: Bool) {
        grid?.reloadRows(animated: animated)
    }
}

extension EnvironmentValues {
    /// whether the grid's footer is on screen. the footer is hosted outside
    /// any swiftui scroll view, so scroll visibility modifiers never fire.
    @Entry var timelineFooterIsVisible = false
}

@Observable @MainActor
final class TimelineGridFooterState {
    var isVisible = false
}

/// header and footer content, measured at its own ideal height.
struct TimelineGridSection<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    let footerState: TimelineGridFooterState?
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) { content }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            // exact, not rounded: the host is sized to it, and a host taller
            // than its content centers it a fraction of a point low.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onHeight(height)
            }
            .environment(\.timelineFooterIsVisible, footerState?.isVisible ?? false)
            // the hosting controller starts from an empty environment, so the
            // whole screen's is handed down: sessions, navigation, dismiss.
            .environment(\.self, environment)
    }
}

/// the grid as a plain uikit scroll view. swiftui's ScrollView diffed the
/// mounted rows on every window slide and ran its own geometry pass every
/// frame. here the rows are placed by the exact layout and diffed by index,
/// and swiftui only hears about the offset.
struct TimelineGrid<Header: View, Footer: View>: UIViewControllerRepresentable {
    let model: TimelineModel
    let controller: TimelineGridController
    let layoutBox: TimelineRowLayoutBox
    let side: CGFloat
    let tailPadding: CGFloat
    let rowContext: TimelineGridRowContext
    let hidesEdgeEffects: Bool
    let refresh: RefreshAction?
    let events: TimelineGridEvents
    let header: Header
    let footer: Footer

    final class Coordinator {
        var header: UIHostingController<TimelineGridSection<Header>>?
        var footer: UIHostingController<TimelineGridSection<Footer>>?
        let footerState = TimelineGridFooterState()
        var onDismantle: () -> Void = {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> TimelineGridViewController {
        let grid = TimelineGridViewController(model: model, layoutBox: layoutBox)
        let coordinator = context.coordinator
        let header = UIHostingController(rootView: headerSection(grid: grid, context: context))
        let footer = UIHostingController(rootView: footerSection(grid: grid, context: context))
        // the sections sit inside the scroll view, so the bars they pass
        // under must not grow their safe area and push their content around.
        header.safeAreaRegions = []
        footer.safeAreaRegions = []
        coordinator.header = header
        coordinator.footer = footer
        grid.install(header: header, footer: footer)
        grid.grid.controller = controller
        grid.grid.onFooterVisible = { [weak footerState = coordinator.footerState] visible in
            if footerState?.isVisible != visible { footerState?.isVisible = visible }
        }
        controller.grid = grid.grid
        apply(to: grid, context: context, animated: false)
        return grid
    }

    func updateUIViewController(_ grid: TimelineGridViewController, context: Context) {
        context.coordinator.header?.rootView = headerSection(grid: grid, context: context)
        context.coordinator.footer?.rootView = footerSection(grid: grid, context: context)
        grid.measureSections()
        controller.grid = grid.grid
        let transaction = context.transaction
        if transaction.animation != nil, !transaction.disablesAnimations {
            context.animate {
                apply(to: grid, context: context, animated: true)
                grid.grid.layoutIfNeeded()
            }
        } else {
            apply(to: grid, context: context, animated: false)
        }
    }

    static func dismantleUIViewController(_ grid: TimelineGridViewController, coordinator: Coordinator) {
        coordinator.onDismantle()
    }

    private func apply(to grid: TimelineGridViewController, context: Context, animated: Bool) {
        context.coordinator.onDismantle = events.onDismantle
        grid.events = events
        grid.setRefresh(refresh)
        grid.setEdgeEffectsHidden(hidesEdgeEffects)
        grid.grid.update(side: side, tailPadding: tailPadding, context: rowContext, animated: animated)
        events.configureScrollView(grid.grid)
    }

    private func headerSection(grid: TimelineGridViewController, context: Context) -> TimelineGridSection<Header> {
        TimelineGridSection(content: header, environment: context.environment, footerState: nil) { [weak grid] height in
            grid?.setHeaderHeight(height)
        }
    }

    private func footerSection(grid: TimelineGridViewController, context: Context) -> TimelineGridSection<Footer> {
        TimelineGridSection(
            content: footer,
            environment: context.environment,
            footerState: context.coordinator.footerState
        ) { [weak grid] height in
            grid?.setFooterHeight(height)
        }
    }
}

final class TimelineGridViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let grid: TimelineGridView
    var events = TimelineGridEvents()
    private var header: UIViewController?
    private var footer: UIViewController?
    private var isIdle = true
    private var refreshAction: RefreshAction?
    private var refreshTask: Task<Void, Never>?

    init(model: TimelineModel, layoutBox: TimelineRowLayoutBox) {
        grid = TimelineGridView(model: model, layoutBox: layoutBox)
        super.init(nibName: nil, bundle: nil)
        grid.delegate = self
        grid.onScroll = { [weak self] scroll in self?.events.onScroll(scroll) }
        grid.onPlaceholder = { [weak self] bucketID in self?.events.onPlaceholder(bucketID) }
        grid.onWidthChange = { [weak self] in self?.measureSections() }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        grid.addGestureRecognizer(pinch)
        grid.pinch = pinch
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// the scroll view sits in a plain container: as a controller's root
    /// view, every scroll frame's layout also recomputed the controller's
    /// insets against the navigation bar.
    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        grid.frame = container.bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(grid)
        view = container
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // the bars read their edge effects and scroll tracking off the
        // screen the navigation controller holds, which is swiftui's.
        var candidate: UIViewController? = self
        while let current = candidate {
            if current.parent == nil || current.parent is UINavigationController {
                current.setContentScrollView(grid, for: [.top, .bottom])
                break
            }
            candidate = current.parent
        }
    }

    func install(header: UIViewController, footer: UIViewController) {
        for host in [header, footer] {
            addChild(host)
            host.view.backgroundColor = .clear
            grid.addSubview(host.view)
            host.didMove(toParent: self)
        }
        self.header = header
        self.footer = footer
        grid.headerView = header.view
        grid.footerView = footer.view
    }

    /// the geometry callback only fires once a host lays out, and a host
    /// still sized to nothing may never, so the sections are also measured
    /// on every update and every width change.
    func measureSections() {
        let width = grid.contentWidth
        guard width > 0 else { return }
        let fitting = CGSize(width: width, height: .greatestFiniteMagnitude)
        if let header {
            setHeaderHeight(header.view.sizeThatFits(fitting).height)
        }
        if let footer {
            setFooterHeight(footer.view.sizeThatFits(fitting).height)
        }
    }

    func setHeaderHeight(_ height: CGFloat) {
        guard grid.headerHeight != height else { return }
        grid.headerHeight = height
        events.onHeaderHeight(height)
    }

    func setFooterHeight(_ height: CGFloat) {
        guard grid.footerHeight != height else { return }
        grid.footerHeight = height
        events.onFooterHeight(height)
    }

    func setRefresh(_ action: RefreshAction?) {
        refreshAction = action
        if action == nil {
            if grid.refreshControl != nil { grid.refreshControl = nil }
        } else if grid.refreshControl == nil {
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
            grid.refreshControl = control
        }
    }

    func setEdgeEffectsHidden(_ hidden: Bool) {
        for effect in [grid.topEdgeEffect, grid.bottomEdgeEffect, grid.leftEdgeEffect, grid.rightEdgeEffect]
        where effect.isHidden != hidden {
            effect.isHidden = hidden
        }
    }

    @objc private func refreshRequested() {
        refreshTask?.cancel()
        guard let refreshAction else {
            grid.refreshControl?.endRefreshing()
            return
        }
        refreshTask = Task { [weak self] in
            await refreshAction()
            self?.grid.refreshControl?.endRefreshing()
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            events.onPinch(recognizer.scale)
        case .ended, .cancelled, .failed:
            events.onPinchEnded()
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: - phase

    private func setIdle(_ idle: Bool) {
        guard isIdle != idle else { return }
        isIdle = idle
        events.onIdleChanged(idle)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        grid.setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setIdle(false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { setIdle(true) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setIdle(true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setIdle(true)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        setIdle(false)
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        setIdle(true)
    }
}

/// the scroll view itself. rows are mounted around the viewport from the
/// exact layout, diffed by index while the rows hold and by id when they
/// are swapped, and handed back to per-kind pools when they leave.
final class TimelineGridView: UIScrollView {
    private enum Kind {
        case tiles
        case band
        case placeholder
    }

    private struct MountedRow {
        let id: String
        let kind: Kind
        var row: TimelineRow
        let view: UIView
    }

    /// how far past the viewport rows stay mounted at rest, so a swipe
    /// reveals content that already exists and placeholder loads run ahead
    /// of arrival.
    private static let buffer: CGFloat = 360
    /// in motion the buffer leans the way the grid is going: rows ahead get
    /// the time to load that a fling would otherwise deny them, and the trail
    /// behind is released sooner.
    private static let bufferAhead: CGFloat = 900
    private static let bufferBehind: CGFloat = 240
    private static let poolLimit = 24

    weak var model: TimelineModel?
    weak var controller: TimelineGridController?
    private let layoutBox: TimelineRowLayoutBox

    var headerView: UIView?
    var footerView: UIView?
    var headerHeight: CGFloat = 0 {
        didSet { if headerHeight != oldValue { setNeedsLayout() } }
    }
    var footerHeight: CGFloat = 0 {
        didSet { if footerHeight != oldValue { setNeedsLayout() } }
    }
    var onScroll: ((TimelineGridScroll) -> Void)?
    var onPlaceholder: ((String) -> Void)?
    var onFooterVisible: ((Bool) -> Void)?
    var onWidthChange: (() -> Void)?
    weak var pinch: UIGestureRecognizer?

    private var side: CGFloat = 0
    private var tailPadding: CGFloat = 0
    private var context: TimelineGridRowContext?
    private var contextVersion = 0

    private var mounted: [MountedRow] = []
    private var mountedRange: Range<Int> = 0..<0
    private var mountedVersion = -1
    private var mountedContentVersion = -1
    private var mountedContextVersion = -1
    private var mountedSide: CGFloat = 0
    private var mountedWidth: CGFloat = 0
    private var mountedHeaderHeight: CGFloat = -1
    private var mountedRemovals = Set<String>()
    private var tileRowPool: [TimelineTileRowView] = []
    private var bandPool: [TimelineTitleBandView] = []
    private var placeholderPool: [TimelinePlaceholderView] = []
    /// rows that move or arrive inside the current pass animate there.
    private var animatesLayout = false

    private var lastScroll: TimelineGridScroll?
    private var footerVisible = false
    /// the distance past rest the grid last sat at, and the top inset it was
    /// measured against. an inset change keeps the distance, like swiftui did.
    private var restOffsetY: CGFloat = 0
    private var appliedInsetTop: CGFloat?

    init(model: TimelineModel, layoutBox: TimelineRowLayoutBox) {
        self.model = model
        self.layoutBox = layoutBox
        super.init(frame: .zero)
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .always
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        keyboardDismissMode = .interactive
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentWidth: CGFloat {
        max(0, bounds.width - adjustedContentInset.left - adjustedContentInset.right)
    }
    private var measuredWidth: CGFloat = 0

    var offsetY: CGFloat {
        contentOffset.y + adjustedContentInset.top
    }

    func scroll(toOffsetY y: CGFloat) {
        restOffsetY = y
        let target = CGPoint(x: -adjustedContentInset.left, y: y - adjustedContentInset.top)
        if contentOffset != target { setContentOffset(target, animated: false) }
    }

    func reloadRows(animated: Bool) {
        animatesLayout = animated
        setNeedsLayout()
        layoutIfNeeded()
        animatesLayout = false
    }

    func update(side: CGFloat, tailPadding: CGFloat, context: TimelineGridRowContext, animated: Bool) {
        var changed = false
        if self.side != side {
            self.side = side
            changed = true
        }
        if self.tailPadding != tailPadding {
            self.tailPadding = tailPadding
            changed = true
        }
        if let current = self.context, current.looksSame(as: context) {
            self.context = context
        } else {
            self.context = context
            contextVersion &+= 1
            changed = true
        }
        guard changed else { return }
        if animated {
            reloadRows(animated: true)
        } else {
            setNeedsLayout()
        }
    }

    // MARK: - layout

    override func layoutSubviews() {
        super.layoutSubviews()
        keepRestOffset()
        guard let model else { return }
        // read on every pass: uikit tracks the reads, so a swap or a
        // projected removal lays the grid out again on its own.
        let rows = model.rows
        let removals = model.projectedRemovalIDs
        let layout = layoutBox.layout(for: model, side: side)
        let insets = adjustedContentInset
        let width = contentWidth
        if width != measuredWidth {
            measuredWidth = width
            onWidthChange?()
        }

        let size = CGSize(width: width, height: headerHeight + layout.total + footerHeight + tailPadding)
        if contentSize != size { contentSize = size }
        place(headerView, CGRect(x: 0, y: 0, width: width, height: headerHeight))
        let footerFrame = CGRect(x: 0, y: headerHeight + layout.total, width: width, height: footerHeight)
        place(footerView, footerFrame)

        let scroll = TimelineGridScroll(
            offsetY: offsetY,
            insetTop: insets.top,
            insetBottom: insets.bottom,
            containerHeight: max(1, bounds.height - insets.top - insets.bottom)
        )
        if scroll != lastScroll {
            lastScroll = scroll
            onScroll?(scroll)
        }

        mount(rows: rows, layout: layout, removals: removals, width: width, viewportHeight: scroll.containerHeight)

        let visibleFooter = footerHeight > 0
            && bounds.intersection(footerFrame).height >= footerHeight * 0.1
        if visibleFooter != footerVisible {
            footerVisible = visibleFooter
            onFooterVisible?(visibleFooter)
        }
    }

    private func place(_ view: UIView?, _ frame: CGRect) {
        guard let view, view.frame != frame else { return }
        view.frame = frame
    }

    /// keeps the distance past rest across inset changes, the first layout
    /// included: a scroll view starts at a zero offset, which sits under the
    /// bar once the insets arrive.
    private func keepRestOffset() {
        let top = adjustedContentInset.top
        if top != appliedInsetTop {
            appliedInsetTop = top
            if !isTracking, !isDecelerating {
                let target = CGPoint(x: -adjustedContentInset.left, y: restOffsetY - top)
                if contentOffset != target { contentOffset = target }
            }
        }
        restOffsetY = contentOffset.y + top
    }

    private func mount(
        rows: [TimelineRow],
        layout: TimelineRowLayout,
        removals: Set<String>,
        width: CGFloat,
        viewportHeight: CGFloat
    ) {
        let count = min(rows.count, layout.starts.count)
        guard count > 0, width > 0, let context else {
            unmountAll()
            return
        }
        let top = offsetY - headerHeight
        let (before, after): (CGFloat, CGFloat)
        switch controller?.direction ?? 0 {
        case 1: (before, after) = (Self.bufferBehind, Self.bufferAhead)
        case -1: (before, after) = (Self.bufferAhead, Self.bufferBehind)
        default: (before, after) = (Self.buffer, Self.buffer)
        }
        let low = min(layout.index(at: top - before), count - 1)
        let high = min(layout.index(at: top + viewportHeight + after), count - 1) + 1
        let range = low..<high

        let sameRows = mountedVersion == layout.version
        let sameContent = sameRows && mountedContentVersion == model?.rowsContentVersion
        let sameLook = mountedContextVersion == contextVersion
            && mountedSide == side
            && (mountedRemovals.isEmpty && removals.isEmpty || mountedRemovals == removals)
        let sameFrames = sameRows && mountedSide == side && mountedWidth == width
            && mountedHeaderHeight == headerHeight
        if sameContent, sameLook, sameFrames, range == mountedRange { return }

        var next: [MountedRow] = []
        next.reserveCapacity(range.count)
        var arrived: [Bool] = []
        arrived.reserveCapacity(range.count)
        if sameRows {
            // the rows hold, so a slide only looks at the rows entering and
            // leaving, by index.
            for index in range {
                if mountedRange.contains(index) {
                    var entry = mounted[index - mountedRange.lowerBound]
                    // a metadata patch, a favorite say, keeps every offset
                    // but changes what a few rows show.
                    let patched = !sameContent && entry.row != rows[index]
                    if patched { entry.row = rows[index] }
                    if !sameLook || patched {
                        configure(entry, index: index, context: context, removals: removals)
                    }
                    next.append(entry)
                    arrived.append(false)
                } else {
                    next.append(makeRow(rows[index], index: index, context: context, removals: removals))
                    arrived.append(true)
                }
            }
            for index in mountedRange where !range.contains(index) {
                recycle(mounted[index - mountedRange.lowerBound])
            }
        } else {
            // a swap: the views follow their row ids, so a reflow moves them
            // instead of repainting every row in place.
            var byID: [String: MountedRow] = [:]
            byID.reserveCapacity(mounted.count)
            for entry in mounted { byID[entry.id] = entry }
            for index in range {
                let row = rows[index]
                if var entry = byID.removeValue(forKey: row.id), entry.kind == Self.kind(of: row) {
                    entry.row = row
                    configure(entry, index: index, context: context, removals: removals)
                    next.append(entry)
                    arrived.append(false)
                } else {
                    next.append(makeRow(row, index: index, context: context, removals: removals))
                    arrived.append(true)
                }
            }
            for entry in byID.values { recycle(entry) }
        }

        for (offset, entry) in next.enumerated() {
            let index = range.lowerBound + offset
            var height = entry.row.height(tileSide: side)
            // tiles keep their 2pt gutter below them, outside the row.
            if entry.kind == .tiles { height = side }
            let frame = CGRect(x: 0, y: headerHeight + layout.starts[index], width: width, height: height)
            if arrived[offset] {
                UIView.performWithoutAnimation {
                    entry.view.frame = frame
                    entry.view.layoutIfNeeded()
                    if animatesLayout { entry.view.alpha = 0 }
                }
                if animatesLayout { entry.view.alpha = 1 }
            } else if entry.view.frame != frame {
                entry.view.frame = frame
            }
        }

        mounted = next
        mountedRange = range
        mountedVersion = layout.version
        mountedContentVersion = model?.rowsContentVersion ?? -1
        mountedContextVersion = contextVersion
        mountedSide = side
        mountedWidth = width
        mountedHeaderHeight = headerHeight
        mountedRemovals = removals
    }

    private static func kind(of row: TimelineRow) -> Kind {
        switch row {
        case .tiles: .tiles
        case .titleBand: .band
        case .placeholder: .placeholder
        }
    }

    private func makeRow(
        _ row: TimelineRow,
        index: Int,
        context: TimelineGridRowContext,
        removals: Set<String>
    ) -> MountedRow {
        let kind = Self.kind(of: row)
        let view: UIView
        switch kind {
        case .tiles:
            let row = tileRowPool.popLast() ?? TimelineTileRowView()
            if let pinch { row.waitForPinch(pinch) }
            view = row
        case .band:
            view = bandPool.popLast() ?? TimelineTitleBandView()
        case .placeholder:
            view = placeholderPool.popLast() ?? TimelinePlaceholderView()
        }
        if view.superview !== self {
            insertSubview(view, at: 0)
        }
        view.isHidden = false
        view.alpha = 1
        let entry = MountedRow(id: row.id, kind: kind, row: row, view: view)
        UIView.performWithoutAnimation {
            configure(entry, index: index, context: context, removals: removals, arriving: true)
        }
        if case .placeholder(_, let bucketID, _, _) = row {
            onPlaceholder?(bucketID)
        }
        return entry
    }

    private func configure(
        _ entry: MountedRow,
        index: Int,
        context: TimelineGridRowContext,
        removals: Set<String>,
        arriving: Bool = false
    ) {
        let animated = animatesLayout && !arriving
        switch entry.row {
        case .tiles(_, let runs):
            (entry.view as? TimelineTileRowView)?.apply(
                TimelineTileRowConfiguration(
                    session: context.session,
                    runs: runs,
                    rowIndex: index,
                    side: side,
                    targetPixelSize: context.targetPixelSize,
                    showsBackupBadge: context.showsBackupBadge,
                    usesOriginalAspectRatio: context.usesOriginalAspectRatio,
                    isSelecting: context.isSelecting,
                    selection: context.selection,
                    projectedRemovalIDs: removals,
                    isSelectable: context.isSelectable,
                    reduceMotion: context.reduceMotion,
                    registry: context.registry,
                    motion: context.motion,
                    actions: context.actions
                ),
                animated: animated
            )
        case .titleBand(_, let segments):
            (entry.view as? TimelineTitleBandView)?.apply(
                segments: segments,
                side: side,
                context: context,
                animated: animated && !context.reduceMotion
            )
        case .placeholder(_, _, let tileRows, let titleBands):
            (entry.view as? TimelinePlaceholderView)?.apply(
                tileRows: tileRows,
                titleBands: titleBands,
                columns: context.columns,
                side: side
            )
        }
    }

    private func recycle(_ entry: MountedRow) {
        let view = entry.view
        if animatesLayout, !UIAccessibility.isReduceMotionEnabled {
            // fades where it stood; the pool takes it once it is gone.
            UIView.animate(withDuration: 0.2, animations: {
                view.alpha = 0
            }, completion: { [weak self] _ in
                self?.pool(view, kind: entry.kind)
            })
        } else {
            pool(view, kind: entry.kind)
        }
    }

    private func pool(_ view: UIView, kind: Kind) {
        if let row = view as? TimelineTileRowView { row.unregisterTiles() }
        view.isHidden = true
        switch kind {
        case .tiles:
            if tileRowPool.count < Self.poolLimit, let view = view as? TimelineTileRowView {
                tileRowPool.append(view)
                return
            }
        case .band:
            if bandPool.count < Self.poolLimit, let view = view as? TimelineTitleBandView {
                bandPool.append(view)
                return
            }
        case .placeholder:
            if placeholderPool.count < Self.poolLimit, let view = view as? TimelinePlaceholderView {
                placeholderPool.append(view)
                return
            }
        }
        view.removeFromSuperview()
    }

    private func unmountAll() {
        guard !mounted.isEmpty else { return }
        for entry in mounted { pool(entry.view, kind: entry.kind) }
        mounted = []
        mountedRange = 0..<0
        mountedVersion = -1
    }
}

/// one band of day titles, each pinned over the columns its tiles take.
final class TimelineTitleBandView: UIView {
    private var titles: [TimelineDayTitleView] = []
    private var segments: [TitleSegment] = []
    private var side: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        segments: [TitleSegment],
        side: CGFloat,
        context: TimelineGridRowContext,
        animated: Bool
    ) {
        self.segments = segments
        self.side = side
        while titles.count < segments.count {
            let title = TimelineDayTitleView()
            addSubview(title)
            titles.append(title)
        }
        for (index, title) in titles.enumerated() {
            guard index < segments.count else {
                title.isHidden = true
                continue
            }
            let segment = segments[index]
            // a day can hold hundreds of ids and this walks the model once
            // per id, so it stays behind the mode that needs them.
            let ids = context.isSelecting && context.actions.pick == nil
                ? segment.selectableIDs.filter(context.isSelectableAssetID)
                : []
            title.isHidden = false
            title.apply(
                title: segment.title,
                selectableIDs: ids,
                allSelected: !ids.isEmpty && ids.allSatisfy(context.selection.contains),
                onToggle: context.toggleDay,
                animated: animated
            )
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (segment, title) in zip(segments, titles) {
            let width = CGFloat(segment.colWidth) * side + CGFloat(segment.colWidth - 1) * 2
            var x = CGFloat(segment.colStart) * (side + 2)
            if isRightToLeft { x = bounds.width - x - width }
            let frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            if title.frame != frame { title.frame = frame }
        }
    }
}

/// a day's title and, while selecting, its select-all toggle.
final class TimelineDayTitleView: UIView {
    private let label = UILabel()
    private let toggle = UIControl()
    private let toggleImage = UIImageView()
    private var selectableIDs: [String] = []
    private var allSelected: Bool?
    private var onToggle: (([String], Bool) -> Void)?

    private static let symbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        toggleImage.preferredSymbolConfiguration = Self.symbolConfiguration
        toggleImage.isUserInteractionEnabled = false
        toggle.addSubview(toggleImage)
        toggle.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        toggle.isHidden = true
        addSubview(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        title: String,
        selectableIDs: [String],
        allSelected: Bool,
        onToggle: @escaping ([String], Bool) -> Void,
        animated: Bool
    ) {
        if label.text != title { label.text = title }
        self.selectableIDs = selectableIDs
        self.onToggle = onToggle
        let showsToggle = !selectableIDs.isEmpty
        if toggle.isHidden == showsToggle {
            toggle.isHidden = !showsToggle
            setNeedsLayout()
        }
        guard showsToggle else {
            self.allSelected = nil
            return
        }
        guard self.allSelected != allSelected else { return }
        let image = UIImage(systemName: allSelected ? "checkmark.circle.fill" : "circle")
        let tint: UIColor = allSelected ? UIColor(resource: .brandTint) : .secondaryLabel
        if animated, self.allSelected != nil, let image {
            toggleImage.setSymbolImage(image, contentTransition: .replace)
            UIView.animate(withDuration: 0.22) { self.toggleImage.tintColor = tint }
        } else {
            toggleImage.image = image
            toggleImage.tintColor = tint
        }
        self.allSelected = allSelected
        toggle.accessibilityLabel = allSelected ? String(localized: "Deselect \(title)") : String(localized: "Select \(title)")
        toggle.isAccessibilityElement = true
        toggle.accessibilityTraits = .button
        setNeedsLayout()
    }

    @objc private func toggled() {
        guard let allSelected else { return }
        onToggle?(selectableIDs, !allSelected)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let content = bounds.inset(by: UIEdgeInsets(
            top: 0,
            left: isRightToLeft ? 6 : 4,
            bottom: 5,
            right: isRightToLeft ? 4 : 6
        ))
        let lineHeight = label.font.lineHeight
        let labelHeight = ceil(lineHeight)
        var toggleSize = CGSize.zero
        if !toggle.isHidden {
            toggleSize = toggleImage.image?.size ?? .zero
        }
        let stackHeight = max(lineHeight, toggleSize.height)
        let midY = content.maxY - stackHeight / 2
        let labelWidth = max(0, content.width - (toggle.isHidden ? 0 : toggleSize.width + 4))
        // swiftui snaps text to whole pixels of the scroll content, so the
        // title lands on the same pixels beside the toggle as it did there.
        let scale = max(1, traitCollection.displayScale)
        let contentY = superview?.superview.map { convert(CGPoint.zero, to: $0).y } ?? 0
        let labelY = midY - lineHeight / 2
        label.frame = CGRect(
            x: isRightToLeft ? content.maxX - labelWidth : content.minX,
            y: ((contentY + labelY) * scale).rounded() / scale - contentY,
            width: labelWidth,
            height: labelHeight
        )
        label.textAlignment = isRightToLeft ? .right : .left
        if !toggle.isHidden {
            toggle.frame = CGRect(
                x: isRightToLeft ? content.minX : content.maxX - toggleSize.width,
                y: midY - toggleSize.height / 2,
                width: toggleSize.width,
                height: toggleSize.height
            )
            toggleImage.frame = toggle.bounds
        }
    }
}

/// dimmed grid pattern shown while a bucket loads. at most a screenful of
/// squares is drawn, the rest is one flat block, and the total matches the
/// row height so the month keeps its place once it loads.
final class TimelinePlaceholderView: UIView {
    private var blocks: [UIView] = []
    private let tail = UIView()
    private var shape: (tileRows: Int, titleBands: Int, columns: Int, side: CGFloat) = (0, 0, 0, 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        tail.backgroundColor = .secondarySystemFill
        tail.alpha = 0.6
        addSubview(tail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(tileRows: Int, titleBands: Int, columns: Int, side: CGFloat) {
        let next = (tileRows, titleBands, columns, side)
        guard next != shape else { return }
        shape = next
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (tileRows, titleBands, columns, side) = shape
        let visibleRows = min(tileRows, 12)
        let visibleBands = min(titleBands, max(1, visibleRows / 2))
        let rowsPerBand = max(1, visibleRows / max(1, visibleBands))
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let rowWidth = CGFloat(columns) * side + CGFloat(max(0, columns - 1)) * 2
        let rowX = (bounds.width - rowWidth) / 2

        var used = 0
        func block(_ frame: CGRect, cornerRadius: CGFloat) {
            if used == blocks.count {
                let view = UIView()
                view.backgroundColor = .secondarySystemFill
                addSubview(view)
                blocks.append(view)
            }
            let view = blocks[used]
            view.isHidden = false
            view.frame = frame
            view.layer.cornerRadius = cornerRadius
            used += 1
        }

        var y: CGFloat = 0
        for row in 0..<visibleRows {
            if row % rowsPerBand == 0, row / rowsPerBand < visibleBands {
                // 34 not 36: the stack's own 2pt spacing completes a band.
                let x = isRightToLeft ? bounds.width - 4 - 96 : 4
                block(CGRect(x: x, y: y + 34 - 5 - 14, width: 96, height: 14), cornerRadius: 4)
                y += 36
            }
            for column in 0..<columns {
                block(CGRect(x: rowX + CGFloat(column) * (side + 2), y: y, width: side, height: side), cornerRadius: 0)
            }
            y += side + 2
        }
        for view in blocks[used...] { view.isHidden = true }

        let remaining = CGFloat(tileRows - visibleRows) * (side + 2)
            + CGFloat(titleBands - visibleBands) * 36
        tail.isHidden = remaining <= 2
        if !tail.isHidden {
            tail.frame = CGRect(x: 0, y: y, width: bounds.width, height: remaining - 2)
        }
    }
}
