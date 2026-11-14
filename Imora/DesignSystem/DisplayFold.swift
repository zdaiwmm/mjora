import SwiftUI

/// the crease of a foldable display. it stays inactive while the display
/// lies flat, so a layout can keep its split and only steer controls away
/// once the device is partly folded.
nonisolated struct DisplayFold: Equatable, Sendable {
    let frame: CGRect
    let margins: EdgeInsets
    let isActive: Bool

    /// a fold taller than wide is a book crease, splitting leading from
    /// trailing. a wide one is a tabletop crease, splitting top from bottom.
    var splitsHorizontally: Bool { frame.height >= frame.width }

    /// what a view has to keep clear of: the crease and its margins.
    var avoidedFrame: CGRect {
        CGRect(
            x: frame.minX - margins.leading,
            y: frame.minY - margins.top,
            width: frame.width + margins.leading + margins.trailing,
            height: frame.height + margins.top + margins.bottom
        )
    }
}

/// how open the hinge of a foldable iphone is.
enum DevicePose: Equatable, Sendable {
    case closed
    case partiallyOpen
    case fullyOpen
}

extension GeometryProxy {
    /// the fold of the display this view is on in global coordinates, nil
    /// on displays that do not fold. it is not narrowed to the view's bounds:
    /// a view that just moved off the crease still has to know where it is.
    nonisolated var displayFold: DisplayFold? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = reservedRegions(kind: .division, options: .includeInactive)
        guard let region = regions.first(where: \.isActive) ?? regions.first else {
            return nil
        }
        let origin = frame(in: .global).origin
        return DisplayFold(
            frame: region.frame.offsetBy(dx: origin.x, dy: origin.y),
            margins: region.margins,
            isActive: region.isActive
        )
    }
}

extension View {
    /// reports the fold of this view's display whenever it moves or changes.
    func onDisplayFoldChange(
        perform action: @escaping (DisplayFold?) -> Void
    ) -> some View {
        onGeometryChange(for: DisplayFold?.self) { proxy in
            proxy.displayFold
        } action: { fold in
            action(fold)
        }
    }

    /// reports discrete hinge changes only, never the angle while it moves.
    @ViewBuilder
    func onDevicePoseChange(
        perform action: @escaping (DevicePose) -> Void
    ) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { old, new in
                guard let pose = DevicePose(new.hinge?.status),
                      pose != DevicePose(old.hinge?.status)
                else { return }
                action(pose)
            }
        }
        else {
            self
        }
    }

    /// slides the view sideways off an active fold when it fits on one side,
    /// so a centered banner or bar is never bent in half by the crease.
    /// toolbar items never see the fold themselves, so a screen that knows
    /// it can hand it over in global coordinates.
    func avoidsActiveFold(_ globalFold: DisplayFold? = nil) -> some View {
        modifier(FoldAvoidingModifier(globalFold: globalFold))
    }
}

@available(iOS 27.1, *)
private extension DevicePose {
    init?(_ status: DeviceHinge.Status?) {
        switch status {
            case .closed?: self = .closed
            case .partiallyOpen?: self = .partiallyOpen
            case .fullyOpen?: self = .fullyOpen
            default: return nil
        }
    }
}

private struct FoldAvoidingModifier: ViewModifier {
    let globalFold: DisplayFold?

    @State private var offset: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(offset)
            // an offset only moves what it draws, never its own frame, so
            // measuring outside it never sees the move and cannot bounce.
            .onGeometryChange(for: CGSize.self) { proxy in
                Self.offset(
                    frame: proxy.frame(in: .global),
                    fold: proxy.displayFold ?? globalFold
                )
            } action: { newOffset in
                withAnimation(.smooth(duration: 0.3)) { offset = newOffset }
            }
    }

    /// the crease sits in the middle of the display, so the space before it
    /// is also the space after it: a view larger than that stays put.
    nonisolated private static func offset(frame: CGRect, fold: DisplayFold?) -> CGSize {
        guard let fold, fold.isActive else { return .zero }
        let crease = fold.avoidedFrame
        guard frame.intersects(crease) else { return .zero }

        if fold.splitsHorizontally {
            guard frame.width <= crease.minX else { return .zero }
            let towardLeading = crease.minX - frame.maxX
            let towardTrailing = crease.maxX - frame.minX
            return CGSize(width: shorter(towardLeading, towardTrailing), height: 0)
        }
        else {
            guard frame.height <= crease.minY else { return .zero }
            let towardTop = crease.minY - frame.maxY
            let towardBottom = crease.maxY - frame.minY
            return CGSize(width: 0, height: shorter(towardTop, towardBottom))
        }
    }

    nonisolated private static func shorter(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        abs(a) <= abs(b) ? a : b
    }
}
