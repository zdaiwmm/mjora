import Foundation
import SwiftUI

private struct TimelineScrollState: Equatable {
    let offsetY: CGFloat
    let indicatorOffsetY: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let containerHeight: CGFloat
}

/// one month's slice of the grid in row space, newest first like the rows.
private struct ScrubberMonth {
    let id: String
    let title: String
    let year: Int
    let startY: CGFloat
    let height: CGFloat
}

/// plain box written from scroll callbacks and read when a realtime rows
/// update lands. nothing here is observed, so per-frame writes never
/// re-render anything.
@MainActor
private final class ScrollContext {
    /// distance scrolled past the rest position, the space scrollTo(y:) takes.
    var offsetY: CGFloat = 0
    var firstVisibleRowID: String?
    var firstVisibleAssetID: String?
    /// the whole visible run, not just the first row: only tile rows anchor a
    /// prefetch window and the top row is usually a month header.
    var visibleRowIDs: [String] = []
    /// same rows as indices, the cheap equality check behind the ids above.
    var visibleRange: Range<Int> = 0..<0
    /// the rows layout the ids were read from. a swap can leave the indices
    /// alone while every row behind them is new.
    var visibleLayoutVersion = -1
    var isIdle = true
    var viewportWidth: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var viewportShowsPhotoOverview = false
    /// the previous offset sample and when it was taken, for the velocity.
    var lastSampledOffsetY: CGFloat = 0
    var lastSampleTime: CFTimeInterval = 0
    /// points per second, smoothed over the last frames.
    var velocity: CGFloat = 0
    /// 1 towards the bottom, -1 towards the top, 0 while slow or at rest.
    /// held with hysteresis so a wobble never flips the buffers back and
    /// forth mid fling.
    var direction = 0
    /// The window also changes when speed or direction changes inside one row.
    var prefetchDirection: Int?
    var prefetchIsFast: Bool?
}

/// speeds, in points per second, past which a fling counts as fast for the
/// tiles and below which it stops counting. a fade per arriving tile reads as
/// flicker beyond the first, and the gap keeps the flag from chattering.
private let fastScrollSpeed: CGFloat = 2400
private let fastScrollRelease: CGFloat = 1200

/// scroll-driven values live here instead of screen @state. per-frame
/// updates reach only the uikit thumb, which reads them in its tracked
/// layout pass; swiftui reads the position only while a scrub is on.
///
/// the indicator geometry below was measured empirically on ios 26: the
/// native track runs from the scroll view's own safe area top plus 3pt to
/// its bottom edge minus 3pt - it ignores the large-title expansion swiftui
/// reports in contentInsets.top - the overlay's own frame top sits at the
/// current inset, offsets are uikit style with 0 at rest meaning
/// offset+inset, and the thumb is bounds over virtual height with a 36pt
/// floor.
@Observable @MainActor
private final class ScrubberState {
    /// distance scrolled past the rest position at the top.
    var offsetY: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var containerHeight: CGFloat = 1
    /// the inset the indicator actually pins to: the COLLAPSED bar. sampled as
    /// the smallest contentInsets.top this scroll view has reported, because a
    /// large title inflates that inset while it is expanded even though the
    /// indicator track never moves with it. sampled rather than read from the
    /// scroll view's safeAreaInsets, which is not reliably the bar bottom -
    /// getting that wrong stretches the whole track and offsets every marker.
    /// one scrolled frame is enough to pin it, and the overlay is hidden until
    /// the user scrolls anyway.
    var compactInsetTop: CGFloat?
    /// scroll view height. a change means rotation, which invalidates the
    /// sampled inset - a landscape bar is shorter than a portrait one.
    private var frameHeight: CGFloat = 0
    var headerHeight: CGFloat = 0
    var footerHeight: CGFloat = 0
    /// true only while the finger is dragging the thumb.
    var isScrubbing = false
    /// the drawn indicator follows the system's own rhythm: it appears with a
    /// scroll and fades shortly after it stops. `grabbable` outlives the fade
    /// so a finger reaching for a thumb that has just faded still catches it.
    ///
    /// they live here rather than in screen @state because they flip on every
    /// scroll phase change - three times a fling - and a screen-level write
    /// would re-run the grid body, and its every visible tile, each time.
    var indicatorVisible = false
    var indicatorGrabbable = false
    /// drag-driven position, so the thumb tracks the finger exactly instead of
    /// chasing the scroll it is causing.
    var scrubFraction: CGFloat?
    /// month layout in row space, rebuilt whenever the rows change shape - a
    /// bucket loading, a pinch resizing every tile.
    var liveMonths: [ScrubberMonth] = []
    /// total row height of `liveMonths`.
    var monthsHeight: CGFloat = 0
    /// empty space padded past the last row - the selection bar's clearance,
    /// nothing else. scrollable content, so it counts toward the total.
    var tailPadding: CGFloat = 0
    /// held still for the length of a scrub, so a bucket landing mid-drag
    /// cannot spread the markers out under the finger.
    private var frozenMonths: [ScrubberMonth]?
    private var frozenTotal: CGFloat?

    var months: [ScrubberMonth] { frozenMonths ?? liveMonths }

    /// the app's OWN layout height - header, rows, bottom padding. the
    /// grid places every row from exactly this layout, so it IS the
    /// scroll view's contentSize and every value derived from it is a real
    /// scroll offset. immich-web's totalViewerHeight, one to one.
    var contentTotal: CGFloat {
        frozenTotal ?? (headerHeight + monthsHeight + footerHeight + tailPadding)
    }

    func beginScrub() {
        frozenMonths = liveMonths
        frozenTotal = headerHeight + monthsHeight + footerHeight + tailPadding
        isScrubbing = true
    }

    func endScrub() {
        frozenMonths = nil
        frozenTotal = nil
        scrubFraction = nil
        isScrubbing = false
    }

    /// how much of the content the viewport top can actually reach, as a
    /// fraction of the whole - immich-web's maxScrollPercent. the last
    /// viewport-height of any timeline can never sit at the top, so the rail
    /// spans the FULL content while a drag only ever asks for a reachable
    /// offset. this is what the web uses instead of padding the end, and it is
    /// why nothing can pin: an offset that is already inside the scrollable
    /// range cannot be clamped short of itself.
    var maxScrollPercent: CGFloat {
        contentTotal > 0 ? scrollRange / contentTotal : 0
    }

    var scrollRange: CGFloat { max(0, contentTotal - containerHeight) }

    var fraction: CGFloat {
        if let scrubFraction { return scrubFraction }
        return scrollRange > 0 ? min(1, max(0, offsetY / scrollRange)) : 0
    }

    /// total scrollable span in uikit bounds coordinates.
    var virtualHeight: CGFloat { contentTotal + insetTop + insetBottom }


    /// indicator track in overlay coordinates. the overlay frame top sits at
    /// the current top inset, so pinning to the collapsed bar goes negative
    /// while the large title is expanded - exactly like the real indicator,
    /// which stays put while the title grows above it.
    var trackTop: CGFloat { (compactInsetTop ?? insetTop) + 3 - insetTop }

    /// the bottom end lands at the scroll view's own bottom edge less 3pt,
    /// which reduces to the container height whatever the insets are doing.
    var trackHeight: CGFloat { max(1, containerHeight - 3 - trackTop) }

    var thumbHeight: CGFloat {
        max(36, trackHeight * (containerHeight + insetTop + insetBottom) / max(1, virtualHeight))
    }

    var thumbCenterY: CGFloat {
        trackTop + fraction * (trackHeight - thumbHeight) + thumbHeight / 2
    }

    /// where a marker for content at `offset` belongs. the rail is laid out
    /// over the WHOLE content - immich-web's segmentTop / totalHeight - while
    /// the thumb rides offsetY / scrollRange, and the two meet exactly because
    /// a drag scrolls to offset * maxScrollPercent. measuring markers against
    /// the scroll range instead put the oldest month's chip at the very bottom
    /// of the track and asked a drag there to place that month at the viewport
    /// top, which only a viewport of padding can satisfy and which clamped
    /// short whenever it did not - the grid pinned a year early while the thumb
    /// kept travelling.
    func markerY(forContentOffset offset: CGFloat) -> CGFloat {
        guard contentTotal > 0 else { return trackTop }
        let progress = min(1, max(0, offset / contentTotal))
        return trackTop + progress * (trackHeight - thumbHeight) + thumbHeight / 2
    }

    /// content offset a drag at `fraction` scrolls to: immich-web's
    /// (segmentTop + delta) * maxScrollPercent, reduced. always inside the
    /// scrollable range, so nothing ever clamps or springs back.
    func contentOffset(forFraction fraction: CGFloat) -> CGFloat {
        min(1, max(0, fraction)) * scrollRange
    }

    /// month the RAIL points at, which is what the floating pill names while a
    /// drag is on. the web reads its label from the same scaled walk that
    /// places the markers, so pill and chip always agree; the month actually at
    /// the viewport top can be up to a viewport newer near the end, which is
    /// inherent to mapping a full timeline onto a shorter scrollable range.
    func month(atFraction fraction: CGFloat) -> ScrubberMonth? {
        month(at: min(1, max(0, fraction)) * contentTotal)
    }

    func update(with state: TimelineScrollState) {
        // the scroll view's own height. only a rotation changes it, and the
        // bar it reported before that no longer applies.
        let frame = state.containerHeight + state.insetTop + state.insetBottom
        if abs(frame - frameHeight) > 0.5 {
            frameHeight = frame
            compactInsetTop = nil
        }
        if let sampled = compactInsetTop {
            if state.insetTop < sampled { compactInsetTop = state.insetTop }
        } else {
            compactInsetTop = state.insetTop
        }
        if insetTop != state.insetTop { insetTop = state.insetTop }
        if insetBottom != state.insetBottom { insetBottom = state.insetBottom }
        if containerHeight != state.containerHeight { containerHeight = state.containerHeight }
        if offsetY != state.indicatorOffsetY { offsetY = state.indicatorOffsetY }
    }

    /// every input `railMarks` reads. the thumb moves every frame of a drag but
    /// none of this does, so the rail is computed once and handed back.
    private struct RailKey: Equatable {
        let count: Int
        let first: String?
        let last: String?
        let monthsHeight: CGFloat
        let headerHeight: CGFloat
        let trackTop: CGFloat
        let trackHeight: CGFloat
        let thumbHeight: CGFloat
        let scrollRange: CGFloat
    }

    @ObservationIgnored private var railCache: (key: RailKey, marks: [ScrubberRailMark])?

    /// months are walked oldest first, like immich-web, so a year is named at
    /// the month it begins with in time - january - and not at the newest
    /// month the year happens to end on. the newest year therefore has no chip
    /// at the very top of the rail; its chip sits down where that year started.
    ///
    /// chips and dots anchor at the BOTTOM edge of their month's segment,
    /// exactly like the web, whose label and dot divs are both absolute
    /// bottom-0 inside the segment. the bottom edge is the month's start in
    /// time - a january segment runs jan 31 at its top down to jan 1 at its
    /// bottom - so the year chip sits on the year's very first photo.
    /// anchoring at the top edge instead put every chip a whole january too
    /// new. the anchor pulls in 2pt so the boundary pixel still resolves to
    /// the month the mark names rather than to december of the year below,
    /// mirroring how the web's boundary pixel belongs to the january div.
    ///
    /// immich-web's thresholds - 16pt between year labels, 8pt between dots,
    /// months thinner than 5pt get no dot, the oldest month always gets both -
    /// are applied as a DROP rule rather than the web's carry-forward. the web
    /// tracks the span since the last label and lets a LATER month claim the
    /// year once the span is big enough, which parks the chip months away from
    /// the year it names. here a mark is either exactly on the boundary it
    /// names or absent.
    func railMarks() -> [ScrubberRailMark] {
        let months = months
        let key = RailKey(
            count: months.count,
            first: months.first?.id,
            last: months.last?.id,
            monthsHeight: monthsHeight,
            headerHeight: headerHeight,
            trackTop: trackTop,
            trackHeight: trackHeight,
            thumbHeight: thumbHeight,
            scrollRange: scrollRange
        )
        if let railCache, railCache.key == key { return railCache.marks }

        var marks: [ScrubberRailMark] = []
        if !months.isEmpty, trackHeight > 1, scrollRange > 0 {
            var previousYear: Int?
            var isOldest = true
            // walking oldest first means positions climb the rail, so the
            // spacing rules compare against a value that decreases.
            var lastLabelY = CGFloat.greatestFiniteMagnitude
            var lastDotY = CGFloat.greatestFiniteMagnitude
            for month in months.reversed() {
                let monthStart = headerHeight + month.startY
                let markY = markerY(forContentOffset: monthStart + month.height - 2)
                let height = markY - markerY(forContentOffset: monthStart)
                let opensYear = previousYear != month.year
                previousYear = month.year

                var year: String?
                if opensYear, lastLabelY - markY > 16 {
                    year = String(month.year)
                    lastLabelY = markY
                }
                var hasDot = false
                if isOldest || (height > 5 && lastDotY - markY > 8) {
                    hasDot = true
                    lastDotY = markY
                }
                isOldest = false
                if year != nil || hasDot {
                    marks.append(ScrubberRailMark(id: month.id, y: markY, year: year, hasDot: hasDot))
                }
            }
        }
        railCache = (key, marks)
        return marks
    }

    /// month whose rows sit at the viewport top for a given offset, clamped
    /// to the newest month while the header is still on screen.
    func month(at offset: CGFloat) -> ScrubberMonth? {
        guard !months.isEmpty else { return nil }
        let rowY = offset - headerHeight
        var low = 0
        var high = months.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if months[mid].startY <= rowY + 1 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return months[best]
    }
}

nonisolated enum TimelineServerCommand: Equatable {
    case restoreAllTrash
    case emptyTrash
}

/// swiftui evaluates a state's initial value on every init of its view and
/// keeps only the first. a model restores its months from disk and lays out
/// every row when built, so it is built lazily, by the holder swiftui keeps.
@MainActor
final class TimelineModelHolder {
    private let make: () -> TimelineModel
    private(set) lazy var model = make()

    init(_ make: @escaping () -> TimelineModel) {
        self.make = make
    }
}

