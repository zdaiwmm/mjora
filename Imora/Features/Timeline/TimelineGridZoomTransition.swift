import UIKit

/// The geometry is independent of row grouping. An anchor is a point inside
/// one photo, rather than a percentage of a potentially very long library.
nonisolated enum TimelineGridZoomGeometry {
    static func anchor(frame: CGRect, midpoint: CGPoint) -> (unitY: CGFloat, point: CGPoint) {
        let point = frame.contains(midpoint) ? midpoint : CGPoint(x: frame.midX, y: frame.midY)
        return (min(1, max(0, (point.y - frame.minY) / max(frame.height, 1))), point)
    }
    static func columns(base: Int, magnification: CGFloat, width: CGFloat) -> Int {
        let range = AssetGridLayout.columnRange(viewportWidth: width)
        guard magnification.isFinite, magnification > 0 else {
            return min(range.upperBound, max(range.lowerBound, base))
        }
        let value = continuousColumns(base: base, magnification: magnification, width: width)
        return Int(value.rounded())
    }

    static func continuousColumns(base: Int, magnification: CGFloat, width: CGFloat) -> CGFloat {
        let range = AssetGridLayout.columnRange(viewportWidth: width)
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: base) * magnification
        let value = (width + AssetGridLayout.gutter) / max(AssetGridLayout.gutter, side + AssetGridLayout.gutter)
        return min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), value))
    }

    static func offset(frame: CGRect, unitY: CGFloat, viewportY: CGFloat,
                       topInset: CGFloat, endOffset: CGFloat) -> CGFloat {
        min(max(0, frame.minY + frame.height * unitY - viewportY + topInset), max(0, endOffset))
    }

    static func scaled(_ frame: CGRect, by scale: CGFloat, around origin: CGPoint, to midpoint: CGPoint) -> CGRect {
        CGRect(x: midpoint.x + (frame.minX - origin.x) * scale,
               y: midpoint.y + (frame.minY - origin.y) * scale,
               width: frame.width * scale, height: frame.height * scale)
    }

    struct Segment {
        let sourceColumns: Int
        let destinationColumns: Int
        let side: CGFloat
        let progress: CGFloat
    }

    static func segment(density: CGFloat, base: Int, width: CGFloat) -> Segment {
        let integer = density.rounded()
        if abs(density - integer) < 0.000_001 {
            let columns = Int(integer)
            return .init(sourceColumns: columns, destinationColumns: columns,
                         side: AssetGridLayout.tileSide(viewportWidth: width, columns: columns), progress: 0)
        }
        let lower = Int(density.rounded(.down)), upper = Int(density.rounded(.up))
        let source = density > CGFloat(base) ? lower : upper
        let destination = source == lower ? upper : lower
        let firstSide = AssetGridLayout.tileSide(viewportWidth: width, columns: source)
        let lastSide = AssetGridLayout.tileSide(viewportWidth: width, columns: destination)
        let side = (width + AssetGridLayout.gutter) / density - AssetGridLayout.gutter
        let progress = firstSide == lastSide ? 0 : min(1, max(0, (side - firstSide) / (lastSide - firstSide)))
        return .init(sourceColumns: source, destinationColumns: destination, side: side, progress: progress)
    }

    static func fade(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        let t = min(1, max(0, (progress - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    static func viewportCoverage(at progress: CGFloat) -> CGFloat {
        let edge = min(progress, 1 - progress)
        return 1 - fade(edge, from: 0, to: 0.16)
    }
}

/// The mounted and projected windows supply two grids of fixed slots.
/// Pinching transforms an entire grid while the next grid fades in underneath.
@MainActor
final class TimelineGridZoomTransition {
    struct CapturedTile {
        let id: String
        let frame: CGRect
        let makeReplica: () -> UIView
    }

    struct Layout {
        let tiles: [String: CapturedTile]
        let verticalOffsets: ClosedRange<CGFloat>
    }

    typealias Projection = (_ anchorID: String, _ unitY: CGFloat, _ columns: Int) -> Layout?

    private struct Anchor {
        let gestureID = UUID()
        let id: String
        let unit: CGPoint
        let initialY: CGFloat
        var viewportY: CGFloat
    }

    private final class Plane {
        let view = UIView()
        let layout: Layout
        var replicas: [String: UIView] = [:]
        var drawn: Set<String> = []

        init(layout: Layout) {
            self.layout = layout
            view.layer.anchorPoint = .zero
            view.layer.position = .zero
        }
    }

    private var overlay: UIView?
    private var viewportCover: UIView?
    private var showsViewportBehind = true
    private var anchor: Anchor?
    private var initialMidpointY: CGFloat = 0
    private var initialOffsetX: CGFloat = 0
    private var committedOriginX: CGFloat = 0
    private var baseColumns = 3
    private var width: CGFloat = 0
    private var projection: Projection?
    private var layouts: [Int: Layout] = [:]
    private var planes: [Int: Plane] = [:]
    private var animator: UIViewPropertyAnimator?
    private(set) var isTracking = false
    var isPrepared: Bool { anchor != nil }
    var anchorAssetID: String? { anchor?.id }

    func targetOffset(in grid: UIScrollView, frames: [String: CGRect], contentHeight: CGFloat? = nil) -> CGFloat? {
        guard let anchor, let frame = frames[anchor.id] else { return nil }
        let end = (contentHeight ?? grid.contentSize.height) - grid.bounds.height
            + grid.adjustedContentInset.top + grid.adjustedContentInset.bottom
        return TimelineGridZoomGeometry.offset(frame: frame, unitY: anchor.unit.y,
            viewportY: anchor.viewportY, topInset: grid.adjustedContentInset.top, endOffset: end)
    }

    func begin(in grid: UIScrollView, captured source: [CapturedTile],
               midpoint: CGPoint, reduceMotion: Bool, baseColumns: Int = 3,
               width: CGFloat? = nil, showsViewportBehind: Bool = true, projection: Projection? = nil) {
        cancel()
        let width = width ?? grid.bounds.width
        guard let parent = grid.superview, width.isFinite, width > 0 else { return }
        let point = viewportPoint(midpoint, in: grid, parent: parent)
        let viewport = CGRect(origin: .zero, size: grid.bounds.size)
        let visible = source.filter { $0.frame.intersects(viewport) }
        guard let hit = visible.first(where: { $0.frame.contains(point) }) ?? visible.min(by: {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y)
                < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }) else { return }
        let pin = TimelineGridZoomGeometry.anchor(frame: hit.frame, midpoint: point)
        let unit = CGPoint(x: (pin.point.x - hit.frame.minX) / max(1, hit.frame.width), y: pin.unitY)
        anchor = Anchor(id: hit.id, unit: unit, initialY: pin.point.y, viewportY: pin.point.y)
        initialMidpointY = point.y
        initialOffsetX = grid.contentOffset.x
        committedOriginX = grid.adjustedContentInset.left
        self.baseColumns = baseColumns
        self.width = width
        self.showsViewportBehind = showsViewportBehind
        self.projection = projection
        isTracking = true
        #if DEBUG || PHASE4_PERFORMANCE
        GalleryFrameMetrics.shared.begin("gallery-pinch-reflow")
        #endif
        guard !reduceMotion else { return }

        let projected = projection?(hit.id, unit.y, baseColumns)
        var tiles = projected?.tiles ?? [:]
        for tile in source {
            tiles[tile.id] = .init(id: tile.id,
                frame: tile.frame.offsetBy(dx: grid.contentOffset.x, dy: grid.contentOffset.y),
                makeReplica: tile.makeReplica)
        }
        let start = -grid.adjustedContentInset.top
        let end = grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.bottom
        layouts[baseColumns] = Layout(tiles: tiles, verticalOffsets:
            min(start, grid.contentOffset.y)...max(start, end, grid.contentOffset.y))
        let canvas = UIView(frame: grid.frame)
        canvas.clipsToBounds = true
        canvas.isUserInteractionEnabled = false
        canvas.accessibilityElementsHidden = true
        let cover = UIView(frame: canvas.bounds)
        cover.backgroundColor = .systemBackground
        canvas.addSubview(cover)
        parent.addSubview(canvas)
        overlay = canvas
        viewportCover = cover
        render(scale: 1)
    }

    func update(scale: CGFloat, midpoint: CGPoint, in grid: UIScrollView) {
        guard isTracking, scale.isFinite, scale > 0, let parent = grid.superview else { return }
        let point = viewportPoint(midpoint, in: grid, parent: parent)
        if let initialY = anchor?.initialY {
            anchor?.viewportY = point.y + initialY - initialMidpointY
        }
        render(scale: scale)
    }

    private func viewportPoint(_ point: CGPoint, in grid: UIScrollView, parent: UIView) -> CGPoint {
        let converted = grid.convert(point, to: parent)
        return CGPoint(x: converted.x - grid.frame.minX, y: converted.y - grid.frame.minY)
    }

    private func layout(columns: Int, anchor: Anchor) -> Layout? {
        if let cached = layouts[columns] { return cached }
        guard let value = projection?(anchor.id, anchor.unit.y, columns), value.tiles[anchor.id] != nil else { return nil }
        layouts[columns] = value
        return value
    }

    private func transform(for layout: Layout, columns: Int, scale: CGFloat, anchor: Anchor) -> CGAffineTransform {
        guard let frame = layout.tiles[anchor.id]?.frame else { return .identity }
        let anchorY = frame.minY + frame.height * anchor.unit.y
        let scrollY = anchorY - anchor.viewportY
        let x = columns == baseColumns ? -initialOffsetX : committedOriginX
        let y = -min(layout.verticalOffsets.upperBound, max(layout.verticalOffsets.lowerBound, scrollY))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: x + (frame.minX + frame.width * anchor.unit.x) * (1 - scale),
            ty: y + anchorY * (1 - scale))
    }

    private func plane(columns: Int, layout: Layout, in canvas: UIView) -> Plane {
        if let cached = planes[columns] { return cached }
        let plane = Plane(layout: layout)
        plane.view.bounds = canvas.bounds
        canvas.addSubview(plane.view)
        planes[columns] = plane
        return plane
    }

    private func draw(_ plane: Plane, transform: CGAffineTransform, visible: CGRect,
                      opacity: (CapturedTile) -> CGFloat) {
        plane.view.transform = transform
        let localViewport = visible.applying(transform.inverted())
        var next: Set<String> = []
        for tile in plane.layout.tiles.values where tile.frame.intersects(localViewport) {
            let alpha = opacity(tile)
            guard alpha > 0 else { continue }
            let replica: UIView
            if let cached = plane.replicas[tile.id] {
                replica = cached
            } else {
                replica = tile.makeReplica()
                guard replica.superview == nil else { continue }
                replica.frame = tile.frame
                plane.view.addSubview(replica)
                plane.replicas[tile.id] = replica
            }
            if replica.alpha != alpha { replica.alpha = alpha }
            next.insert(tile.id)
        }
        for id in plane.drawn.subtracting(next) { plane.replicas[id]?.alpha = 0 }
        plane.drawn = next
    }

    private func render(scale: CGFloat) {
        guard let canvas = overlay, let anchor else { return }
        let density = TimelineGridZoomGeometry.continuousColumns(base: baseColumns, magnification: scale, width: width)
        let segment = TimelineGridZoomGeometry.segment(density: density, base: baseColumns, width: width)
        let projectedSource = layout(columns: segment.sourceColumns, anchor: anchor)
        let sourceColumns = projectedSource == nil ? baseColumns : segment.sourceColumns
        guard let sourceLayout = projectedSource ?? layouts[baseColumns] else { return }
        let destinationLayout = sourceColumns == segment.sourceColumns && sourceColumns != segment.destinationColumns
            ? layout(columns: segment.destinationColumns, anchor: anchor) : nil
        let visible = canvas.bounds.insetBy(dx: -24, dy: -24)
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: sourceColumns)
        guard side > 0 else { return }
        let sourceTransform = transform(for: sourceLayout, columns: sourceColumns,
                                        scale: segment.side / side, anchor: anchor)
        let progress = destinationLayout == nil ? 0 : segment.progress
        let sharedFade = TimelineGridZoomGeometry.fade(progress, from: 0.55, to: 1)
        var destinationCount = 0
        viewportCover?.alpha = showsViewportBehind ? TimelineGridZoomGeometry.viewportCoverage(at: progress) : 1

        if let destinationLayout {
            let destinationColumns = segment.destinationColumns
            for columns in Array(planes.keys) where columns != sourceColumns && columns != destinationColumns {
                planes.removeValue(forKey: columns)?.view.removeFromSuperview()
            }
            let destination = plane(columns: destinationColumns, layout: destinationLayout, in: canvas)
            let destinationTransform = transform(for: destinationLayout, columns: destinationColumns, scale: 1, anchor: anchor)
            let edgeFade = TimelineGridZoomGeometry.fade(progress, from: 0, to: 0.28)
            let sourceRoster = canvas.bounds.applying(
                transform(for: sourceLayout, columns: sourceColumns, scale: 1, anchor: anchor).inverted())
            destination.view.isHidden = false
            destination.view.alpha = 1
            draw(destination, transform: destinationTransform, visible: visible) { tile in
                guard let sourceFrame = sourceLayout.tiles[tile.id]?.frame else { return edgeFade }
                let overlap = sourceFrame.intersection(sourceRoster)
                let depth = overlap.isNull ? 0 : min(overlap.width, overlap.height)
                let shared = TimelineGridZoomGeometry.fade(depth, from: 0, to: min(24, side * 0.5))
                return edgeFade + (sharedFade - edgeFade) * shared
            }
            destinationCount = destination.drawn.count
        } else {
            // Keep the other plane cached at an exact endpoint for a reversal.
            for (columns, plane) in planes where columns != sourceColumns { plane.view.isHidden = true }
            if planes[sourceColumns] == nil && planes.count == 2 {
                for columns in Array(planes.keys) { planes.removeValue(forKey: columns)?.view.removeFromSuperview() }
            }
        }
        let source = plane(columns: sourceColumns, layout: sourceLayout, in: canvas)
        source.view.isHidden = false
        source.view.alpha = 1 - sharedFade
        if canvas.subviews.last !== source.view { canvas.bringSubviewToFront(source.view) }
        draw(source, transform: sourceTransform, visible: visible) { _ in 1 }
        #if DEBUG || PHASE4_PERFORMANCE
        GalleryFrameMetrics.shared.mark("gallery-pinch-held", values: [
            "density": Double(density), "progress": Double(progress),
            "visibleReplicas": Double(source.drawn.count + destinationCount),
            "coverOpacity": Double(viewportCover?.alpha ?? 1)
        ])
        #endif
    }

    func finish(in grid: UIScrollView, frames: [String: CGRect], contentHeight: CGFloat? = nil,
                scroll: (CGFloat) -> Void,
                finalTiles: () -> [CapturedTile] = { [] },
                completion: @escaping () -> Void) {
        guard let anchor else { cancel(); completion(); return }
        guard isTracking else { return }
        isTracking = false
        #if DEBUG || PHASE4_PERFORMANCE
        GalleryFrameMetrics.shared.mark("gallery-pinch-release")
        #endif
        let canvas = overlay
        if showsViewportBehind, let canvas, let cover = viewportCover, cover.alpha < 1 {
            // Freeze only the backing pixels that were visible while held, before the reflow mutates the grid.
            if let snapshot = grid.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = canvas.bounds
                canvas.insertSubview(snapshot, belowSubview: cover)
            }
        }
        if let offset = targetOffset(in: grid, frames: frames, contentHeight: contentHeight) { scroll(offset) }
        guard self.anchor?.gestureID == anchor.gestureID else { return }
        guard let canvas else { cancel(); completion(); return }

        // Keep the held geometry frozen until the committed grid is in its own slots.
        let captured = finalTiles()
        let expected = frames[anchor.id]?.offsetBy(dx: -grid.contentOffset.x, dy: -grid.contentOffset.y)
        if let expected, expected.intersects(canvas.bounds), !captured.contains(where: {
            $0.id == anchor.id && abs($0.frame.minX - expected.minX) < 1
                && abs($0.frame.minY - expected.minY) < 1
                && abs($0.frame.width - expected.width) < 1 && abs($0.frame.height - expected.height) < 1
        }) {
            DispatchQueue.main.async { [weak self, weak grid, weak canvas] in
                guard let self, let canvas, self.overlay === canvas else { return }
                grid?.layoutIfNeeded()
                self.reveal(canvas, completion: completion)
            }
        } else {
            reveal(canvas, completion: completion)
        }
    }

    private func reveal(_ canvas: UIView, completion: @escaping () -> Void) {
        guard overlay === canvas else { return }
        let animator = UIViewPropertyAnimator(duration: PhotosMotion.chromeDuration, curve: .easeOut) {
            canvas.alpha = 0
        }
        animator.addCompletion { [weak self, weak canvas] _ in
            guard let self, let canvas, self.overlay === canvas else { return }
            self.animator = nil
            self.cancel()
            completion()
        }
        self.animator = animator
        animator.startAnimation()
    }

    func cancel() {
        #if DEBUG || PHASE4_PERFORMANCE
        if anchor != nil { GalleryFrameMetrics.shared.end("gallery-pinch-reflow") }
        #endif
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        overlay = nil
        viewportCover = nil
        anchor = nil
        projection = nil
        layouts.removeAll()
        planes.removeAll()
        isTracking = false
    }
}
