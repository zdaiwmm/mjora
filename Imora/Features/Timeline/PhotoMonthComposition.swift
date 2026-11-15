import CoreGraphics

/// Adaptive day-count policy requested for month browsing. Native AX supplied
/// the outer 20pt inset and single 3:2 photo band; the multi-day arrangements
/// below are the product policy, not measurements from a native multi-card
/// capture. Each frame corresponds to one input day in chronological order.
nonisolated struct PhotoMonthComposition {
    let frames: [CGRect]
    let bandCounts: [Int]
    let size: CGSize

    init(dayCount: Int?, contentWidth: CGFloat) {
        guard contentWidth.isFinite, contentWidth > 0 else {
            frames = []; bandCounts = []; size = .zero
            return
        }
        guard let dayCount, dayCount > 0 else {
            frames = []; bandCounts = []; size = CGSize(width: contentWidth, height: 0)
            return
        }
        let bandCount = (dayCount - 1) / 4 + 1
        let base = dayCount / bandCount
        let remainder = dayCount % bandCount
        let counts = (0..<bandCount).map { base + ($0 < remainder ? 1 : 0) }
        // Use 4pt gaps at normal widths. Clamp only below 12pt so an initial
        // or extremely narrow proposal cannot create negative tile geometry.
        let gap = min(4, contentWidth / 3)
        let bandHeight = contentWidth * (2.0 / 3.0)
        let height = CGFloat(bandCount) * bandHeight + CGFloat(bandCount - 1) * gap
        guard height.isFinite else {
            frames = []; bandCounts = []; size = .zero
            return
        }
        var result: [CGRect] = []
        result.reserveCapacity(dayCount)
        for (index, count) in counts.enumerated() {
            let y = CGFloat(index) * (bandHeight + gap)
            let halfWidth = (contentWidth - gap) / 2
            let halfHeight = (bandHeight - gap) / 2
            switch count {
            case 1:
                result.append(CGRect(x: 0, y: y, width: contentWidth, height: bandHeight))
            case 2:
                result.append(CGRect(x: 0, y: y, width: halfWidth, height: bandHeight))
                result.append(CGRect(x: halfWidth + gap, y: y, width: halfWidth, height: bandHeight))
            case 3:
                // Divide the available width after the gap in a 2:1 ratio.
                let rightWidth = (contentWidth - gap) / 3
                let leftWidth = (contentWidth - gap) - rightWidth
                result.append(CGRect(x: 0, y: y, width: leftWidth, height: bandHeight))
                result.append(CGRect(x: leftWidth + gap, y: y, width: rightWidth, height: halfHeight))
                result.append(CGRect(x: leftWidth + gap, y: y + halfHeight + gap,
                                     width: rightWidth, height: halfHeight))
            default: // Four days, row-major; no day is elided into a cover.
                result.append(CGRect(x: 0, y: y, width: halfWidth, height: halfHeight))
                result.append(CGRect(x: halfWidth + gap, y: y, width: halfWidth, height: halfHeight))
                result.append(CGRect(x: 0, y: y + halfHeight + gap, width: halfWidth, height: halfHeight))
                result.append(CGRect(x: halfWidth + gap, y: y + halfHeight + gap,
                                     width: halfWidth, height: halfHeight))
            }
        }
        frames = result
        bandCounts = counts
        size = CGSize(width: contentWidth, height: height)
    }
}