/// reusable bucketed photo grid, the workhorse behind most screens.
struct TimelineScreen<Header: View, Trailing: ToolbarContent, Footer: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.usesCompactPhotosNavigation) private var usesCompactPhotosNavigation
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    @Environment(\.refresh) private var refresh

    let title: String
    let filter: TimelineFilter
    var emptyIcon = "photo.on.rectangle"
    var emptyMessage = String(localized: "No photos yet")
    var showsLargeTitle = true
    var photosConfiguration: PhotosToolbarConfiguration?
    var showsEmptyState = true
    var hidesScrollEdgeEffect = false
    var scrollResetTrigger = 0
    /// main photos tab only: weave in device photos and show backup badges.
    var mergesLocalPhotos = false
    /// hosts bump this after mutating the grid's contents server-side, e.g.
    /// adding album photos. the model resyncs in place with an animated
    /// reflow instead of the host remounting the whole screen.
    var resyncTrigger = 0
    /// album grids pass their owner so the viewer can offer removal to the
    /// people the server accepts it from. the id itself comes from the filter.
    var albumOwnerID: String?
    /// shared album grids pass this so the viewer offers comments and likes.
    var albumActivity: AlbumActivityScope?
    /// Keeps AlbumDetail's metadata header in lockstep with direct grid
    /// removals without coupling this reusable screen to album state.
    var onAlbumAssetCountDelta: ((Int) -> Void)?
    /// album grids hand this over for their owner only. a single server photo
    /// then offers itself as the cover from the tile menu, the selection menu
    /// and the viewer; the album screen runs the request and projects it.
    var onSetAlbumCover: ((String) async -> Bool)?
    /// space grids pass this for their editors and owners, the roles gallery
    /// lets take photos out. the space id itself comes from the filter.
    var canRemoveFromSpace = false
    /// one-shot picker: while set, a tap hands the photo back instead of
    /// opening it, and nothing else on a tile responds. person pages choose a
    /// featured photo this way.
    var onPickAsset: ((Asset) -> Void)?
    /// the locked folder re-gates when the server refuses its elevation.
    var onUnauthorized: (() -> Void)?
    @Binding private var navigationTarget: TimelineNavigationTarget?
    @Binding private var serverCommand: TimelineServerCommand?
    let header: Header
    let footer: Footer
    /// the host's own trailing navigation items. they are declared here
    /// rather than on the host so this screen owns the whole trailing group:
    /// the select pill always leads them, and selection mode unmounts them
    /// in place - a host-side toolbar would merge ahead of anything added
    /// from inside.
    let trailingItems: Trailing

    @State private var modelHolder: TimelineModelHolder
    private var model: TimelineModel { modelHolder.model }
    @State private var selection = Set<String>()
    @State private var deviceCopyRemoval = DeviceCopyRemovalCoordinator()
    @State private var isSelecting = false
    @State private var viewer = ViewerPresentation()
    @State private var indicatorHideTask: Task<Void, Never>?
    @State private var scrub = ScrubberState()
    @State private var scrollContext = ScrollContext()
    @State private var rowLayoutBox = TimelineRowLayoutBox()
    @State private var gridController = TimelineGridController()
    @State private var periodMotion = PhotoPeriodMotion()
    @State private var openingChromePrewarmOwner = UUID()
    @State private var pendingAlbumAssets: [String]?
    @State private var pendingSpaceAssets: [String]?
    @State private var pendingEditAsset: Asset?
    @State private var shareRequest: AssetShareRequest?
    /// frozen at the moment the pill is tapped, so the sheet's grid holds
    /// still while items are unchecked inside it.
    @State private var selectedSheetAssets: [Asset] = []
    @State private var showsSelectedSheet = false
    @State private var downloadingAssetIDs = Set<String>()
    /// Serializes mutations per asset while still allowing unrelated photos
    /// to update concurrently. The set also disables bulk actions that overlap
    /// an in-flight context-menu command.
    @State private var mutatingAssetIDs = Set<String>()
    /// Downloads update the persisted pairing asynchronously. Keeping the new
    /// identifier here makes a reopened context menu correct immediately.
    @State private var downloadedLocalIdentifiers: [String: String] = [:]
    @State private var pendingRebackup: RebackupConfirmation?
    @State private var columnCount = 3
    /// Nil follows the width-aware default. Once the user pinches, retain
    /// their choice across window changes and only clamp the rendered value.
    @State private var preferredColumnCount: Int?
    @State private var pinchBaseColumns: Int?
    // device tiles warm the same uncropped render they draw, so the caching
    // manager serves the tile and the opening transition alike.
    @State private var prefetcher = ThumbnailPrefetcher(
        localContentMode: DeviceTileRender.contentMode,
        localCoversTarget: DeviceTileRender.coversTile
    )
    @State private var motion = GridMotion()
    @State private var tileRegistry = AssetTileRegistry()
    @State private var selectionSlideController = TimelineSelectionSlideController()
    @State private var isRunningServerCommand = false
    @State private var restoredPhotosPosition = false
    @State private var completedPhotosRestoration = false

    init(
        title: String,
        filter: TimelineFilter,
        emptyIcon: String = "photo.on.rectangle",
        emptyMessage: String = String(localized: "No photos yet"),
        showsLargeTitle: Bool = true,
        photosConfiguration: PhotosToolbarConfiguration? = nil,
        showsEmptyState: Bool = true,
        hidesScrollEdgeEffect: Bool = false,
        scrollResetTrigger: Int = 0,
        suppliedModel: TimelineModel? = nil,
        mergesLocalPhotos: Bool = false,
        resyncTrigger: Int = 0,
        albumOwnerID: String? = nil,
        albumActivity: AlbumActivityScope? = nil,
        onAlbumAssetCountDelta: ((Int) -> Void)? = nil,
        onSetAlbumCover: ((String) async -> Bool)? = nil,
        canRemoveFromSpace: Bool = false,
        onPickAsset: ((Asset) -> Void)? = nil,
        onUnauthorized: (() -> Void)? = nil,
        navigationTarget: Binding<TimelineNavigationTarget?> = .constant(nil),
        serverCommand: Binding<TimelineServerCommand?> = .constant(nil),
        @ToolbarContentBuilder trailingItems: () -> Trailing = {
            ToolbarItemGroup(placement: .topBarTrailing) {}
        },
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        @ViewBuilder header: () -> Header = { EmptyView() }
    ) {
        self.title = title
        self.filter = filter
        self.emptyIcon = emptyIcon
        self.emptyMessage = emptyMessage
        self.showsLargeTitle = showsLargeTitle
        self.photosConfiguration = photosConfiguration
        self.showsEmptyState = showsEmptyState
        self.hidesScrollEdgeEffect = hidesScrollEdgeEffect
        self.scrollResetTrigger = scrollResetTrigger
        self.mergesLocalPhotos = mergesLocalPhotos
        self.resyncTrigger = resyncTrigger
        self.albumOwnerID = albumOwnerID
        self.albumActivity = albumActivity
        self.onAlbumAssetCountDelta = onAlbumAssetCountDelta
        self.onSetAlbumCover = onSetAlbumCover
        self.canRemoveFromSpace = canRemoveFromSpace
        self.onPickAsset = onPickAsset
        self.onUnauthorized = onUnauthorized
        _navigationTarget = navigationTarget
        _serverCommand = serverCommand
        self.trailingItems = trailingItems()
        self.header = header()
        self.footer = footer()
        _modelHolder = State(initialValue: TimelineModelHolder {
            suppliedModel ?? TimelineModel(filter: filter, mergesLocal: mergesLocalPhotos)
        })
    }

    private var isPicking: Bool { onPickAsset != nil }

    /// the default builder hands back an empty group, and a spacer next to
    /// nothing would only push the select pill inward.
    private var hasTrailingItems: Bool {
        Trailing.self != ToolbarItemGroup<EmptyView>.self
    }

    private func tileSide(for width: CGFloat) -> CGFloat {
        AssetGridLayout.tileSide(viewportWidth: width, columns: columnCount)
    }

    private func thumbnailPixelSize(for side: CGFloat) -> CGFloat {
        let pixels = max(1, side * displayScale)
        return min(1_280, (pixels / 32).rounded(.up) * 32)
    }

    /// keeps the row window and the column count in step with the width.
    private func applyViewportWidth(_ width: CGFloat, viewportHeight: CGFloat) {
        scrollContext.viewportWidth = width
        // whichever of the initial callbacks lands last completes the
        // viewport, so each one windows the rows.
        updateVisibleRows()
        if navigationTarget != nil {
            Task { await revealPendingTimelineTarget() }
        }
        let target = columnTarget(viewportWidth: width)
        guard target != columnCount else { return }
        applyColumnCount(
            target,
            viewportWidth: width,
            viewportHeight: viewportHeight,
            preservedFraction: scrub.fraction,
            recordsUserPreference: false
        )
    }

    /// the stored preference clamped to what the current width can show, or
    /// the default when nothing was pinched yet.
    private func columnTarget(viewportWidth: CGFloat) -> Int {
        guard let preferred = preferredColumnCount else {
            return AssetGridLayout.defaultColumnCount(viewportWidth: viewportWidth)
        }
        let range = AssetGridLayout.columnRange(viewportWidth: viewportWidth)
        return min(range.upperBound, max(range.lowerBound, preferred))
    }

    private func applyColumnCount(
        _ target: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        preservedFraction: CGFloat,
        recordsUserPreference: Bool
    ) {
        if recordsUserPreference { gridController.prepareColumnChange() }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if recordsUserPreference { preferredColumnCount = target }
            if recordsUserPreference { photosConfiguration?.controls.columns = target }
            columnCount = target
            model.columns = target
        }

        let newSide = AssetGridLayout.tileSide(
            viewportWidth: viewportWidth,
            columns: target
        )
        if recordsUserPreference, gridController.finishColumnChange(side: newSide) { return }
        let contentHeight = scrub.headerHeight + model.contentHeight(tileSide: newSide) + scrub.footerHeight + bottomPadding()
        // distance past the rest position, the space scrollTo(y:) takes.
        let offset = preservedFraction * max(0, contentHeight - viewportHeight)
        // the grid takes the new tile side with the next screen update.
        Task { @MainActor in
            gridController.scrollTo(y: offset)
        }
    }

    /// content is taller than the viewport, so there is a scrollbar to draw.
    private func isScrollable(rowsHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        scrub.headerHeight + rowsHeight + scrub.footerHeight > viewportHeight
    }

    /// the cached exact row offsets, rebuilt when the rows or the side moved.
    private func rowLayout(side: CGFloat) -> TimelineRowLayout {
        rowLayoutBox.layout(for: model, side: side)
    }

    /// recomputes what the viewport sees from the exact layout, for the
    /// prefetch window and the scroll anchor. runs on every scroll frame, two
    /// binary searches and integer compares. the grid mounts its own rows.
    private func updateVisibleRows() {
        let context = scrollContext
        guard context.viewportWidth > 0, context.viewportHeight > 0 else { return }
        let side = tileSide(for: context.viewportWidth)
        let layout = rowLayout(side: side)
        let rows = model.rows
        let count = min(rows.count, layout.starts.count)
        guard count > 0 else { return }
        let top = context.offsetY - scrub.headerHeight

        let visibleLow = min(layout.index(at: top), count - 1)
        let visibleHigh = min(layout.index(at: top + context.viewportHeight), count - 1) + 1
        let visible = visibleLow..<visibleHigh
        // refreshed on every rows swap, not only when the range moves: a
        // bucket landing keeps the same indices while the rows behind them
        // are all new, and stale ids would anchor the prefetch window and the
        // scroll compensation to rows that no longer exist.
        let viewportChanged = visible != context.visibleRange || context.visibleLayoutVersion != layout.version
        if viewportChanged {
            context.visibleRange = visible
            context.visibleLayoutVersion = layout.version
            context.firstVisibleRowID = rows[visibleLow].id
            context.visibleRowIDs = rows[visible].map(\.id)
        }
        // A reversal or speed change can occur before the visible row changes.
        // Scrubbing catches up once the finger lifts instead of warming each stop.
        if !scrub.isScrubbing && (viewportChanged || context.prefetchDirection != context.direction || context.prefetchIsFast != motion.isFast) {
            context.prefetchDirection = context.direction
            context.prefetchIsFast = motion.isFast
            prefetcher.update(
                visibleRowIDs: context.visibleRowIDs,
                model: model,
                client: session.client,
                backup: session.backup,
                targetPixelSize: thumbnailPixelSize(for: side),
                direction: context.direction,
                isFast: motion.isFast
            )
        }
        prewarmOpeningChrome(in: rows, visibleRange: visible)
        if context.isIdle || viewportChanged {
            let tileRows = visible.filter { index in
                if case .tiles = rows[index] {
                    return layout.starts[index] + side > top && layout.starts[index] < top + context.viewportHeight
                }
                return false
            }
            let firstTileRow = tileRows.first
            let unknownVisible = visible.contains { index in
                guard case .placeholder = rows[index] else { return false }
                return min(layout.starts[index] + rows[index].height(tileSide: side), top + context.viewportHeight)
                    - max(layout.starts[index], top) > 1
            }
            context.firstVisibleAssetID = firstTileRow.flatMap { model.firstAssetIDByRowID[rows[$0].id] }
            model.checkpointViewport(rowIDs: tileRows.map { rows[$0].id },
                layout: .init(width: Double(context.viewportWidth), height: Double(context.viewportHeight),
                    scale: Double(displayScale), columns: columnCount), pixels: thumbnailPixelSize(for: side),
                anchorOffset: Double(top - (firstTileRow.map { layout.starts[$0] } ?? top)), stable: context.isIdle && !unknownVisible,
                surfaceProvider: { [weak grid = gridController, weak client = session.client] key in
                    guard let client else { return nil }
                    return grid?.checkpointSurface(for: key, client: client)
                })
        }
    }

    /// velocity and direction from the offset samples. they steer the mount
    /// buffers and the prefetch window, and flip the tiles' fade switch when
    /// a fling is too fast for fades to read as anything but flicker.
    private func noteScroll(to offsetY: CGFloat) {
        let context = scrollContext
        context.offsetY = offsetY
        // only a finger or a fling counts. a programmatic jump - scroll
        // compensation, a reveal, the scrubber - lands in one frame and would
        // read as an impossible speed that nothing resets until the next
        // real scroll ends.
        guard !context.isIdle else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - context.lastSampleTime
        if context.lastSampleTime > 0, elapsed > 0, elapsed < 0.25 {
            let sample = (offsetY - context.lastSampledOffsetY) / CGFloat(elapsed)
            if abs(sample) > 600 && context.direction != 0 && (sample > 0 ? 1 : -1) != context.direction {
                context.velocity = sample
            } else {
                context.velocity = context.velocity * 0.5 + sample * 0.5
            }
        } else {
            context.velocity = 0
        }
        context.lastSampledOffsetY = offsetY
        context.lastSampleTime = now

        let speed = abs(context.velocity)
        if speed > 600 {
            context.direction = context.velocity > 0 ? 1 : -1
        } else if speed < 200 {
            context.direction = 0
        }
        gridController.direction = context.direction
        let fast = speed > (motion.isFast ? fastScrollRelease : fastScrollSpeed)
        if motion.isFast != fast { motion.isFast = fast }
    }

    private func settleMotion() {
        let context = scrollContext
        context.velocity = 0
        context.direction = 0
        gridController.direction = 0
        context.lastSampleTime = 0
        if motion.isFast { motion.isFast = false }
    }

    private func prewarmOpeningChrome(
        in rows: [TimelineRow],
        visibleRange: Range<Int>
    ) {
        guard scrollContext.isIdle,
              !scrub.isScrubbing,
              pinchBaseColumns == nil,
              !isSelecting,
              !isPicking,
              !viewer.isTransitioning
        else { return }
        let center = CGFloat(visibleRange.lowerBound + visibleRange.upperBound - 1) / 2
        let prioritizedIndices = visibleRange.sorted {
            abs(CGFloat($0) - center) < abs(CGFloat($1) - center)
        }
        let assets = prioritizedIndices.flatMap { index -> [Asset] in
            let row = rows[index]
            guard case .tiles(_, let runs) = row else { return [] }
            return runs.flatMap(\.assets)
        }
        AssetViewerOpeningChromeCache.shared.prewarm(
            owner: openingChromePrewarmOwner,
            assets: assets,
            session: session
        )
    }

    /// everything padded past the last row, which is only the selection bar's
    /// clearance. there is deliberately NO viewport-sized tail: padding the end
    /// so the last month can reach the viewport top is what made a drag there
    /// depend on a full screen of empty content being present to the pixel, and
    /// it clamped short whenever the scroll view disagreed. immich-web pads
    /// nothing and compresses the mapping instead - see maxScrollPercent - so
    /// the end of the track is simply the end of the scroll.
    private func bottomPadding() -> CGFloat {
        if isSelecting { return 90 }
        return extendsPhotosBehindBars ? 100 : 0
    }

    private var selectionMoreMenu: some View {
        // the optional handlers are typed here: inferring them through the
        // ternaries costs more than the whole screen's type checking budget.
        let isLocked = filter.visibility == .locked
        let removeFromAlbum: (() async -> Void)? = filter.albumId == nil
            ? nil
            : { await applyRemoveFromAlbum() }
        let setAlbumCover: (() async -> Void)? = onSetAlbumCover != nil && selection.count == 1
            ? { await applySetAlbumCover() }
            : nil
        let lock: (() async -> Void)? = isLocked ? nil : { await applyLock() }
        let unlock: (() async -> Void)? = isLocked ? { await applyVisibility(.timeline) } : nil
        let backUp: (() -> Void)? = selectionHasLocalAssets ? { applyBackup() } : nil
        let addToSpace: (() -> Void)? = session.capabilities.supportsSharedSpaces && !isLocked
            ? { pendingSpaceAssets = Array(selection) }
            : nil
        let removeFromSpace: (() async -> Void)? = canRemoveFromSpace && filter.spaceId != nil
            ? { await applyRemoveFromSpace() }
            : nil
        let stack: (() async -> Void)? = selection.count >= 2 && !isLocked && filter.isTrashed != true
            && !selectionHasForeignAssets
            ? { await applyStack() }
            : nil
        return SelectionMoreMenu(
            filter: filter,
            count: selection.count,
            mediaCounts: selectedMediaCounts,
            isDisabled: isSelectionWorking || selection.isEmpty,
            serverActionsDisabled: selectionHasLocalAssets,
            ownerActionsDisabled: selectionHasForeignAssets,
            favoritesArePerUser: session.capabilities.supportsPerUserFavorites,
            onFavorite: { await applyFavorite() },
            onArchive: { await applyVisibility(filter.visibility == .archive ? .timeline : .archive) },
            onRemoveFromAlbum: removeFromAlbum,
            onSetAlbumCover: setAlbumCover,
            onAddToAlbum: { pendingAlbumAssets = Array(selection) },
            onAddToSpace: addToSpace,
            onRemoveFromSpace: removeFromSpace,
            onStack: stack,
            onLock: lock,
            onUnlock: unlock,
            lockDeletesDeviceCopies: selectionHasDeviceCopies,
            onBackUp: backUp,
            backUpTitle: isBackupOnlySelection ? String(localized: "Back Up") : String(localized: "Back Up Missing")
        )
    }

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        if let configuration = photosConfiguration {
            ToolbarItem(placement: .topBarLeading) {
                PhotosSourceMenu(configuration: configuration,
                                 count: model.sections.reduce(0) { $0 + $1.count })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if isSelecting, !isPicking {
            if let configuration = photosConfiguration {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosBrowseMenu(controls: configuration.controls, supportsDateAdded: configuration.supportsDateAdded, source: configuration.source.wrappedValue)
                }
            }
            if filter.isTrashed != true {
                ToolbarItem(placement: .topBarTrailing) { selectionMoreMenu }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exitSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .disabled(isSelectionWorking)
                .accessibilityLabel("Cancel Selection")
                .accessibilityIdentifier("selection-cancel")
            }
        } else {
            if let configuration = photosConfiguration {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosBrowseMenu(controls: configuration.controls, supportsDateAdded: configuration.supportsDateAdded, source: configuration.source.wrappedValue)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            if !isPicking, !model.isEmpty, (photosConfiguration?.controls.mode ?? .all) == .all {
                // leads the host's items as a pill of its own: the fixed
                // spacer splits the glass so it never merges into their
                // group.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { enterSelection() }
                        .tint(photosConfiguration == nil ? .accentColor : .primary)
                        .accessibilityIdentifier("timeline-select")
                }
                if hasTrailingItems {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }
            trailingItems
        }
    }

    /// the header above the rows and the footer below them, in one uikit
    /// scroll view. every marker position is measured from where row space
    /// starts, so the header's height is measured rather than assumed.
    private func timelineGrid(
        side: CGFloat,
        tailPadding: CGFloat,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> some View {
        TimelineGrid(
            model: model,
            controller: gridController,
            layoutBox: rowLayoutBox,
            side: side,
            tailPadding: tailPadding,
            rowContext: rowContext(side: side),
            hidesEdgeEffects: photosConfiguration != nil || hidesScrollEdgeEffect,
            refresh: refresh,
            events: gridEvents(viewportWidth: viewportWidth, viewportHeight: viewportHeight),
            header: header,
            footer: footer
        )
    }

    private func rowContext(side: CGFloat) -> TimelineGridRowContext {
        TimelineGridRowContext(
            session: session,
            columns: columnCount,
            targetPixelSize: thumbnailPixelSize(for: side),
            showsBackupBadge: mergesLocalPhotos,
            showsAllBackupStatuses: photosConfiguration?.controls.showsAllBackupStatuses ?? false,
            usesOriginalAspectRatio: photosConfiguration?.controls.usesOriginalAspectRatio ?? false,
            isSelecting: isSelecting,
            selection: selection,
            reduceMotion: reduceMotion,
            registry: tileRegistry,
            motion: motion,
            isSelectable: { isSelectable($0) },
            isSelectableAssetID: { isSelectableAssetID($0) },
            actions: tileActions,
            toggleDay: { ids, selects in
                if selects {
                    selection.formUnion(ids)
                } else {
                    selection.subtract(ids)
                }
            }
        )
    }

    private func gridEvents(viewportWidth: CGFloat, viewportHeight: CGFloat) -> TimelineGridEvents {
        TimelineGridEvents(
            onScroll: { handleScroll($0) },
            onIdleChanged: { handleScrollIdle($0) },
            onHeaderHeight: { height in
                // the rail only needs whole points, the rows the exact edge.
                scrub.headerHeight = height.rounded()
                updateVisibleRows()
            },
            onFooterHeight: { scrub.footerHeight = $0.rounded() },
            onPlaceholder: { bucketID in
                // debounced rows: a synchronous rebuild here would change
                // content heights inside the layout pass that mounted it.
                Task { await model.loadBucket(bucketID, immediateRows: false) }
            },
            onPinch: { magnification in
                pinchChanged(
                    magnification,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
            },
            onPinchEnded: { pinchEnded() },
            configureScrollView: { scrollView in
                if photosConfiguration != nil {
                    let fullCanvas = (photosConfiguration?.controls.mode ?? .all) == .all
                    (scrollView as? TimelineGridView)?.usesFullPhotosCanvas = fullCanvas
                    scrollView.contentInsetAdjustmentBehavior = fullCanvas ? .never : .always
                }
                selectionSlideController.attach(to: scrollView)
                selectionSlideController.configure(
                    isEnabled: isSelecting && !isPicking,
                    selectedIDs: selection,
                    assetIDsInRectangle: selectableAssetIDs,
                    applyChanges: applySelectionRectangle,
                    onActiveChanged: handleSelectionSlideActivity
                )
            },
            onDismantle: { [selectionSlideController] in
                selectionSlideController.detach()
            }
        )
    }

    private func handleScroll(_ scroll: TimelineGridScroll) {
        // This callback describes the actual UIScrollView, including its
        // behind-bar extent and current adjusted insets.
        scrollContext.viewportHeight = scroll.containerHeight
        if let layout = model.launchLayout { scrollContext.viewportWidth = CGFloat(layout.width) }
        if let controls = photosConfiguration?.controls, completedPhotosRestoration, !controls.isRestoring {
            if photosConfiguration?.completePeriodIndex == true {
                controls.observeScroll(offset: scroll.offsetY, endOffset: gridController.endOffset,
                                       isUserScrolling: !scrollContext.isIdle)
            } else {
                controls.scrollOffset = scroll.offsetY
            }
        }
        // the indicator is rounded to suppress sub point drawing noise,
        // while the visible rows keep the precise offset.
        scrub.update(with: TimelineScrollState(
            offsetY: scroll.offsetY,
            indicatorOffsetY: max(0, (scroll.offsetY * 2).rounded() / 2),
            insetTop: scroll.insetTop.rounded(),
            insetBottom: scroll.insetBottom.rounded(),
            containerHeight: max(1, scroll.containerHeight.rounded())
        ))
        noteScroll(to: scroll.offsetY)
        updateVisibleRows()
    }

    private func handleScrollIdle(_ isIdle: Bool) {
        if !isIdle { MediaPresentationCoordinator.shared.cancelCheckpoint() }
        if !isIdle { periodMotion.cancel() }
        scrollContext.isIdle = isIdle
        if isIdle {
            settleMotion()
            // the offline sweep resumes once the tiles on screen have had
            // the bandwidth to themselves.
            ImageLoader.shared.setSweepPaused(false)
            updateVisibleRows()
            scheduleIndicatorHide()
            // the scrubber owns the hold for the length of its drag.
            if !scrub.isScrubbing { model.resumeRebuilds() }
        } else {
            ImageLoader.shared.setSweepPaused(true)
            AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                owner: openingChromePrewarmOwner
            )
            showIndicator()
            // reflowing the library under a moving finger is what makes the
            // grid jump; loads keep landing in the model and project in one
            // compensated pass at idle.
            model.deferRebuilds()
        }
    }

    /// the app's own scroll indicator, kept out of `body` so the screen stays
    /// one expression the type checker can still solve.
    @ViewBuilder
    private func scrubberOverlay(scrollable: Bool, side: CGFloat) -> some View {
        if scrollable && !viewer.isTransitioning {
            TimelineScrubber(
                scrub: scrub,
                // an absolute jump to the exact pixel, immich-web's
                // scrollToSegmentPercentage. the grid places every row
                // from the layout, so the layout IS the scroll view's
                // coordinate space and nothing can land short or clamp.
                // the drag is continuous within a month, not snapped.
                onScrub: { fraction in
                    gridController.scrollTo(y: scrub.contentOffset(forFraction: fraction))
                },
                onScrubbingChanged: { scrubbing in
                    if scrubbing {
                        AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                            owner: openingChromePrewarmOwner
                        )
                        showIndicator()
                        model.deferRebuilds()
                    } else {
                        scheduleIndicatorHide()
                        // a drag can end mid-deceleration; the phase
                        // handler lifts the hold once the scroll is
                        // actually at rest.
                        if scrollContext.isIdle { model.resumeRebuilds() }
                        // Force a new window where the drag landed, even if
                        // its last frame happened to stay within the same row.
                        scrollContext.prefetchDirection = nil
                        scrollContext.prefetchIsFast = nil
                    }
                    let apply = { scrubbing ? scrub.beginScrub() : scrub.endScrub() }
                    if reduceMotion {
                        apply()
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { apply() }
                    }
                    if !scrubbing { updateVisibleRows() }
                }
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = tileSide(for: geometry.size.width)
            let layout = rowLayout(side: side)
            let scrollable = isScrollable(rowsHeight: layout.total, viewportHeight: geometry.size.height)
            let tailPadding = bottomPadding()

            ZStack(alignment: .topTrailing) {
                timelineGrid(
                    side: side,
                    tailPadding: tailPadding,
                    viewportWidth: geometry.size.width,
                    viewportHeight: geometry.size.height
                )
                .ignoresSafeArea()
                .accessibilityHidden(photosConfiguration?.controls.mode != nil && photosConfiguration?.controls.mode != .all)
                .allowsHitTesting((photosConfiguration?.controls.mode ?? .all) == .all)
                // the scrollbar is the app's own everywhere, so anything
                // that scrolls at all gets one. gating it on a row count left
                // short albums with no indicator of any kind.
                scrubberOverlay(scrollable: scrollable, side: side)
            }
            .onChange(of: scrollResetTrigger) {
                gridController.scrollToTop()
            }
            .onChange(of: geometry.size.height, initial: true) { _, height in
                let overview = photosConfiguration != nil && photosConfiguration?.controls.mode != .all
                // The overview hides Library's navigation bar. That expected
                // height change belongs to the current photo transition.
                if overview == scrollContext.viewportShowsPhotoOverview { periodMotion.cancel() }
                scrollContext.viewportShowsPhotoOverview = overview
                scrollContext.viewportHeight = height
                updateVisibleRows()
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                periodMotion.cancel()
                applyViewportWidth(width, viewportHeight: geometry.size.height)
                photosConfiguration?.controls.viewportWidth = width
                if let controls = photosConfiguration?.controls, columnCount != controls.columns {
                    applyColumnCount(controls.columns, viewportWidth: width, viewportHeight: geometry.size.height,
                                     preservedFraction: scrub.fraction, recordsUserPreference: true)
                }
            }
            .onChange(of: photosConfiguration?.controls.columns) { _, columns in
                guard let columns, columns != columnCount else { return }
                applyColumnCount(columns, viewportWidth: geometry.size.width, viewportHeight: geometry.size.height,
                                 preservedFraction: scrub.fraction, recordsUserPreference: true)
            }
            .onChange(of: photosConfiguration?.controls.groupsByDate, initial: true) { _, grouped in
                if let grouped { model.showsDateHeaders = grouped }
            }
            .onChange(of: photosConfiguration?.controls.scrollRequest) { _, request in
                guard let request else { return }
                Task { await revealPhotoPeriod(request) }
            }
            .onChange(of: model.rowsLayoutVersion) {
                Task { await restorePhotosPositionIfNeeded() }
            }
            // the window is otherwise only recomputed while scrolling, so a
            // grid that has just filled in sits with nothing warmed past the
            // fold until the first drag.
            .onChange(of: model.flatAssets.count) {
                prefetcher.update(
                    visibleRowIDs: scrollContext.visibleRowIDs,
                    model: model,
                    client: session.client,
                    backup: session.backup,
                    targetPixelSize: thumbnailPixelSize(for: side),
                    direction: scrollContext.direction,
                    isFast: motion.isFast
                )
            }
            // keyed on the row tallies and the layout version, so any change
            // of layout - a bucket filling in, a pinch, a month appearing -
            // re-measures the months and re-windows the rows, which may have
            // shifted under a fixed scroll offset.
            .onChange(of: ScrubberLayoutKey(model: model, side: side), initial: true) { _, _ in
                let months = Self.scrubberMonths(spans: model.sectionSpans, side: side)
                scrub.liveMonths = months
                scrub.monthsHeight = model.contentHeight(tileSide: side)
                updateVisibleRows()
            }
            .onChange(of: tailPadding, initial: true) { _, padding in
                scrub.tailPadding = padding
            }
            .onChange(of: viewer.isTransitioning) { _, isTransitioning in
                if isTransitioning {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                } else {
                    updateVisibleRows()
                }
            }
            .onChange(of: isSelecting) { _, isSelecting in
                photosConfiguration?.controls.isSelecting = isSelecting
                if isSelecting {
                    AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                        owner: openingChromePrewarmOwner
                    )
                } else {
                    updateVisibleRows()
                }
            }
            .onDisappear {
                AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                    owner: openingChromePrewarmOwner
                )
            }
        }
        .onAppear {
            periodMotion.reducesMotion = reduceMotion
            photosConfiguration?.controls.onModeChange = { from, to in preparePeriodTransition(from: from, to: to) }
        }
        .onDisappear {
            photosConfiguration?.controls.onModeChange = nil
            periodMotion.cancel()
        }
        .onChange(of: reduceMotion) { _, enabled in
            periodMotion.reducesMotion = enabled
            if enabled { periodMotion.cancel() }
        }
        .onChange(of: session.client?.offlineAccountKey) { _, _ in
            periodMotion.cancel()
            photosConfiguration?.controls.periodAnchor = nil
        }
        .navigationTitle(title)
        .preference(key: PhotosSelectionPreferenceKey.self, value: isSelecting)
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        // one toolbar owns the whole trailing group, so selection swaps the
        // items in place - the bar itself stays put and the controls fade
        // where they are instead of sliding away with it. only the tab bar
        // leaves, for the bottom controls, like the photos app.
        .toolbar { timelineToolbar }
        .toolbarVisibility(photosConfiguration != nil && photosConfiguration?.controls.mode != .all ? .hidden : .automatic,
                           for: .navigationBar)
        .toolbarVisibility(isSelecting || usesCompactPhotosNavigation ? .hidden : .automatic, for: .tabBar)
        .toolbarBackground(photosConfiguration == nil ? .automatic : .hidden, for: .navigationBar)
        .toolbarColorScheme(extendsPhotosBehindBars ? .dark : nil, for: .navigationBar)
        .overlay(alignment: .top) {
            if extendsPhotosBehindBars {
                Rectangle().fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.3),
                                                  .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 165).ignoresSafeArea(edges: .top).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .navigationBarBackButtonHidden(isSelecting)
        .overlay {
            if showsEmptyState { overlayState }
        }
        .overlay {
            if let configuration = photosConfiguration, configuration.controls.mode != .all {
                PhotoCalendarOverview(gridModel: model, controls: configuration.controls, motion: periodMotion)
                    .transition(.identity)
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if isSelecting, !isPicking {
                    SelectionControlBar(
                        count: selection.count,
                        mediaCounts: selectedMediaCounts,
                        filter: filter,
                        isWorking: isSelectionWorking,
                        onShare: shareSelection,
                        onShowSelected: presentSelectedSheet,
                        onRestore: filter.isTrashed == true ? { await applyRestore() } : nil,
                        onTrash: { await applyTrash() },
                        trashDisabled: selectionHasForeignAssets
                    )
                    .transition(.opacity)
                } else if let configuration = photosConfiguration, showsPeriodControls, horizontalSizeClass == .regular {
                    PhotoPeriodControls(controls: configuration.controls, onSearch: configuration.onSearch)
                }
            }
            .animation(.smooth(duration: 0.25), value: isSelecting)
        }
        .deviceCopyRemovalPresentation(deviceCopyRemoval)
        .confirmationDialog("Back Up Again?", isPresented: Binding(
            get: { pendingRebackup != nil }, set: { if !$0 { pendingRebackup = nil } }
        ), titleVisibility: .visible, presenting: pendingRebackup) { confirmation in
            Button("Back Up Again") {
                let backup = session.backup
                Task {
                    do { _ = try await backup?.rebackupAfterConfirmation(confirmation) }
                    catch { ErrorToastCenter.shared.show(String(localized: "Couldn't back up"), error: error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This photo was deleted in the cloud. Back Up Again restores its cloud copy from trash when available, or uploads a new copy if it was permanently deleted. The original stays on this device.")
        }
        .sheet(isPresented: $showsSelectedSheet) {
            SelectedAssetsSheet(assets: selectedSheetAssets, selection: $selection)
        }
        // no pull-to-refresh: the realtime hub keeps every grid current.
        .task {
            model.assetProjection = { [weak session = session] asset in
                session?.projectingFavorite(asset) ?? asset
            }
            if let client = session.client {
                model.attach(client, backup: session.backup, hub: session.realtime, preparesLaunchViewport: true)
                model.columns = columnCount
                // capture list only - a self capture would cycle through the
                // @state storage that owns the model and leak it on pop. the
                // weak capture is renamed so it does not shadow the strong
                // reference this task already holds.
                model.applyRowsUpdate = { [weak weakModel = model, context = scrollContext, grid = gridController] old, new, animated, apply in
                    Self.applyRowsChange(
                        old: old, new: new, animated: animated, apply: apply,
                        model: weakModel, context: context, grid: grid
                    )
                }
                model.onUnauthorized = onUnauthorized
                await model.waitForLaunchLayout()
                guard !Task.isCancelled else { return }
                if !model.usesSuppliedAssets { await model.load() }
                await revealPendingTimelineTarget()
                await restorePhotosPositionIfNeeded()
            }
        }
        .onChange(of: navigationTarget) {
            Task { await revealPendingTimelineTarget() }
        }
        .onChange(of: model.rowsContentVersion) {
            if navigationTarget != nil { Task { await revealPendingTimelineTarget() } }
        }
        .onChange(of: resyncTrigger) {
            model.requestResync()
        }
        // a selection made before the mode began would come back with it.
        .onChange(of: isPicking) { _, picking in
            if picking { exitSelection() }
        }
        .onChange(of: serverCommand) { _, command in
            guard let command else { return }
            serverCommand = nil
            Task { await run(command) }
        }
        // the pipeline outlives the screen, so a window left open would keep
        // downloading tiles for a grid nobody is looking at.
        .onDisappear {
            model.releaseCachedLaunch()
            photosConfiguration?.controls.isSelecting = false
            MediaPresentationCoordinator.shared.cancelCheckpoint()
            prefetcher.cancel()
            model.resumeRebuilds()
            ImageLoader.shared.setSweepPaused(false)
        }
        .sheet(item: $pendingAlbumAssets) { ids in
            let selected = model.flatAssets.filter { ids.contains($0.id) }
            AlbumPickerSheet(
                assetIDs: selected.compactMap { serverIdentifier(for: $0) },
                localIdentifiers: selected.filter { serverIdentifier(for: $0) == nil }.compactMap(\.localIdentifier),
                sourceAccountGeneration: session.client?.context.id,
                onApplied: exitSelection,
                onRollback: { failedIDs in
                    selection.formUnion(selected.filter { asset in
                        serverIdentifier(for: asset).map { failedIDs.contains($0) } ?? false
                    }.map(\.id))
                    isSelecting = !selection.isEmpty
                }
            )
        }
        .sheet(item: $pendingSpaceAssets) { ids in
            SpacePickerSheet(assetIDs: ids, onApplied: exitSelection)
        }
        .background {
            AssetSharePresenter(request: $shareRequest) {
                exitSelection()
            }
        }
        // escape leaves selection mode from a hardware keyboard. installed
        // for the mode only, so the grid never holds the keyboard otherwise.
        .background {
            if isSelecting, !isPicking {
                KeyCommandHost(
                    isActive: true,
                    commands: [
                        KeyCommandBinding(title: String(localized: "Cancel Selection"), input: UIKeyCommand.inputEscape) {
                            exitSelection()
                        },
                    ]
                )
            }
        }
        .fullScreenCover(item: $pendingEditAsset) { asset in
            AssetEditScreen(asset: asset,
                            localAssetIdentifier: asset.localIdentifier,
                            onLocalSaved: { _ in
                LocalImageLoader.shared.noteLibraryChange()
                model.updateAssets(ids: [asset.id]) { $0.localImageVersion = UUID().uuidString }
                session.realtime?.notifyLocalChange()
            }, onRemoteSaveUnconfirmed: { _ in
                session.backup?.noteRemoteEdits([asset.id])
                model.realtimeResync()
            }) { outcome in
                guard case .saved(let detail) = outcome else { return }
                guard !asset.isLocal else { return }
                model.updateAssets(ids: [asset.id]) { current in
                    if let thumbhash = detail?.thumbhash { current.thumbhash = thumbhash }
                    if current.isVideo, let duration = detail?.duration { current.duration = duration }
                }
                // The device original is no longer a valid render source for
                // the edited server asset, even when refreshing its detail fails.
                session.backup?.noteRemoteEdits([asset.id])
            }
        }
    }

    // MARK: - rows

    private var extendsPhotosBehindBars: Bool {
        photosConfiguration != nil && (photosConfiguration?.controls.mode ?? .all) == .all
            && model.contentHeight(tileSide: tileSide(for: max(1, scrollContext.viewportWidth))) > scrollContext.viewportHeight
    }

    private var showsPeriodControls: Bool {
        guard let c = photosConfiguration, c.completePeriodIndex, !isSelecting else { return false }
        return c.controls.browsingPast || c.controls.mode != .all
    }

    private func restorePhotosPositionIfNeeded() async {
        guard let controls = photosConfiguration?.controls, !restoredPhotosPosition,
              !model.sections.isEmpty, scrollContext.viewportWidth > 0 else { return }
        restoredPhotosPosition = true
        if model.hasRestoredLaunchViewport {
            completedPhotosRestoration = true
            return
        }
        let savedOffset = controls.scrollOffset
        controls.isRestoring = true
        defer {
            controls.isRestoring = false
            completedPhotosRestoration = true
        }
        if savedOffset == nil, filter.order?.lowercased() == "asc", let last = model.sections.last {
            await model.loadBucket(last.id)
        }
        await Task.yield()
        gridController.reloadRows(animated: false)
        if let offset = savedOffset { gridController.scrollTo(y: offset) }
        else if filter.order?.lowercased() == "asc" { gridController.scrollToEnd() }
    }

    private func preparePeriodTransition(from: PhotoBrowseMode, to: PhotoBrowseMode) {
        guard let controls = photosConfiguration?.controls else { return }
        var tile: TimelineTileView?
        if from == .all {
            tile = gridController.periodTile(assetID: controls.periodAnchor?.asset.id) ?? gridController.periodTile()
            if let asset = tile?.asset,
               let bucket = model.sections.first(where: { $0.days?.contains(where: { $0.assets.contains(where: { $0.id == asset.id }) }) == true }) {
                controls.periodAnchor = PhotoPeriodAnchor(asset: asset, bucketID: bucket.id, scrollOffset: gridController.scrollOffset)
            }
        }
        guard let anchor = controls.periodAnchor else { periodMotion.cancel(); return }
        periodMotion.begin(assetID: anchor.asset.id, from: from, to: to, gridSource: tile, reduceMotion: periodMotion.reducesMotion)
        if to == .all {
            controls.scrollRequest = PhotoScrollRequest(bucketID: anchor.bucketID, assetID: anchor.asset.id)
        }
    }

    private func revealPhotoPeriod(_ request: PhotoScrollRequest) async {
        guard let controls = photosConfiguration?.controls else { return }
        controls.isRestoring = true
        defer {
            if controls.scrollRequest == request {
                controls.scrollOffset = gridController.scrollOffset
                controls.isRestoring = false
            }
        }
        guard let requestedBucketID = request.bucketID else {
            gridController.scrollToEnd()
            return
        }
        let bucketID: String
        if model.filter.groupsByUploadDate, let anchor = controls.periodAnchor,
           anchor.asset.id == request.assetID {
            guard let mapped = PhotoCalendarSource.gridBucketID(for: anchor.asset, in: model) else {
                ErrorToastCenter.shared.show(String(localized: "Couldn't locate this photo in the current sort. Try again."))
                return
            }
            bucketID = mapped
        } else { bucketID = requestedBucketID }
        await model.loadBucket(bucketID)
        guard controls.scrollRequest == request,
              let assetID = request.assetID ?? model.sections.first(where: { $0.id == bucketID })?.days?.first?.assets.first?.id,
              let rowIndex = model.rowIndex(containingAnyOf: [assetID]) else { return }
        let layout = rowLayout(side: tileSide(for: scrollContext.viewportWidth))
        guard layout.starts.indices.contains(rowIndex), model.rows.indices.contains(rowIndex) else { return }
        gridController.reloadRows(animated: false)
        let sourceOffset = controls.periodAnchor.flatMap { $0.asset.id == assetID ? $0.scrollOffset : nil }
        let rowHeight = model.rows[rowIndex].height(tileSide: tileSide(for: scrollContext.viewportWidth))
        let centeringInset = max(0, (scrollContext.viewportHeight - rowHeight) / 2)
        let targetOffset = max(0, scrub.headerHeight + layout.starts[rowIndex] - centeringInset)
        gridController.scrollTo(y: sourceOffset ?? targetOffset)
        await Task.yield()
        guard controls.scrollRequest == request, controls.mode == .all else { return }
        if let tile = gridController.periodTile(assetID: assetID) { periodMotion.arrive(at: tile, mode: .all) }
    }

    private func revealPendingTimelineTarget() async {
        guard let target = navigationTarget,
              scrollContext.viewportWidth > 0
        else { return }
        if let bucketID = model.bucketID(containing: target.localDate) {
            await model.loadBucket(bucketID)
        }
        guard navigationTarget == target,
              let rowIndex = model.rowIndex(containingAnyOf: target.candidateAssetIDs)
        else { return }

        let side = tileSide(for: scrollContext.viewportWidth)
        let layout = rowLayout(side: side)
        guard layout.starts.indices.contains(rowIndex), model.rows.indices.contains(rowIndex) else { return }
        let rowHeight = model.rows[rowIndex].height(tileSide: side)
        let centeringInset = max(0, (scrollContext.viewportHeight - rowHeight) / 2)
        let offset = max(0, scrub.headerHeight + layout.starts[rowIndex] - centeringInset)
        gridController.scrollTo(y: offset)
        navigationTarget = nil
    }

    /// lands a rows swap the way the official clients do: content that
    /// changed above the viewport applies instantly with the scroll offset
    /// shifted by the exact height delta, so visible photos never move;
    /// changes in or below the viewport reflow with an animation when one
    /// was requested.
    private static func applyRowsChange(
        old: [TimelineRow],
        new: [TimelineRow],
        animated: Bool,
        apply: () -> Void,
        model: TimelineModel?,
        context: ScrollContext,
        grid: TimelineGridController
    ) {
        // at rest at the very top, new rows above simply show, like the
        // device photos merging in at launch. holding the old first row
        // there would push the header and the newest photos out of view.
        if context.isIdle,
           context.offsetY > 0.5,
           let model,
           context.viewportWidth > 0,
           let anchor = context.firstVisibleRowID {
            let side = AssetGridLayout.tileSide(
                viewportWidth: context.viewportWidth,
                columns: model.columns
            )
            if model.hasRestoredLaunchViewport, let assetID = context.firstVisibleAssetID,
               let oldRow = model.rowIndex(containingAnyOf: [assetID]), old.indices.contains(oldRow),
               let oldStart = TimelineModel.rowStart(of: old[oldRow].id, in: old, tileSide: side) {
                // W0 metadata contains only visible assets. Expanding its day
                // from the normal cache/server changes row ordinals; preserve
                // the actual visible subject rather than the provisional rowID.
                apply()
                if let newRow = model.rowIndex(containingAnyOf: [assetID]), new.indices.contains(newRow),
                   let newStart = TimelineModel.rowStart(of: new[newRow].id, in: new, tileSide: side) {
                    grid.scrollTo(y: max(0, context.offsetY + newStart - oldStart))
                }
                grid.reloadRows(animated: false)
                return
            }
            if let oldStart = TimelineModel.rowStart(of: anchor, in: old, tileSide: side),
               let newStart = TimelineModel.rowStart(of: anchor, in: new, tileSide: side),
               abs(newStart - oldStart) > 0.5 {
                apply()
                // 0 is the rest position in this space, and the floor. the
                // rows are laid out in the same breath as the jump, so the
                // visible photos never move.
                grid.scrollTo(y: max(0, context.offsetY + newStart - oldStart))
                grid.reloadRows(animated: false)
                return
            }
        }
        if !animated || UIAccessibility.isReduceMotionEnabled || !context.isIdle {
            apply()
        } else {
            // the animations run before this returns, so the swap never
            // outlives the call that owns it.
            withoutActuallyEscaping(apply) { apply in
                UIView.animate(springDuration: 0.3, bounce: 0) {
                    apply()
                    grid.reloadRows(animated: true)
                }
            }
        }
    }

    /// one set for every row, each taking the asset it is asked about.
    private var tileActions: TimelineTileActions {
        TimelineTileActions(
            pick: onPickAsset,
            toggleSelection: { toggle($0) },
            menu: { UIMenu(children: menuElements(for: $0)) },
            makeViewer: { asset, startsAsContextPreview, bounds in
                periodMotion.cancel()
                return viewerController(
                    for: asset,
                    startsAsContextPreview: startsAsContextPreview,
                    previewBounds: bounds
                )
            }
        )
    }

    // MARK: - context menu

    /// Single-asset menu behind the long-press preview. Eligibility comes from
    /// the same device/server/owner policy as the viewer, so partner assets and
    /// paired device copies cannot accidentally receive owner-only actions.
    private func menuElements(for asset: Asset) -> [UIMenuElement] {
        let serverID = serverIdentifier(for: asset)
        let pairedLocalID = pairedLocalIdentifier(for: asset)
        let availability = AssetActionAvailability(
            asset: asset,
            ownsAsset: owns(asset),
            localRemoteIdentifier: asset.isLocal ? serverID : nil,
            pairedLocalIdentifier: pairedLocalID,
            perUserFavorites: session.capabilities.supportsPerUserFavorites,
            trimsVideos: session.capabilities.supportsTrim
        )
        let mutationAttributes: UIMenuElement.Attributes = isRunningServerCommand || mutatingAssetIDs.contains(asset.id)
            ? .disabled
            : []

        var primary: [UIMenuElement] = []
        if availability.canRestore, let serverID {
            primary.append(UIAction(
                title: String(localized: "Restore"),
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await restore(ids: [serverID]) }
            })
        }
        if availability.canFavorite {
            primary.append(UIAction(
                title: asset.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await favorite(ids: [asset.id], value: !session.projectingFavorite(asset).isFavorite) }
            })
        }
        if availability.canEdit {
            primary.append(UIAction(title: String(localized: "Edit"), image: UIImage(systemName: "slider.horizontal.3")) { _ in
                pendingEditAsset = asset
            })
        }
        if availability.canAddToAlbum {
            primary.append(UIAction(title: String(localized: "Add to Album"), image: UIImage(systemName: "rectangle.stack.badge.plus")) { _ in
                pendingAlbumAssets = [asset.id]
            })
        }
        if canRemoveFromAlbum(asset), let serverID {
            primary.append(UIAction(
                title: String(localized: "Remove from Album"),
                image: UIImage(systemName: "rectangle.stack.badge.minus"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await removeFromAlbum(ids: [serverID]) }
            })
        }
        if canRemoveFromSpace, filter.spaceId != nil, !asset.isLocal, let serverID {
            primary.append(UIAction(
                title: String(localized: "Remove from Space"),
                image: UIImage(systemName: "person.3.sequence"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await removeFromSpace(ids: [serverID]) }
            })
        }
        if canSetAlbumCover(asset), let serverID {
            primary.append(UIAction(
                title: String(localized: "Set as Album Cover"),
                image: UIImage(systemName: "photo.badge.checkmark"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await setAlbumCover(id: serverID) }
            })
        }
        if availability.canArchive, let serverID {
            let isArchived = asset.visibility == .archive
            primary.append(UIAction(
                title: isArchived ? String(localized: "Unarchive") : String(localized: "Archive"),
                image: UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await setVisibility(ids: [serverID], isArchived ? .timeline : .archive) }
            })
        }
        if availability.canLock, serverID != nil {
            primary.append(UIAction(
                title: String(localized: "Move to Locked Folder"),
                image: UIImage(systemName: "lock"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await lockAssets([asset]) }
            })
        }
        if availability.canUnlock, let serverID {
            primary.append(UIAction(
                title: String(localized: "Remove from Locked Folder"),
                image: UIImage(systemName: "lock.open"),
                attributes: mutationAttributes
            ) { _ in
                Task { _ = await setVisibility(ids: [serverID], .timeline) }
            })
        }

        var transfer: [UIMenuElement] = []
        transfer.append(UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
            shareRequest = AssetShareRequest(assets: [asset])
        })
        if asset.isLocal, let localID = asset.localIdentifier {
            transfer.append(backupMenuElement(for: asset, localID: localID))
        }
        if availability.canDownload {
            if downloadingAssetIDs.contains(asset.id) {
                transfer.append(UIAction(
                    title: String(localized: "Downloading…"),
                    image: UIImage(systemName: "arrow.down.circle.dotted"),
                    attributes: .disabled
                ) { _ in })
            } else {
                transfer.append(UIAction(title: String(localized: "Download to Device"), image: UIImage(systemName: "arrow.down.circle")) { _ in
                    Task { await download(asset) }
                })
            }
        }
        if let serverID, !asset.isTrashed, !availability.isLocked {
            transfer.append(UIAction(title: String(localized: "Open in Browser"), image: UIImage(systemName: "safari")) { _ in
                Task { await openInBrowser(serverID: serverID) }
            })
        }

        var destructive: [UIMenuElement] = []
        if availability.canDeleteFromDevice, let pairedLocalID {
            destructive.append(UIAction(
                title: String(localized: "Delete from This Device"),
                image: UIImage(systemName: "iphone.slash"),
                attributes: .destructive
            ) { _ in
                Task { await deleteFromDevice(asset: asset, localID: pairedLocalID) }
            })
        }
        if availability.canTrashEverywhere, serverID != nil {
            destructive.append(UIAction(
                title: pairedLocalID == nil ? String(localized: "Move to Trash") : String(localized: "Move to Trash Everywhere"),
                image: UIImage(systemName: "trash"),
                attributes: [.destructive, mutationAttributes]
            ) { _ in
                Task { _ = await deleteAssets([asset], force: false) }
            })
        }
        if availability.canDeletePermanently, serverID != nil {
            destructive.append(UIAction(
                title: String(localized: "Delete Permanently"),
                image: UIImage(systemName: "trash.slash"),
                attributes: [.destructive, mutationAttributes]
            ) { _ in
                Task { _ = await deleteAssets([asset], force: true) }
            })
        }

        var sections: [UIMenuElement] = []
        if !primary.isEmpty { sections.append(UIMenu(options: .displayInline, children: primary)) }
        if !transfer.isEmpty { sections.append(UIMenu(options: .displayInline, children: transfer)) }
        if !destructive.isEmpty { sections.append(UIMenu(options: .displayInline, children: destructive)) }
        return sections
    }

    private func backupMenuElement(
        for asset: Asset,
        localID: String
    ) -> UIMenuElement {
        if session.backup?.remoteRemovedLocalIDs.contains(localID) == true {
            return UIAction(title: String(localized: "Back Up Again…"), image: UIImage(systemName: "icloud.and.arrow.up")) { _ in
                pendingRebackup = session.backup?.rebackupConfirmation(localIdentifier: localID)
            }
        }
        if asset.isLocalBackedUp || session.backup?.hasVerifiedBackup(localIdentifier: localID) == true {
            return UIAction(title: String(localized: "Backed Up"), image: UIImage(systemName: "checkmark.icloud"),
                            attributes: .disabled) { _ in }
        }
        switch session.backup?.uploadStates[localID] {
        case .uploading(let fraction):
            let percent = Int((fraction * 100).rounded())
            return UIAction(
                title: String(localized: "Backing Up… \(percent)%"),
                image: UIImage(systemName: "icloud.and.arrow.up"),
                attributes: .disabled
            ) { _ in }
        case .failed:
            return UIAction(title: String(localized: "Retry Backup"), image: UIImage(systemName: "exclamationmark.icloud")) { _ in
                Task { await backUp(localID: localID) }
            }
        case nil:
            if session.backup?.sizeExcludedLocalIdentifiers.contains(localID) == true {
                return UIAction(title: String(localized: "Excluded by Upload Size Limit"),
                                image: UIImage(systemName: "minus.circle"),
                                attributes: .disabled) { _ in }
            }
            guard session.backup != nil else {
                return UIAction(
                    title: String(localized: "Backup Unavailable"),
                    image: UIImage(systemName: "icloud.slash"),
                    attributes: .disabled
                ) { _ in }
            }
            return UIAction(title: String(localized: "Back Up Now"), image: UIImage(systemName: "icloud.and.arrow.up")) { _ in
                Task { await backUp(localID: localID) }
            }
        }
    }

    private func serverIdentifier(for asset: Asset) -> String? {
        guard asset.isLocal else { return asset.id }
        guard let localID = asset.localIdentifier else { return nil }
        return session.backup?.remoteIdentifierByLocalId[localID]
    }

    private func pairedLocalIdentifier(for asset: Asset) -> String? {
        if let localID = asset.localIdentifier { return localID }
        return downloadedLocalIdentifiers[asset.id]
            ?? session.backup?.pairedLocalIdentifierByRemoteId[asset.id]
    }

    private func owns(_ asset: Asset) -> Bool {
        if asset.isLocal { return true }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    private func canRemoveFromAlbum(_ asset: Asset) -> Bool {
        guard filter.albumId != nil, !asset.isLocal else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID || albumOwnerID == userID
    }

    private func canSetAlbumCover(_ asset: Asset) -> Bool {
        onSetAlbumCover != nil && !asset.isLocal && !asset.isTrashed
    }

    /// Source-specific actions resolve device and server identities separately.
    private func isSelectable(_ asset: Asset) -> Bool {
        if asset.isLocal { return true }
        return owns(asset)
    }

    private func isSelectableAssetID(_ id: String) -> Bool {
        guard let index = model.flatAssetIndex(for: id) else { return false }
        return isSelectable(model.flatAssets[index])
    }

    /// device ids carry the local- prefix, so selection composition reads
    /// off the id set without walking the model.
    private var selectionHasLocalAssets: Bool {
        selection.contains { $0.hasPrefix("local-") }
    }

    /// backed-up device photos are never selectable, so a local-only
    /// selection is exactly the not-yet-backed-up one bulk backup serves.
    private var isBackupOnlySelection: Bool {
        !selection.isEmpty && selection.allSatisfy { $0.hasPrefix("local-") }
    }

    @ViewBuilder private var overlayState: some View {
        // rows, not sections: cache-restored months and merged device photos
        // are real content, and a failed server load must not cover them.
        if model.isLoading && model.rows.isEmpty {
            ProgressView()
        } else if let error = model.loadError, model.rows.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.glass)
            }
        } else if model.isEmpty {
            ContentUnavailableView(emptyMessage, systemImage: emptyIcon)
        }
    }

    // MARK: - gestures

    private func pinchChanged(_ magnification: CGFloat, viewportWidth: CGFloat, viewportHeight: CGFloat) {
        guard magnification > 0 else { return }
        periodMotion.cancel()
        if pinchBaseColumns == nil {
            AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                owner: openingChromePrewarmOwner
            )
        }
        let base = pinchBaseColumns ?? columnCount
        pinchBaseColumns = base
        // zooming in shows fewer, larger tiles.
        let target = TimelineGridZoomGeometry.columns(base: base, magnification: magnification, width: viewportWidth)
        guard target != columnCount else { return }

        let preservedFraction = scrub.fraction
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()

        applyColumnCount(
            target,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            preservedFraction: preservedFraction,
            recordsUserPreference: true
        )
    }

    private func pinchEnded() {
        pinchBaseColumns = nil
        updateVisibleRows()
    }

    // MARK: - selection

    /// deselecting the last item keeps the mode on - the pill just reads
    /// "Select Items" again, exactly like photos.app.
    private func toggle(_ asset: Asset) {
        if selection.contains(asset.id) {
            selection.remove(asset.id)
        } else {
            selection.insert(asset.id)
        }
    }

    private func selectableAssetIDs(
        in rectangle: SelectionGridRectangle
    ) -> Set<String> {
        guard !model.rows.isEmpty else { return [] }
        let lowerRow = max(0, rectangle.rows.lowerBound)
        let upperRow = min(model.rows.count - 1, rectangle.rows.upperBound)
        guard lowerRow <= upperRow else { return [] }

        var result = Set<String>()
        for rowIndex in lowerRow...upperRow {
            guard case .tiles(_, let runs) = model.rows[rowIndex] else { continue }
            for run in runs {
                for (offset, asset) in run.assets.enumerated() {
                    let column = run.colStart + offset
                    guard rectangle.columns.contains(column),
                          isSelectable(asset),
                          !model.projectedRemovalIDs.contains(asset.id)
                    else { continue }
                    result.insert(asset.id)
                }
            }
        }
        return result
    }

    private func applySelectionRectangle(
        _ changes: [SelectionRectangleState.Change]
    ) {
        guard isSelecting, !changes.isEmpty else { return }
        var updated = selection
        for change in changes where isSelectableAssetID(change.assetID) {
            if change.selects {
                updated.insert(change.assetID)
            } else {
                updated.remove(change.assetID)
            }
        }
        selection = updated
    }

    private func handleSelectionSlideActivity(_ isActive: Bool) {
        if isActive {
            AssetViewerOpeningChromeCache.shared.cancelPrewarming(
                owner: openingChromePrewarmOwner
            )
            showIndicator()
            model.deferRebuilds()
            return
        }
        scheduleIndicatorHide()
        model.resumeRebuilds()
        updateVisibleRows()
    }

    /// entry and exit run inside one animation so the toolbar swap, the tab
    /// bar fade and the bottom controls fade move together.
    private func enterSelection() {
        withAnimation(.smooth(duration: 0.25)) {
            isSelecting = true
        }
    }

    private func exitSelection() {
        showsSelectedSheet = false
        withAnimation(.smooth(duration: 0.25)) {
            isSelecting = false
            selection.removeAll()
        }
        selectedSheetAssets.removeAll()
    }

    /// walks the selection rather than the whole timeline, this runs on every render.
    /// a partner's or a space member's photos are picked. walks the selection,
    /// not the grid, so it stays cheap on large libraries.
    private var selectionHasForeignAssets: Bool {
        let indexByID = model.viewerAssetIndexByID
        let assets = model.flatAssets
        return selection.contains { id in
            guard let index = indexByID[id], assets.indices.contains(index) else { return false }
            return !owns(assets[index])
        }
    }

    private var selectedMediaCounts: MediaCounts {
        var counts = MediaCounts()
        let indexByID = model.viewerAssetIndexByID
        let assets = model.flatAssets
        for id in selection {
            guard let index = indexByID[id], assets.indices.contains(index) else { continue }
            if assets[index].isImage { counts.photos += 1 } else { counts.videos += 1 }
        }
        return counts
    }

    private var isSelectionWorking: Bool {
        isRunningServerCommand || !selection.isDisjoint(with: mutatingAssetIDs)
    }

    /// the asset list is captured here so deselecting immediately afterwards
    /// cannot change what was asked for; metadata options come from the saved
    /// defaults. selection clears on tap so the grid is free while the share
    /// prepares in the background.
    private func shareSelection() {
        let assets = model.flatAssets.filter { selection.contains($0.id) }
        guard !assets.isEmpty else { return }
        shareRequest = AssetShareRequest(assets: assets, options: .current)
        exitSelection()
    }

    private func presentSelectedSheet() {
        selectedSheetAssets = model.flatAssets.filter { selection.contains($0.id) }
        showsSelectedSheet = true
    }

    private func viewerController(
        for asset: Asset,
        startsAsContextPreview: Bool,
        previewBounds: CGSize
    ) -> AssetViewerHostingController? {
        guard let index = model.flatAssetIndex(for: asset.id) else { return nil }
        guard let route = viewer.makeRoute(
            assets: model.flatAssets,
            initialIndex: index,
            indexByAssetID: model.viewerAssetIndexByID
        ) else { return nil }

        return AssetViewerHostingController(
            route: route,
            startsAsContextPreview: startsAsContextPreview,
            previewBounds: previewBounds,
            session: session,
            sourceRegistry: tileRegistry,
            openingChromePresentation: startsAsContextPreview
                ? nil
                : AssetViewerOpeningChromePresentation(asset: asset, session: session),
            album: filter.albumId.map { AlbumContext(id: $0, ownerID: albumOwnerID, activity: albumActivity) },
            onSetAlbumCover: onSetAlbumCover,
            personID: filter.personId,
            willPresent: { route in beginViewerPresentation(route) },
            didPresent: { id in finishViewerOpening(id) },
            didDismiss: { id in finishViewer(id) },
            onChange: { change in handleViewerChange(change) }
        )
    }

    private func beginViewerPresentation(_ route: ViewerRoute) -> Bool {
        viewer.activate(
            route,
            presentsCover: false,
            replacesSettlingPresentation: true
        )
    }

    private func finishViewerOpening(_ id: UUID) {
        guard viewer.isActive(id) else { return }
        model.suspendForViewer()
        hideScrubberForViewer()
    }

    private func finishViewer(_ id: UUID) {
        viewer.complete(id)
        guard !viewer.isTransitioning else { return }
        model.resumeAfterViewer()
    }

    private func hideScrubberForViewer() {
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        // a drag interrupted by the viewer never reaches its onEnded, so the
        // hold it took out is released here rather than left standing.
        model.resumeRebuilds()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if scrub.isScrubbing { scrub.endScrub() }
            if scrub.indicatorVisible { scrub.indicatorVisible = false }
            if scrub.indicatorGrabbable { scrub.indicatorGrabbable = false }
        }
    }

    private func showIndicator() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        // a phase change fires three times a fling and @observable notifies on
        // every write, equal or not, so each one is worth a look first.
        if !scrub.indicatorGrabbable { scrub.indicatorGrabbable = true }
        guard !scrub.indicatorVisible else { return }
        if reduceMotion {
            scrub.indicatorVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.12)) { scrub.indicatorVisible = true }
        }
    }

    private func scheduleIndicatorHide() {
        guard !viewer.isTransitioning else { return }
        indicatorHideTask?.cancel()
        indicatorHideTask = Task {
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            if reduceMotion {
                scrub.indicatorVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.25)) { scrub.indicatorVisible = false }
            }
            // grace window: the thumb is gone but still catchable, so reaching
            // for it right after it fades does not scroll the grid instead.
            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled, !scrub.isScrubbing else { return }
            scrub.indicatorGrabbable = false
        }
    }

    private func handleViewerChange(_ change: AssetChange) {
        switch change {
        case .favorite(let id, let value):
            if let requiredValue = filter.isFavorite {
                if value == requiredValue {
                    model.rollbackExternalOptimisticRemoval(id: id)
                    model.updateAssets(ids: [id]) { $0.isFavorite = value }
                } else {
                    model.beginExternalOptimisticRemoval(id: id)
                }
            } else {
                model.beginExternalOptimisticFavorite(id: id, value: value)
            }
        case .favoriteCommitted(let id, let value):
            if let requiredValue = filter.isFavorite, value != requiredValue {
                model.commitExternalOptimisticRemoval(id: id)
            } else if filter.isFavorite == nil {
                model.commitExternalOptimisticFavorite(id: id)
            }
        case .optimisticRemoval(let id):
            model.beginExternalOptimisticRemoval(id: id)
        case .removalCommitted(let id):
            model.commitExternalOptimisticRemoval(id: id)
        case .removalReverted(let id):
            model.rollbackExternalOptimisticRemoval(id: id)
        case .albumMembershipProjected:
            onAlbumAssetCountDelta?(-1)
        case .albumMembershipCommitted:
            break
        case .albumMembershipReverted:
            onAlbumAssetCountDelta?(1)
        case .removed(let id):
            model.removeAssets(ids: [id])
        case .localDeleted:
            // the server copy remains, so the timeline keeps the asset.
            break
        case .edited(let id, let thumbhash, let duration):
            model.updateAssets(ids: [id]) { asset in
                if let thumbhash { asset.thumbhash = thumbhash }
                if let duration { asset.duration = duration }
            }
        }
    }

    private func run(_ command: TimelineServerCommand) async {
        guard !isRunningServerCommand else {
            ErrorToastCenter.shared.show(String(localized: "A trash action is already in progress."))
            return
        }
        let action = command == .restoreAllTrash
            ? String(localized: "Couldn't restore the trash")
            : String(localized: "Couldn't empty the trash")
        guard mutatingAssetIDs.isEmpty else {
            ErrorToastCenter.shared.show(String(localized: "Wait for the current photo action to finish."))
            return
        }
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "\(action). The server is not available."))
            return
        }
        isRunningServerCommand = true
        let snapshot = model.clearForOptimisticAction()
        exitSelection()
        defer { isRunningServerCommand = false }
        do {
            switch command {
            case .restoreAllTrash:
                try await client.restoreTrash()
            case .emptyTrash:
                try await client.emptyTrash()
            }
            model.commit(snapshot)
        } catch {
            model.restore(snapshot)
            ErrorToastCenter.shared.show(action, error: error)
        }
    }

    // MARK: - asset actions

    @discardableResult
    private func favorite(ids: [String], value: Bool) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "Couldn't update favorites. The server is not available."))
            return false
        }

        let leavesCurrentFilter = filter.isFavorite.map { $0 != value } ?? false
        var favorite: TimelineFavoriteMutation?
        var removal: TimelineRemoval?
        let selected = model.flatAssets.filter { requestedIDs.contains($0.id) }
        guard selected.count == requestedIDs.count else { return false }
        var allSucceeded = true
        let result: Void? = await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't update favorites"),
            apply: {
                if leavesCurrentFilter {
                    removal = model.removeAssetsForOptimisticAction(ids: requestedIDs)
                } else {
                    favorite = model.setFavoriteForOptimisticAction(ids: requestedIDs, value: value)
                }
            },
            rollback: {
                if let removal {
                    model.restore(removal)
                } else if let favorite {
                    model.restore(favorite)
                }
            },
            request: {
                var failed: Set<String> = []
                var failure: Error?
                for asset in selected {
                    guard session.client === client else { throw CancellationError() }
                    do {
                        let outcome = try await session.setFavorite(asset, value: value)
                        if outcome.storageFailed {
                            ErrorToastCenter.shared.show(String(localized: "Saved on device. Cloud favorite couldn't be queued."))
                        }
                    } catch { failed.insert(asset.id); failure = error }
                }
                guard session.client === client else { throw CancellationError() }
                if failed.count == requestedIDs.count, let failure { throw failure }
                if !failed.isEmpty {
                    allSucceeded = false
                    if let removal { model.restore(removal, ids: failed) }
                    else if let favorite { model.restore(favorite, ids: failed) }
                    selection = failed
                    ErrorToastCenter.shared.show(String(localized: "Some favorites couldn't be updated. Retry the selected photos."))
                }
            },
            commit: { _ in
                if let removal {
                    model.commit(removal)
                } else if let favorite {
                    model.commit(favorite)
                }
            }
        )
        return result != nil && allSucceeded
    }

    @discardableResult
    private func setVisibility(ids: [String], _ value: AssetVisibility) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "The server is not available."))
            return false
        }
        let errorMessage: String
        switch value {
        case .locked:
            errorMessage = String(localized: "Couldn't move to the locked folder")
        case .archive:
            errorMessage = String(localized: "Couldn't archive")
        case .timeline where filter.visibility == .locked:
            errorMessage = String(localized: "Couldn't remove from the locked folder")
        default:
            errorMessage = String(localized: "Couldn't unarchive")
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: errorMessage,
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.setVisibility(ids: ids, value) },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    /// device first, like deleteAssets: the folder would otherwise keep
    /// showing through the device copy in the merged grid, and a declined
    /// system dialog leaves the server untouched.
    @discardableResult
    private func lockAssets(_ assets: [Asset]) async -> Bool {
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "The server is not available."))
            return false
        }
        let ids = assets.filter { !$0.isLocal }.map(\.id)
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }

        var localIDs = Set<String>()
        for asset in assets where !asset.isLocal {
            if let localID = pairedLocalIdentifier(for: asset) {
                localIDs.insert(localID)
            } else if let backup = session.backup,
                      let localID = await backup.localIdentifier(forRemote: asset.id) {
                localIDs.insert(localID)
            }
        }
        if !localIDs.isEmpty {
            do {
                guard let backup = session.backup else { throw CleanupVerificationError.changed }
                let outcome = try await deviceCopyRemoval.remove(localIDs: localIDs, backup: backup)
                guard outcome.deletedIDs.count == localIDs.count,
                      Set(outcome.deletedIDs) == localIDs, client.context.isActive else {
                    throw CleanupVerificationError.changed
                }
            } catch {
                if !(error is CancellationError) && !PhotoLibraryService.isUserCancelled(error) {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
                }
                return false
            }
            for id in ids { downloadedLocalIdentifiers[id] = nil }
        }

        guard client.context.isActive else { return false }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: localIDs.isEmpty
                ? String(localized: "Couldn't move to the locked folder")
                : String(localized: "Deleted from this device, but couldn't move to the locked folder"),
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.setVisibility(ids: ids, .locked) },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    /// whether locking the selection would also delete device copies.
    private func selectionHasDeviceCopies() -> Bool {
        model.flatAssets.contains { asset in
            !asset.isLocal && selection.contains(asset.id) && pairedLocalIdentifier(for: asset) != nil
        }
    }

    private func backUp(localID: String) async {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show(String(localized: "Backup is not available."))
            return
        }
        do {
            _ = try await backup.backUp(localIdentifier: localID)
            await model.refreshLocalItems()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't back up"), error: error)
        }
    }

    private func download(_ asset: Asset) async {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show(String(localized: "Download is not available."))
            return
        }
        guard downloadingAssetIDs.insert(asset.id).inserted else { return }
        defer { downloadingAssetIDs.remove(asset.id) }
        do {
            downloadedLocalIdentifiers[asset.id] = try await backup.download(asset: asset)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't download"), error: error)
        }
    }

    private func openInBrowser(serverID: String) async {
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "The server is not available."))
            return
        }
        let base = await client.serverWebURL()
        openURL(base.appending(path: "photos/\(serverID)"))
    }

    private func deleteFromDevice(asset: Asset, localID: String) async {
        do {
            guard let backup = session.backup else { throw CleanupVerificationError.changed }
            let outcome = try await deviceCopyRemoval.remove(localIDs: [localID], backup: backup)
            guard outcome.deletedIDs == [localID] else { throw CleanupVerificationError.changed }
        } catch {
            if !(error is CancellationError) && !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
            }
            return
        }
        downloadedLocalIdentifiers[asset.id] = nil
    }

    /// Device deletion happens first so cancelling the system prompt leaves the
    /// server untouched. Once that irreversible step succeeds, the remote
    /// projection disappears immediately and is restored if the server rejects
    /// its half of the operation. not-yet-backed-up device photos have no
    /// server half at all: deleting them only removes them from the library.
    @discardableResult
    private func deleteAssets(_ assets: [Asset], force: Bool) async -> Bool {
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "The server is not available."))
            return false
        }
        let targets = assets.compactMap { asset -> (sourceID: String, serverID: String)? in
            serverIdentifier(for: asset).map { (asset.id, $0) }
        }
        let serverSourceIDs = Set(targets.map(\.sourceID))
        let deviceOnlyIDs = Set(assets.map(\.id)).subtracting(serverSourceIDs)
        let sourceIDs = serverSourceIDs.union(deviceOnlyIDs)
        guard !sourceIDs.isEmpty, beginServerMutation(ids: sourceIDs) else { return false }
        defer { finishServerMutation(ids: sourceIDs) }

        var localIDs = Set<String>()
        for asset in assets {
            if let localID = pairedLocalIdentifier(for: asset) {
                localIDs.insert(localID)
            } else if let serverID = serverIdentifier(for: asset),
                      let backup = session.backup,
                      let localID = await backup.localIdentifier(forRemote: serverID) {
                localIDs.insert(localID)
            }
        }
        if !localIDs.isEmpty {
            do {
                try await PhotoLibraryService.delete(localIdentifiers: Array(localIDs))
            } catch {
                if !PhotoLibraryService.isUserCancelled(error) {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't delete from this device"), error: error)
                }
                return false
            }
            session.backup?.noteLocalDeletion(Array(localIDs))
            for target in targets { downloadedLocalIdentifiers[target.serverID] = nil }
        }

        // the device copies are gone for good at this point, so device-only
        // photos leave the grid immediately and never roll back.
        if !deviceOnlyIDs.isEmpty {
            model.commit(model.removeAssetsForOptimisticAction(ids: deviceOnlyIDs))
        }
        guard !targets.isEmpty else { return true }

        let errorMessage: String
        if localIDs.isEmpty {
            errorMessage = force ? String(localized: "Couldn't delete permanently") : String(localized: "Couldn't move to trash")
        } else if force {
            errorMessage = String(localized: "Deleted from this device, but couldn't permanently delete the server copy")
        } else {
            errorMessage = String(localized: "Deleted from this device, but couldn't move the server copy to trash")
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: errorMessage,
            apply: { removal = model.removeAssetsForOptimisticAction(ids: serverSourceIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: {
                try await client.trashAssets(ids: targets.map(\.serverID), force: force)
            },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    @discardableResult
    private func restore(ids: [String]) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show(String(localized: "The server is not available."))
            return false
        }
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't restore"),
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.restoreAssets(ids: ids) },
            commit: { _ in if let removal { model.commit(removal) } }
        )
        return result != nil
    }

    /// Returns only the ids the server actually removed. Immich can accept a
    /// bulk request while rejecting individual assets for permission reasons.
    private func removeFromAlbum(ids: [String]) async -> Set<String> {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return [] }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client, let albumID = filter.albumId else {
            ErrorToastCenter.shared.show(String(localized: "The album is not available."))
            return []
        }
        var removal: TimelineRemoval?
        let results: [BulkIdResult]? = await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't remove from the album"),
            apply: {
                removal = model.removeAssetsForOptimisticAction(ids: requestedIDs)
                onAlbumAssetCountDelta?(-requestedIDs.count)
            },
            rollback: {
                if let removal { model.restore(removal) }
                onAlbumAssetCountDelta?(requestedIDs.count)
            },
            request: { try await client.removeAssets(albumID: albumID, ids: ids) }
        )
        guard let results else { return [] }

        let succeeded = Set(results.lazy.filter(\.success).map(\.id))
            .intersection(requestedIDs)
        let failed = requestedIDs.subtracting(succeeded)
        if let removal { model.commit(removal, ids: succeeded) }
        if !failed.isEmpty {
            if let removal { model.restore(removal, ids: failed) }
            onAlbumAssetCountDelta?(failed.count)
            ErrorToastCenter.shared.show(albumRemovalFailureMessage(results, failedCount: failed.count))
        }
        return succeeded
    }

    private func beginServerMutation(ids: Set<String>) -> Bool {
        guard !isRunningServerCommand,
              !ids.isEmpty,
              mutatingAssetIDs.isDisjoint(with: ids)
        else { return false }
        mutatingAssetIDs.formUnion(ids)
        return true
    }

    private func finishServerMutation(ids: Set<String>) {
        mutatingAssetIDs.subtract(ids)
    }

    private func albumRemovalFailureMessage(_ results: [BulkIdResult], failedCount: Int) -> String {
        let base = failedCount == 1
            ? String(localized: "Couldn't remove this item from the album.")
            : String(localized: "Couldn't remove \(failedCount) items from the album.")
        guard let reason = results.first(where: { !$0.success })?.error else { return base }
        let readable = reason.replacingOccurrences(of: "_", with: " ")
        return String(localized: "\(base) Server response: \(readable).")
    }

    // MARK: - bulk actions

    private func applyFavorite() async {
        guard await favorite(ids: Array(selection), value: true) else { return }
        exitSelection()
    }

    private func applyVisibility(_ value: AssetVisibility) async {
        guard await setVisibility(ids: Array(selection), value) else { return }
        exitSelection()
    }

    private func applyTrash() async {
        let selected = model.flatAssets.filter { selection.contains($0.id) && isSelectable($0) }
        let force = filter.isTrashed == true || filter.visibility == .locked
        guard await deleteAssets(selected, force: force) else { return }
        exitSelection()
    }

    private func applyLock() async {
        let selected = model.flatAssets.filter { selection.contains($0.id) && !$0.isLocal }
        guard await lockAssets(selected) else { return }
        exitSelection()
    }

    private func applyRestore() async {
        guard await restore(ids: Array(selection)) else { return }
        exitSelection()
    }

    private func applyRemoveFromAlbum() async {
        let removed = await removeFromAlbum(ids: Array(selection))
        selection.subtract(removed)
        if selection.isEmpty { exitSelection() }
    }

    /// the earliest photo in the grid leads the stack, like the web's order.
    private func applyStack() async {
        guard let client = session.client, !selectionHasLocalAssets else { return }
        let indexByID = model.viewerAssetIndexByID
        let ordered = selection.sorted { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
        let requestedIDs = Set(ordered)
        guard beginServerMutation(ids: requestedIDs) else { return }
        defer { finishServerMutation(ids: requestedIDs) }
        do {
            try await client.createStack(assetIDs: ordered)
            exitSelection()
            model.realtimeResync()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't stack the selected photos."), error: error)
        }
    }

    private func applyRemoveFromSpace() async {
        guard await removeFromSpace(ids: Array(selection)) else { return }
        exitSelection()
    }

    /// all or nothing: gallery answers the whole batch with one status.
    private func removeFromSpace(ids: [String]) async -> Bool {
        let requestedIDs = Set(ids)
        guard beginServerMutation(ids: requestedIDs) else { return false }
        defer { finishServerMutation(ids: requestedIDs) }
        guard let client = session.client, let spaceID = filter.spaceId else {
            ErrorToastCenter.shared.show(String(localized: "The space is not available."))
            return false
        }
        var removal: TimelineRemoval?
        let removed: Void? = await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't remove from the space"),
            apply: { removal = model.removeAssetsForOptimisticAction(ids: requestedIDs) },
            rollback: { if let removal { model.restore(removal) } },
            request: { try await client.removeAssets(spaceID: spaceID, ids: ids) }
        )
        guard removed != nil else { return false }
        if let removal { model.commit(removal, ids: requestedIDs) }
        return true
    }

    private func applySetAlbumCover() async {
        guard selection.count == 1, let id = selection.first else { return }
        guard await setAlbumCover(id: id) else { return }
        exitSelection()
    }

    /// the album screen owns the request; the grid only holds the photo
    /// against a second action while it runs.
    private func setAlbumCover(id: String) async -> Bool {
        guard let onSetAlbumCover, beginServerMutation(ids: [id]) else { return false }
        defer { finishServerMutation(ids: [id]) }
        return await onSetAlbumCover(id)
    }

    /// uploads continue after the mode closes so tiles report progress
    /// through their own overlays, like the single-asset menu action.
    private func applyBackup() {
        guard let backup = session.backup else {
            ErrorToastCenter.shared.show(String(localized: "Backup is not available."))
            return
        }
        let localIDs = model.flatAssets
            .filter { selection.contains($0.id) }
            .compactMap(\.localIdentifier)
        guard !localIDs.isEmpty else { return }
        exitSelection()
        Task {
            do {
                let outcome = try await backup.backUp(localIdentifiers: localIDs)
                if outcome.failed > 0 {
                    ErrorToastCenter.shared.show(bulkBackupFailureMessage(outcome))
                }
            } catch {
                ErrorToastCenter.shared.show(String(localized: "Couldn't back up"), error: error)
            }
            // partial uploads may have landed even when the run threw.
            await model.refreshLocalItems()
        }
    }

    private func bulkBackupFailureMessage(_ outcome: BulkBackupOutcome) -> String {
        let base = outcome.failed == 1
            ? String(localized: "Couldn't back up 1 item.")
            : String(localized: "Couldn't back up \(outcome.failed) items.")
        guard let reason = outcome.firstFailure else { return base }
        return "\(base) \(reason)"
    }

    private static func scrubberMonths(spans: [TimelineSectionSpan], side: CGFloat) -> [ScrubberMonth] {
        var y: CGFloat = 0
        return spans.map { span in
            let height = CGFloat(span.titleBands) * 36 + CGFloat(span.tileRows) * (side + 2)
            defer { y += height }
            return ScrubberMonth(
                id: span.id,
                title: span.title,
                year: span.year,
                startY: y,
                height: height
            )
        }
    }
}

