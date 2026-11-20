import CoreGraphics

/// Width-aware sizing rules shared by timeline grids and their zoom gesture.
nonisolated enum AssetGridLayout {
    static let gutter: CGFloat = 2

    private static let preferredTileSide: CGFloat = 150
    private static let minimumDefaultColumns = 3
    private static let maximumDefaultColumns = 24
    private static let minimumPinchColumns = 2

    /// Keeps thumbnails near a useful viewing size as the app window grows.
    static func defaultColumnCount(viewportWidth: CGFloat) -> Int {
        guard viewportWidth.isFinite, viewportWidth > 0 else {
            return minimumDefaultColumns
        }

        let estimatedColumns = min(
            (viewportWidth / preferredTileSide).rounded(),
            CGFloat(maximumDefaultColumns)
        )
        return max(minimumDefaultColumns, Int(estimatedColumns))
    }

    /// Leaves two zoom-out steps beyond the adaptive default while retaining
    /// the familiar two-to-five-column range on compact phones.
    static func columnRange(viewportWidth: CGFloat) -> ClosedRange<Int> {
        let upperBound = max(5, defaultColumnCount(viewportWidth: viewportWidth) + 2)
        return minimumPinchColumns...upperBound
    }

    static func tileSide(viewportWidth: CGFloat, columns: Int) -> CGFloat {
        guard viewportWidth.isFinite, viewportWidth > 0, columns > 0 else { return 0 }
        let totalGutterWidth = CGFloat(columns - 1) * gutter
        return max(0, (viewportWidth - totalGutterWidth) / CGFloat(columns))
    }
}

nonisolated struct TimelinePinchSettle {
    private static let disarmingRetreatRatio: CGFloat = 1.10
    private static let neutralCrossingRatio: CGFloat = 1.05

    private var farthestScale: CGFloat = 1
    private var armedScale: CGFloat?

    var releaseScale: CGFloat { armedScale ?? 1 }

    mutating func update(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }

        let expandingReach = farthestScale > 1
        let reachesFarther = expandingReach ? scale > farthestScale : scale < farthestScale
        let crossesNeutral = expandingReach
            ? scale <= 1 / Self.neutralCrossingRatio
            : scale >= Self.neutralCrossingRatio

        if farthestScale == 1 || reachesFarther || crossesNeutral {
            farthestScale = scale
            armedScale = scale
        } else if armedScale != nil {
            let retreatRatio = expandingReach ? farthestScale / scale : scale / farthestScale
            armedScale = retreatRatio >= Self.disarmingRetreatRatio ? nil : scale
        }
    }
}
