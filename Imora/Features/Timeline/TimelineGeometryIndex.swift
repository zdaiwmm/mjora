import CoreGraphics
import Foundation

/// Counts and flattened offsets survive a density change. Gesture geometry
/// reads these small groups instead of rebuilding every photo's row and metadata.
nonisolated struct TimelineGeometryIndex {
    struct Day {
        let start: Int
        let count: Int
        let hasTitle: Bool
    }
    struct Section {
        let id: String
        let start: Int
        let count: Int
        let indexedCount: Int
        let days: [Day]?
        let leading: Int
        let trailing: Int
        var hasValidPartialRange: Bool {
            leading >= 0 && trailing >= 0 && leading <= indexedCount
                && trailing <= indexedCount - leading && count == indexedCount - leading - trailing
        }
    }
    private struct Placement {
        let range: Range<Int>
        let y: CGFloat
        let column: Int
        let width: Int

        func rowY(_ row: Int, stride: CGFloat) -> CGFloat {
            y + CGFloat(row) * stride
        }

        func frame(at index: Int, side: CGFloat, viewportWidth: CGFloat, rightToLeft: Bool) -> CGRect {
            let stride = side + AssetGridLayout.gutter
            let offset = index - range.lowerBound
            let x = CGFloat(column + offset % width) * stride
            return CGRect(x: rightToLeft ? viewportWidth - x - side : x,
                y: rowY(offset / width, stride: stride), width: side, height: side)
        }
    }
    let sections: [Section]
    let sectionByID: [String: Int]
    let bucketList: Data?

    init(sections source: [TimelineSection]) {
        var offset = 0
        sections = source.map { section in
            let start = offset
            let days = section.days?.map { day in
                let value = Day(start: offset, count: day.assets.count, hasTitle: !day.title.isEmpty)
                offset += value.count
                return value
            }
            return Section(id: section.id, start: start, count: offset - start,
                indexedCount: section.count, days: days, leading: section.leadingUnloadedAssetCount,
                trailing: section.trailingUnloadedAssetCount)
        }
        sectionByID = Dictionary(uniqueKeysWithValues: sections.enumerated().map { ($0.element.id, $0.offset) })
        bucketList = try? JSONEncoder().encode(sections.map {
            TimeBucket(timeBucket: $0.id, count: $0.days == nil || $0.leading > 0 || $0.trailing > 0 ? $0.indexedCount : $0.count)
        })
    }

    func frames(for indices: [String: Int], columns: Int, width: CGFloat,
                grouped: Bool, assetsPerDay: Double, rightToLeft: Bool) -> [String: CGRect] {
        guard columns > 0, width > 0, !indices.isEmpty else { return [:] }
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: columns)
        let (placements, _) = layout(columns: columns, side: side, grouped: grouped, assetsPerDay: assetsPerDay)
        var result: [String: CGRect] = [:]
        result.reserveCapacity(indices.count)
        for (id, index) in indices {
            guard let placement = placement(containing: index, in: placements) else { continue }
            result[id] = placement.frame(at: index, side: side, viewportWidth: width, rightToLeft: rightToLeft)
        }
        return result
    }

    func window(around anchorIndex: Int?, unitY: CGFloat, viewportReach: CGFloat, columns: Int, width: CGFloat,
                grouped: Bool, assetsPerDay: Double, rightToLeft: Bool)
        -> (tiles: [(index: Int, frame: CGRect)], rowsHeight: CGFloat) {
        guard columns > 0, width.isFinite, width > 0 else { return ([], 0) }
        let side = AssetGridLayout.tileSide(viewportWidth: width, columns: columns)
        let stride = side + AssetGridLayout.gutter
        let (placements, rowsHeight) = layout(columns: columns, side: side, grouped: grouped, assetsPerDay: assetsPerDay)
        guard let anchorIndex, let anchorPlacement = placement(containing: anchorIndex, in: placements),
              unitY.isFinite, viewportReach >= 0 else { return ([], rowsHeight) }
        let anchor = anchorPlacement.frame(at: anchorIndex, side: side, viewportWidth: width, rightToLeft: rightToLeft)
        let anchorY = anchor.minY + min(max(unitY, 0), 1) * anchor.height
        let minY = anchorY - viewportReach, maxY = anchorY + viewportReach

        var tiles: [(index: Int, frame: CGRect)] = []
        for placement in placements {
            if placement.y > maxY { break }
            let lastRow = (placement.range.count - 1) / placement.width
            guard placement.rowY(lastRow, stride: stride) + side >= minY else { continue }

            let startRow = firstIndex(upTo: lastRow + 1) { placement.rowY($0, stride: stride) + side >= minY }
            let endRow = firstIndex(upTo: lastRow + 1) { placement.rowY($0, stride: stride) > maxY }
            let start = placement.range.lowerBound + startRow * placement.width
            let end = endRow <= lastRow ? placement.range.lowerBound + endRow * placement.width : placement.range.upperBound
            for index in start..<end {
                let frame = placement.frame(at: index, side: side, viewportWidth: width, rightToLeft: rightToLeft)
                tiles.append((index, frame))
            }
        }
        return (tiles, rowsHeight)
    }

    private func placement(containing index: Int, in placements: [Placement]) -> Placement? {
        let position = firstIndex(upTo: placements.count) { placements[$0].range.upperBound > index }
        guard placements.indices.contains(position), placements[position].range.contains(index) else { return nil }
        return placements[position]
    }

    private func firstIndex(upTo count: Int, where matches: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if matches(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private func layout(columns: Int, side: CGFloat, grouped: Bool, assetsPerDay: Double)
        -> (placements: [Placement], rowsHeight: CGFloat) {
        grouped ? groupedPlacements(columns: columns, side: side, assetsPerDay: assetsPerDay)
            : compactPlacements(columns: columns, side: side)
    }

    private func compactPlacements(columns: Int, side: CGFloat) -> (placements: [Placement], rowsHeight: CGFloat) {
        var slot = 0
        var known: [(range: Range<Int>, slot: Int)] = []
        var unknownRows: [Range<Int>] = []
        func unknown(_ count: Int) {
            guard count > 0 else { return }
            let range = slot / columns..<(slot + count - 1) / columns + 1
            if let last = unknownRows.last, last.upperBound >= range.lowerBound {
                unknownRows[unknownRows.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { unknownRows.append(range) }
            slot += count
        }
        for section in sections {
            guard section.days != nil else { unknown(section.indexedCount); continue }
            if (section.leading > 0 || section.trailing > 0), !section.hasValidPartialRange {
                unknown(section.indexedCount)
                continue
            }
            unknown(section.leading)
            if section.count > 0 { known.append((section.start..<section.start + section.count, slot)) }
            slot += section.count
            unknown(section.trailing)
        }
        var placements: [Placement] = []
        var missingIndex = 0
        for value in known {
            var start = value.range.lowerBound
            let endSlot = value.slot + value.range.count
            var currentSlot = value.slot
            while missingIndex < unknownRows.count, unknownRows[missingIndex].upperBound <= currentSlot / columns { missingIndex += 1 }
            while start < value.range.upperBound {
                let missing = missingIndex < unknownRows.count ? unknownRows[missingIndex] : nil
                if let missing, missing.contains(currentSlot / columns) {
                    let skip = min(endSlot - currentSlot, missing.upperBound * columns - currentSlot)
                    start += skip; currentSlot += skip
                    if currentSlot / columns >= missing.upperBound { missingIndex += 1 }
                    continue
                }
                let end = min(endSlot, missing.map { $0.lowerBound * columns } ?? endSlot)
                let count = end - currentSlot
                guard count > 0 else { break }
                // Split only at the first partial row. Subsequent rows share
                // the same full-width stride regardless of month boundaries.
                let leading = min(count, columns - currentSlot % columns)
                placements.append(.init(range: start..<start + leading,
                    y: CGFloat(currentSlot / columns) * (side + AssetGridLayout.gutter),
                    column: currentSlot % columns, width: columns))
                start += leading; currentSlot += leading
                if currentSlot < end {
                    placements.append(.init(range: start..<start + end - currentSlot,
                        y: CGFloat(currentSlot / columns) * (side + AssetGridLayout.gutter), column: 0, width: columns))
                    start += end - currentSlot; currentSlot = end
                }
            }
        }
        let rowCount = slot / columns + (slot % columns == 0 ? 0 : 1)
        return (placements, CGFloat(rowCount) * (side + AssetGridLayout.gutter))
    }

    private func groupedPlacements(columns: Int, side: CGFloat, assetsPerDay: Double)
        -> (placements: [Placement], rowsHeight: CGFloat) {
        var result: [Placement] = []
        var y: CGFloat = 0
        var assetTally = 0, dayTally = 0
        var ratio = assetsPerDay
        for section in sections {
            if let days = section.days {
                var sectionPlacements: [Placement] = []
                for band in TimelineFlowLayout.pack(counts: days.map(\.count), columns: columns) {
                    if band.blocks.contains(where: { days[$0.dayIndex].hasTitle }) { y += 36 }
                    for block in band.blocks {
                        let day = days[block.dayIndex]
                        sectionPlacements.append(.init(range: day.start..<day.start + day.count,
                            y: y, column: block.colStart, width: block.colWidth))
                    }
                    y += CGFloat(band.rowCount) * (side + AssetGridLayout.gutter)
                }
                result.append(contentsOf: sectionPlacements.sorted { $0.range.lowerBound < $1.range.lowerBound })
                assetTally += section.count; dayTally += days.count
                if dayTally > 0 { ratio = Double(assetTally) / Double(dayTally) }
            } else {
                let estimate = TimelineModel.placeholderEstimate(count: section.indexedCount,
                    columns: columns, assetsPerDay: ratio)
                y += CGFloat(estimate.titleBands) * 36 + CGFloat(estimate.tileRows) * (side + AssetGridLayout.gutter)
            }
        }
        return (result, y)
    }
}