/// every input to the month layout, in o(1): the two row tallies move whenever
/// any month's height does, and the ends catch a month appearing or leaving.
/// the layout version catches a rows swap that leaves every tally as it was -
/// a placeholder replaced by exactly the rows it estimated - which still has
/// to re-read the visible rows, since their ids belong to the old rows.
private struct ScrubberLayoutKey: Equatable {
    let layoutVersion: Int
    let titleBands: Int
    let tileRows: Int
    let count: Int
    let first: String?
    let last: String?
    let side: CGFloat

    init(model: TimelineModel, side: CGFloat) {
        layoutVersion = model.rowsLayoutVersion
        titleBands = model.titleBandCount
        tileRows = model.tileRowCount
        count = model.sectionSpans.count
        first = model.sectionSpans.first?.id
        last = model.sectionSpans.last?.id
        self.side = side
    }
}

extension [String]: @retroactive Identifiable {
    public var id: String { joined(separator: ",") }
}

@MainActor
private protocol SelectionAutoScrollerDelegate: AnyObject {
    func selectionAutoScrollerDidScroll(to point: CGPoint, in window: UIWindow)
}

@MainActor
private final class SelectionAutoScroller {
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: SelectionAutoScroller?

        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.advance(displayLink)
        }
    }

    weak var delegate: SelectionAutoScrollerDelegate?
    private weak var scrollView: UIScrollView?
    private weak var window: UIWindow?
    private var location = CGPoint.zero
    private var speed: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let displayLinkTarget = DisplayLinkTarget()

    init(delegate: SelectionAutoScrollerDelegate) {
        self.delegate = delegate
        displayLinkTarget.owner = self
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    func update(location: CGPoint, in window: UIWindow, scrollView: UIScrollView) {
        self.location = location
        self.window = window
        self.scrollView = scrollView
        let frame = scrollView.convert(scrollView.bounds, to: window)
        guard frame.height > 0 else {
            stopDisplayLink()
            return
        }
        speed = SelectionAutoScrollProfile.timeline.speed(
            at: location.y,
            in: frame.minY...frame.maxY
        )
        if speed == 0 {
            stopDisplayLink()
        } else {
            startDisplayLink()
        }
    }

    func stop() {
        speed = 0
        scrollView = nil
        window = nil
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(
            target: displayLinkTarget,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func advance(_ displayLink: CADisplayLink) {
        guard let scrollView, let window, speed != 0 else {
            stop()
            return
        }
        let elapsed = lastTimestamp.map { displayLink.timestamp - $0 }
            ?? displayLink.targetTimestamp - displayLink.timestamp
        lastTimestamp = displayLink.timestamp
        let interval = min(1.0 / 15.0, max(0, elapsed))
        let insets = scrollView.adjustedContentInset
        let minimumY = -insets.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        )
        let currentY = scrollView.contentOffset.y
        let targetY = min(maximumY, max(minimumY, currentY + speed * interval))
        guard abs(targetY - currentY) > 0.01 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetY),
            animated: false
        )
        delegate?.selectionAutoScrollerDidScroll(to: location, in: window)
    }
}

