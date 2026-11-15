import Foundation

/// A real photographer-local day, independent of the timeline's upload-day
/// labels. The cover always belongs to assets and retains its source bucket
/// so a card opens the displayed photo rather than a month-level substitute.
nonisolated struct PhotoMonthDay: Identifiable {
    let id: String
    let date: Date
    let assets: [Asset]
    let cover: Asset
    let coverBucketID: String
}

/// Capture-date month content. Bucket counts cannot reveal how many days are
/// present: a composition may use completeDayCount only after every indexed
/// bucket has loaded. A failed/cancelled fetch stays unknown, never empty.
/// Date-added indexes need an explicit capture-date index before using this
/// model as a complete capture-month overview.
nonisolated struct PhotoMonthContent {
    let days: [PhotoMonthDay]
    let missingBucketIDs: [String]
    let indexedAssetCount: Int
    let hasCaptureMonthMismatch: Bool

    var isComplete: Bool { missingBucketIDs.isEmpty }
    var completeDayCount: Int? { isComplete ? days.count : nil }
    var loadedAssetCount: Int { days.reduce(0) { $0 + $1.assets.count } }

    init(period: PhotoPeriod, sections: [TimelineSection], preferredAssetID: String? = nil,
         preferredBucketID: String? = nil, retainedCoverIDs: [String: String] = [:]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let bucketIDs = Set(period.bucketIDs)
        let sources = sections.filter { bucketIDs.contains($0.id) }
        let loadedIDs = Set(sources.filter { $0.days != nil }.map(\.id))
        missingBucketIDs = period.bucketIDs.filter { !loadedIDs.contains($0) }.sorted()
        indexedAssetCount = period.count

        struct Source {
            let asset: Asset
            let bucketID: String
        }
        // Resolve repeated appearances of one asset deterministically. Preserve
        // an exact preferred source when supplied by the grid's photo anchor.
        let candidates = sources.flatMap { section in
            (section.days ?? []).flatMap(\.assets).map { Source(asset: $0, bucketID: section.id) }
        }.sorted { lhs, rhs in
            if lhs.bucketID == preferredBucketID, rhs.bucketID != preferredBucketID { return true }
            if rhs.bucketID == preferredBucketID, lhs.bucketID != preferredBucketID { return false }
            if lhs.bucketID != rhs.bucketID { return lhs.bucketID < rhs.bucketID }
            return lhs.asset.id < rhs.asset.id
        }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.asset.id).inserted }
        let grouped = Dictionary(grouping: unique) { calendar.startOfDay(for: $0.asset.localDate) }
        days = grouped.keys.sorted().map { date in
            let values = grouped[date]!.sorted {
                if $0.asset.localDate != $1.asset.localDate { return $0.asset.localDate < $1.asset.localDate }
                return $0.asset.id < $1.asset.id
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            let id = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
            let chosen = values.first { $0.asset.id == preferredAssetID }
                ?? values.first { $0.asset.id == retainedCoverIDs[id] }
                ?? values.last!
            return PhotoMonthDay(id: id, date: date, assets: values.map(\.asset),
                                 cover: chosen.asset, coverBucketID: chosen.bucketID)
        }
        // Do not silently throw away a real day at an inconsistent source
        // boundary. Expose the mismatch so callers can refresh the index.
        hasCaptureMonthMismatch = days.contains {
            calendar.component(.year, from: $0.date) != period.year
                || calendar.component(.month, from: $0.date) != period.month
        }
    }
}
