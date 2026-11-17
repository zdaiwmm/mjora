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
        let value = min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), CGFloat(base) / magnification))
        return Int(value.rounded())
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

    static func interpolate(_ from: CGRect, _ to: CGRect, progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress))
        return CGRect(x: from.minX + (to.minX - from.minX) * t,
                      y: from.minY + (to.minY - from.minY) * t,
                      width: from.width + (to.width - from.width) * t,
                      height: from.height + (to.height - from.height) * t)
    }
}

/// Only the mounted thumbnails participate. Replicas share their UIImage
/// storage; no snapshot bitmap, network request or row rebuild is made on a
/// pinch frame. UIKit animates the same photo across changing row parents.
@MainActor
final class TimelineGridZoomTransition {
    struct CapturedTile {
        let id: String
        /// Frame in the scroll view's visible coordinate space.
        let frame: CGRect
        let makeReplica: () -> UIView
    }
    private struct Tile {
        let id: String
        let initialFrame: CGRect
        let view: UIView
    }

    private struct Anchor {
        let id: String
        var unitX: CGFloat
        var unitY: CGFloat
        var viewportPoint: CGPoint
    }

    private var tiles: [Tile] = []
    private var overlay: UIView?
    private var anchor: Anchor?
    private var origin = CGPoint.zero
    private var anchorOrigin = CGPoint.zero
    private var animator: UIViewPropertyAnimator?
    private var reduceMotion = false
    private var displayScale: CGFloat = 1
    private var sourceSide: CGFloat = 1
    private(set) var isTracking = false
    var isPrepared: Bool { anchor != nil }

    func begin(in grid: UIScrollView, tiles source: [TimelineTileView],
               midpoint: CGPoint, reduceMotion: Bool) {
        guard let parent = grid.superview else { cancel(); return }
        let captured = source.compactMap { tile -> CapturedTile? in
            guard let asset = tile.asset, !tile.isProjectedRemoved else { return nil }
            let frame = tile.convert(tile.bounds, to: parent)
                .offsetBy(dx: -grid.frame.minX, dy: -grid.frame.minY)
            return CapturedTile(id: asset.id, frame: frame, makeReplica: { tile.makeZoomReplica() })
        }
        begin(in: grid, captured: captured, midpoint: midpoint, reduceMotion: reduceMotion)
    }

    func begin(in grid: UIScrollView, captured source: [CapturedTile],
               midpoint: CGPoint, reduceMotion: Bool) {
        cancel()
        guard let parent = grid.superview else { return }
        self.reduceMotion = reduceMotion
        displayScale = 1
        let point = grid.convert(midpoint, to: parent)
        let viewportPoint = CGPoint(x: point.x - grid.frame.minX, y: point.y - grid.frame.minY)
        origin = viewportPoint
        let canvas = UIView(frame: grid.frame)
        canvas.clipsToBounds = true
        canvas.isUserInteractionEnabled = false
        canvas.accessibilityElementsHidden = true
        canvas.backgroundColor = .systemBackground
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for tile in source {
            let visibleFrame = tile.frame
            guard visibleFrame.intersects(canvas.bounds.insetBy(dx: -160, dy: -200)) else { continue }
            let distance = hypot(visibleFrame.midX - viewportPoint.x, visibleFrame.midY - viewportPoint.y)
            if distance < nearestDistance {
                nearestDistance = distance
                let point = TimelineGridZoomGeometry.anchor(frame: visibleFrame, midpoint: viewportPoint)
                anchor = Anchor(id: tile.id,
                    unitX: min(1, max(0, (point.point.x - visibleFrame.minX) / max(visibleFrame.width, 1))),
                    unitY: point.unitY, viewportPoint: point.point)
            }
            if !reduceMotion {
                sourceSide = visibleFrame.width
                let replica = tile.makeReplica()
                replica.frame = visibleFrame
                canvas.addSubview(replica)
                tiles.append(Tile(id: tile.id, initialFrame: visibleFrame, view: replica))
            }
        }
        guard anchor != nil else { return }
        anchorOrigin = anchor?.viewportPoint ?? viewportPoint
        isTracking = true
        if !reduceMotion {
            parent.addSubview(canvas)
            overlay = canvas
        }
    }