@MainActor
private final class TimelineSelectionSlideController: NSObject,
    UIGestureRecognizerDelegate,
    SelectionAutoScrollerDelegate
{
    private weak var scrollView: UIScrollView?
    private weak var directRecognizer: UIPanGestureRecognizer?
    private weak var heldRecognizer: UILongPressGestureRecognizer?
    private weak var activeRecognizer: UIGestureRecognizer?
    private var isEnabled = false
    private var isActive = false
    private var selectedIDs = Set<String>()
    private var origin: SelectionGridPosition?
    private var target: SelectionGridPosition?
    private var selectionRectangle = SelectionRectangleState()
    private var assetIDsInRectangle: (SelectionGridRectangle) -> Set<String> = { _ in [] }
    private var applyChanges: ([SelectionRectangleState.Change]) -> Void = { _ in }
    private var onActiveChanged: (Bool) -> Void = { _ in }
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private lazy var autoScroller = SelectionAutoScroller(delegate: self)

    func configure(
        isEnabled: Bool,
        selectedIDs: Set<String>,
        assetIDsInRectangle: @escaping (SelectionGridRectangle) -> Set<String>,
        applyChanges: @escaping ([SelectionRectangleState.Change]) -> Void,
        onActiveChanged: @escaping (Bool) -> Void
    ) {
        self.selectedIDs = selectedIDs
        self.assetIDsInRectangle = assetIDsInRectangle
        self.applyChanges = applyChanges
        self.onActiveChanged = onActiveChanged
        self.isEnabled = isEnabled
        if !isEnabled { finishSelection() }
        directRecognizer?.isEnabled = isEnabled
        heldRecognizer?.isEnabled = isEnabled
    }

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        let direct = UIPanGestureRecognizer(target: self, action: #selector(selected(_:)))
        direct.maximumNumberOfTouches = 1
        direct.delegate = self
        direct.isEnabled = isEnabled
        let held = UILongPressGestureRecognizer(target: self, action: #selector(selected(_:)))
        held.minimumPressDuration = 0.3
        held.allowableMovement = 14
        held.numberOfTouchesRequired = 1
        held.delegate = self
        held.isEnabled = isEnabled
        scrollView.addGestureRecognizer(direct)
        scrollView.addGestureRecognizer(held)
        scrollView.panGestureRecognizer.require(toFail: direct)
        self.scrollView = scrollView
        directRecognizer = direct
        heldRecognizer = held
    }

    func detach() {
        finishSelection()
        if let directRecognizer { scrollView?.removeGestureRecognizer(directRecognizer) }
        if let heldRecognizer { scrollView?.removeGestureRecognizer(heldRecognizer) }
        directRecognizer = nil
        heldRecognizer = nil
        scrollView = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              let scrollView,
              let window = scrollView.window
        else { return false }
        let point = originPoint(of: gestureRecognizer, in: window)
        guard tile(at: point, in: scrollView, window: window)?.isSelectable == true else {
            return false
        }
        guard let direct = gestureRecognizer as? UIPanGestureRecognizer else {
            return gestureRecognizer === heldRecognizer
        }
        guard gestureRecognizer === directRecognizer else { return false }
        let translation = direct.translation(in: window)
        return SelectionDirectDragIntent.timeline.matches(
            translation: CGSize(width: translation.x, height: translation.y)
        )
    }

    @objc private func selected(_ recognizer: UIGestureRecognizer) {
        guard let scrollView, let window = scrollView.window else {
            finishSelection()
            return
        }
        let point = recognizer.location(in: window)
        switch recognizer.state {
        case .began:
            beginSelection(recognizer, point: point, scrollView: scrollView, window: window)
        case .changed:
            guard activeRecognizer === recognizer else { return }
            updateRectangle(at: point, in: scrollView, window: window)
            autoScroller.update(location: point, in: window, scrollView: scrollView)
        case .ended, .cancelled, .failed:
            if activeRecognizer === recognizer { finishSelection() }
        default:
            break
        }
    }

    private func beginSelection(
        _ recognizer: UIGestureRecognizer,
        point: CGPoint,
        scrollView: UIScrollView,
        window: UIWindow
    ) {
        guard activeRecognizer == nil else { return }
        guard let tile = tile(
            at: originPoint(of: recognizer, in: window),
            in: scrollView,
            window: window
        ), tile.isSelectable else { return }
        activeRecognizer = recognizer
        origin = tile.selectionPosition
        target = nil
        selectionRectangle.begin(
            originIsSelected: tile.isSelected,
            selectedIDs: selectedIDs
        )
        setActive(true)
        selectionFeedback.prepare()
        updateRectangle(at: point, in: scrollView, window: window)
        autoScroller.update(location: point, in: window, scrollView: scrollView)
    }

    private func finishSelection() {
        autoScroller.stop()
        selectionRectangle.end()
        activeRecognizer = nil
        origin = nil
        target = nil
        setActive(false)
    }

    private func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        onActiveChanged(isActive)
    }

    private func originPoint(
        of recognizer: UIGestureRecognizer,
        in window: UIWindow
    ) -> CGPoint {
        let point = recognizer.location(in: window)
        guard let pan = recognizer as? UIPanGestureRecognizer else { return point }
        let translation = pan.translation(in: window)
        return CGPoint(x: point.x - translation.x, y: point.y - translation.y)
    }

    private func updateRectangle(
        at point: CGPoint,
        in scrollView: UIScrollView,
        window: UIWindow
    ) {
        guard let origin,
              let tile = tile(at: point, in: scrollView, window: window),
              tile.selectionPosition != target
        else { return }
        target = tile.selectionPosition
        let rectangle = SelectionGridRectangle(origin: origin, target: tile.selectionPosition)
        apply(selectionRectangle.update(assetIDs: assetIDsInRectangle(rectangle)))
    }

    private func tile(
        at point: CGPoint,
        in scrollView: UIScrollView,
        window: UIWindow
    ) -> TimelineTileView? {
        let frame = scrollView.convert(scrollView.bounds, to: window)
        guard frame.width > 2, frame.height > 2 else { return nil }
        let clamped = CGPoint(
            x: min(frame.maxX - 1, max(frame.minX + 1, point.x)),
            y: min(frame.maxY - 1, max(frame.minY + 1, point.y))
        )
        var candidate = scrollView.hitTest(scrollView.convert(clamped, from: window), with: nil)
        while let view = candidate {
            if let tile = view as? TimelineTileView { return tile }
            candidate = view.superview
        }
        return nil
    }

    private func apply(_ changes: [SelectionRectangleState.Change]) {
        guard !changes.isEmpty else { return }
        applyChanges(changes)
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }

    func selectionAutoScrollerDidScroll(to point: CGPoint, in window: UIWindow) {
        guard let scrollView else { return }
        updateRectangle(at: point, in: scrollView, window: window)
    }
}

/// scroll indicator drawn by the app, sized and placed exactly like the system/// scroll indicator drawn by the app, sized and placed exactly like the system
/// one, plus the immich-web style marker rail and date pill that appear while
/// it is held.
///
/// the system indicator cannot be used for this: nothing in uikit or swiftui
/// reports when the user grabs it. UIScrollView exposes only its pan and pinch
/// recognizers - the indicator's own recognizer and view are private -
/// UIScrollViewDelegate has no callback for it, and during such a drag only
/// scrollViewDidScroll fires, which is indistinguishable from a programmatic
/// scroll. so the app owns the thumb, and the system's is hidden.
private struct TimelineScrubber: View {
    let scrub: ScrubberState
    let onScrub: (CGFloat) -> Void
    let onScrubbingChanged: (Bool) -> Void

    private var scrubbedMonth: String? {
        guard scrub.scrollRange > 0 else { return nil }
        return scrub.month(atFraction: scrub.fraction)?.title
    }

    var body: some View {
        // only the scrub reads the scroll position here. the thumb follows
        // the offset in uikit, so a plain scroll never re-renders the screen.
        ZStack(alignment: .topTrailing) {
            if scrub.isScrubbing {
                Group {
                    ScrubberMarkerRail(marks: scrub.railMarks())
                        .equatable()
                    if let month = scrubbedMonth {
                        // drawn after the rail in the overlay zstack, so it
                        // passes over the markers while hugging the indicator.
                        ScrubberMonthLabel(title: month)
                            .equatable()
                            .padding(.trailing, 10)
                            .offset(y: scrub.thumbCenterY - 17)
                            .accessibilityIdentifier("timeline-scrubber-label")
                    }
                }
                .transition(.opacity)
                // the drawn parts must never swallow a tap meant for a photo.
                .allowsHitTesting(false)
            }

            TimelineScrollIndicator(
                scrub: scrub,
                onScrub: onScrub,
                onScrubbingChanged: onScrubbingChanged
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}

private struct TimelineScrollIndicator: UIViewRepresentable {
    let scrub: ScrubberState
    let onScrub: (CGFloat) -> Void
    let onScrubbingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> TimelineScrollIndicatorView {
        let view = TimelineScrollIndicatorView(scrub: scrub)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TimelineScrollIndicatorView, context: Context) {
        view.onScrub = onScrub
        view.onScrubbingChanged = onScrubbingChanged
    }
}

/// the thumb and its grab handle. both read the scrub state in uikit's
/// tracked layout pass, so they follow every scroll frame on their own.
private final class TimelineScrollIndicatorView: UIView {
    private let scrub: ScrubberState
    var onScrub: (CGFloat) -> Void = { _ in }
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    private let thumb = UIView()
    private var shows = false
    private var wasScrubbing = false
    private var grabRect = CGRect.zero
    private var isGrabbable = false
    /// where the finger sat inside the thumb when it was grabbed, so the thumb
    /// never jumps under it.
    private var grabOffset: CGFloat = 0
    /// month the thumb last landed in, nil at rest. the haptics hang off it:
    /// nil to a month is the grab, month to month is a boundary crossed.
    private var scrubbedMonthID: String?
    /// a rigid tap rather than a selection tick: the thumb rides the very edge
    /// of the glass under a finger that is already moving, and the softest
    /// tick goes unfelt there. the grab is lighter so the two read apart.
    private let boundaryFeedback = UIImpactFeedbackGenerator(style: .rigid)
    private let grabFeedback = UIImpactFeedbackGenerator(style: .light)

    init(scrub: ScrubberState) {
        self.scrub = scrub
        super.init(frame: .zero)
        backgroundColor = .clear
        thumb.alpha = 0
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        let grab = UILongPressGestureRecognizer(target: self, action: #selector(grabbed(_:)))
        grab.minimumPressDuration = 0
        grab.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(grab)
        accessibilityIdentifier = "timeline-scrubber"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isScrubbing = scrub.isScrubbing
        let visible = scrub.indicatorVisible || isScrubbing
        let thumbHeight = scrub.thumbHeight
        let centerY = scrub.thumbCenterY
        isGrabbable = scrub.indicatorGrabbable || isScrubbing
        // generous next to a 3.5pt thumb, and it only covers the thumb, so an
        // ordinary swipe anywhere else along the edge still scrolls the grid.
        let grabHeight = max(48, thumbHeight + 20)
        grabRect = CGRect(x: bounds.width - 44, y: centerY - grabHeight / 2, width: 44, height: grabHeight)

        // system metrics: a hairline capsule 4.5pt in from the trailing edge,
        // thickening while held.
        let width: CGFloat = isScrubbing ? 6 : 3.5
        let frame = CGRect(
            x: bounds.width - 4.5 - width / 2,
            y: centerY - thumbHeight / 2,
            width: width,
            height: thumbHeight
        )
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if isScrubbing != wasScrubbing {
            wasScrubbing = isScrubbing
            let restyle = {
                self.thumb.frame = frame
                self.thumb.layer.cornerRadius = width / 2
                self.thumb.backgroundColor = UIColor.label.withAlphaComponent(isScrubbing ? 0.5 : 0.35)
            }
            if reduceMotion {
                restyle()
            } else {
                UIView.animate(springDuration: 0.18, bounce: 0.15, animations: restyle)
            }
        } else {
            if thumb.frame != frame { thumb.frame = frame }
            thumb.layer.cornerRadius = width / 2
            if thumb.backgroundColor == nil {
                thumb.backgroundColor = UIColor.label.withAlphaComponent(0.35)
            }
        }
        if visible != shows {
            shows = visible
            let alpha: CGFloat = visible ? 1 : 0
            if reduceMotion {
                thumb.alpha = alpha
            } else {
                UIView.animate(withDuration: visible ? 0.12 : 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    self.thumb.alpha = alpha
                }
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isGrabbable, grabRect.contains(point) else { return nil }
        return self
    }

    @objc private func grabbed(_ recognizer: UILongPressGestureRecognizer) {
        let y = recognizer.location(in: self).y
        switch recognizer.state {
        case .began:
            grabOffset = y - scrub.thumbCenterY
            scrubbedMonthID = scrub.month(atFraction: scrub.fraction)?.id
            grabFeedback.impactOccurred()
            boundaryFeedback.prepare()
            onScrubbingChanged(true)
            drag(to: y)
        case .changed:
            drag(to: y)
        case .ended, .cancelled, .failed:
            scrubbedMonthID = nil
            onScrubbingChanged(false)
        default:
            break
        }
    }

    private func drag(to y: CGFloat) {
        let travel = max(1, scrub.trackHeight - scrub.thumbHeight)
        let centre = y - grabOffset
        let raw = (centre - scrub.thumbHeight / 2 - scrub.trackTop) / travel
        // quantized and deduped so coalesced touch samples collapse to one
        // scroll write per frame.
        let fraction = (min(1, max(0, raw)) * 1_000).rounded() / 1_000
        guard fraction != scrub.scrubFraction else { return }
        scrub.scrubFraction = fraction
        // read off the same mapping the rail and the pill use, so the tick
        // lands on the frame the pill changes word.
        if let month = scrub.month(atFraction: fraction)?.id, month != scrubbedMonthID {
            if scrubbedMonthID != nil {
                boundaryFeedback.impactOccurred(intensity: 0.8)
                boundaryFeedback.prepare()
            }
            scrubbedMonthID = month
        }
        onScrub(fraction)
    }
}

/// one rail entry: a year chip, a month dot, or both.
private struct ScrubberRailMark: Identifiable, Equatable {
    let id: String
    let y: CGFloat
    let year: String?
    let hasDot: Bool
}

/// year labels at year boundaries and dots for months, spaced with the
/// minimum-distance rules immich-web uses and placed with the same mapping
/// the indicator thumb sweeps.
///
/// equatable, and given already-computed marks: the thumb it hangs beside
/// re-renders on every frame of a drag, and rebuilding a rail of glass chips
/// alongside it is what made a scrub crawl on a large library.
private struct ScrubberMarkerRail: View, Equatable {
    let marks: [ScrubberRailMark]

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .topTrailing) {
                ForEach(marks) { mark in
                    if let year = mark.year {
                        Text(year)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .frame(height: 18)
                            .padding(.trailing, 12)
                            .offset(y: mark.y - 9)
                    }
                    if mark.hasDot {
                        // centred on the indicator's own line, measured at
                        // 4.5pt in from the trailing edge. the overlay cannot
                        // draw under a uikit indicator, so sharing the column
                        // is as layered as the two can get.
                        Circle()
                            .fill(Color(.label))
                            .frame(width: 4, height: 4)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .padding(.trailing, 2.5)
                            .offset(y: mark.y - 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// floating month pill riding the indicator thumb, naming whatever month
/// sits at the viewport top. equatable on its title alone: it rides along on
/// every frame of a drag but only ever reads differently at a month boundary,
/// and re-blurring glass sixty times a second for the same word is not free.
private struct ScrubberMonthLabel: View, Equatable {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .frame(height: 34)
    }
}