    func update(scale: CGFloat, midpoint: CGPoint, in grid: UIScrollView,
                from lowerFrames: [String: CGRect] = [:], to upperFrames: [String: CGRect] = [:],
                progress: CGFloat = 0) {
        guard isTracking, scale.isFinite, scale > 0, let parent = grid.superview else { return }
        displayScale = scale
        let point = grid.convert(midpoint, to: parent)
        let destination = CGPoint(x: point.x - grid.frame.minX, y: point.y - grid.frame.minY)
        // A scale-only gesture keeps the anchor where it began. Midpoint
        // translation lets the photo follow both fingers without drifting.
        anchor?.viewportPoint = CGPoint(x: destination.x + (anchorOrigin.x - origin.x) * scale,
                                       y: destination.y + (anchorOrigin.y - origin.y) * scale)
        let lowerOffset = anchor.flatMap { anchor in
            lowerFrames[anchor.id].map {
                CGPoint(x: $0.minX + $0.width * anchor.unitX - anchor.viewportPoint.x,
                        y: $0.minY + $0.height * anchor.unitY - anchor.viewportPoint.y)
            }
        }
        let upperOffset = anchor.flatMap { anchor in
            upperFrames[anchor.id].map {
                CGPoint(x: $0.minX + $0.width * anchor.unitX - anchor.viewportPoint.x,
                        y: $0.minY + $0.height * anchor.unitY - anchor.viewportPoint.y)
            }
        }
        // Store translation relative to the original anchor, not cumulatively.
        for tile in tiles {
            if let lower = lowerFrames[tile.id], let upper = upperFrames[tile.id],
               let lowerOffset, let upperOffset {
                tile.view.frame = TimelineGridZoomGeometry.interpolate(
                    lower.offsetBy(dx: -lowerOffset.x, dy: -lowerOffset.y),
                    upper.offsetBy(dx: -upperOffset.x, dy: -upperOffset.y), progress: progress)
            } else {
                tile.view.frame = TimelineGridZoomGeometry.scaled(tile.initialFrame, by: scale, around: origin, to: destination)
            }
        }
    }

    func finish(in grid: UIScrollView, frames: [String: CGRect],
                scroll: (CGFloat) -> Void, destinations: () -> [TimelineTileView],
                completion: @escaping () -> Void) {
        isTracking = false
        guard let anchor else { cancel(); completion(); return }
        if let frame = frames[anchor.id] {
            let end = grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.top + grid.adjustedContentInset.bottom
            scroll(TimelineGridZoomGeometry.offset(frame: frame, unitY: anchor.unitY,
                   viewportY: anchor.viewportPoint.y, topInset: grid.adjustedContentInset.top, endOffset: end))
        }
        guard let overlay, !reduceMotion else { cancel(); completion(); return }
        let targets = frames.mapValues { $0.offsetBy(dx: -grid.contentOffset.x, dy: -grid.contentOffset.y) }
        let captured = Set(tiles.map(\.id))
        // Zooming out exposes photos that were outside the old viewport.
        // Bring these in alongside their neighbours instead of leaving holes
        // in the overlay until the final crossfade.
        for tile in destinations() {
            guard let id = tile.asset?.id, !captured.contains(id),
                  let target = targets[id], target.intersects(overlay.bounds)
            else { continue }
            let replica = tile.makeZoomReplica()
            replica.frame = TimelineGridZoomGeometry.scaled(target, by: sourceSide * displayScale / max(target.width, 1),
                around: anchor.viewportPoint, to: anchor.viewportPoint)
            replica.alpha = 0
            overlay.addSubview(replica)
            tiles.append(Tile(id: id, initialFrame: replica.frame, view: replica))
        }
        // The real destination grid is already laid out under the replicas.
        // Crossfade after most of the travel so the final handoff stays continuous.
        let animator = PhotosMotion.springAnimator(duration: PhotosMotion.layoutDuration) { [tiles] in
            for tile in tiles {
                if let target = targets[tile.id] { tile.view.frame = target }
                else { tile.view.alpha = 0 }
                if targets[tile.id] != nil { tile.view.alpha = 1 }
            }
        }
        animator.addAnimations({ overlay.alpha = 0 }, delayFactor: 0.65)
        animator.addCompletion { [weak self, weak overlay] _ in
            overlay?.removeFromSuperview()
            guard self?.overlay === overlay else { return }
            self?.overlay = nil
            self?.anchor = nil
            self?.tiles = []
            self?.animator = nil
            completion()
        }
        self.animator = animator
        animator.startAnimation()
    }

    func cancel() {
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        overlay = nil
        tiles = []
        anchor = nil
        isTracking = false
    }
}
