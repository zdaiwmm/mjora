import Foundation
import CoreGraphics
import Observation

nonisolated enum PhotoBrowseMode: String, CaseIterable, Identifiable {
    case years, months, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .years: String(localized: "Years")
        case .months: String(localized: "Months")
        case .all: String(localized: "All")
        }
    }
}

nonisolated enum PhotoMediaFilter: String, CaseIterable, Identifiable {
    case all, favorites, photos, videos, livePhotos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All Items")
        case .favorites: String(localized: "Favorites")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        case .livePhotos: String(localized: "Live Photos")
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.3x3"
        case .favorites: "heart"
        case .photos: "photo"
        case .videos: "video"
        case .livePhotos: "livephoto"
        }
    }
    func includes(_ asset: Asset) -> Bool {
        switch self {
        case .all: true
        case .favorites: asset.isFavorite
        case .photos: asset.isImage
        case .videos: asset.isVideo
        case .livePhotos: asset.isLivePhoto
        }
    }
}

/// Derived from the full bucket index, never just the currently loaded assets.
nonisolated struct PhotoPeriod: Identifiable {
    let id: String
    let year: Int
    let month: Int?
    let count: Int
    let bucketIDs: [String]
    let cover: Asset?

    var representativeBucketID: String { bucketIDs[0] }
    var date: Date { TimelineModel.bucketDate(representativeBucketID)! }
    var title: String {
        month == nil ? String(year) : date.formatted(.dateTime.year().month(.wide).utc())
    }

    static func years(in sections: [TimelineSection]) -> [Self] { periods(in: sections, groupedByYear: true, year: nil) }
    static func months(in sections: [TimelineSection], year: Int? = nil) -> [Self] {
        periods(in: sections, groupedByYear: false, year: year)
    }

    private static func periods(in sections: [TimelineSection], groupedByYear: Bool, year: Int?) -> [Self] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let valid = sections.compactMap { section -> (TimelineSection, Int, Int)? in
            guard section.count > 0, let date = TimelineModel.bucketDate(section.id) else { return nil }
            let y = calendar.component(.year, from: date)
            guard year == nil || year == y else { return nil }
            return (section, y, calendar.component(.month, from: date))
        }
        let groups = Dictionary(grouping: valid) { value in
            groupedByYear ? "\(value.1)" : String(format: "%04d-%02d", value.1, value.2)
        }
        return groups.keys.sorted(by: >).compactMap { key in
            let values = groups[key]!.sorted { $0.0.id > $1.0.id }
            guard let first = values.first else { return nil }
            return Self(id: key, year: first.1, month: groupedByYear ? nil : first.2,
                        count: values.reduce(0) { $0 + $1.0.count }, bucketIDs: values.map { $0.0.id },
                        cover: values.lazy.compactMap { $0.0.days?.first?.assets.first }.first)
        }
    }
}

nonisolated struct PhotoScrollRequest: Equatable {
    let id = UUID()
    let bucketID: String?
}

@MainActor @Observable
final class PhotosGridControls {
    var columns = 3
    var usesOriginalAspectRatio = false
    var isSelecting = false
    var browsingPast = false
    var mode: PhotoBrowseMode = .all
    var selectedYear: Int?
    var scrollRequest: PhotoScrollRequest?
    @ObservationIgnored var viewportWidth: CGFloat = 393
    @ObservationIgnored var scrollOffset: CGFloat?
    @ObservationIgnored var isRestoring = false

    func zoomIn(viewportWidth: CGFloat) { adjustZoom(inward: true, width: viewportWidth) }
    func zoomOut(viewportWidth: CGFloat) { adjustZoom(inward: false, width: viewportWidth) }
    func reveal(bucketID: String?) {
        mode = .all
        scrollRequest = PhotoScrollRequest(bucketID: bucketID)
    }

    private func adjustZoom(inward: Bool, width: CGFloat) {
        let range = AssetGridLayout.columnRange(viewportWidth: width)
        let steps = Set([2, 3, 5, AssetGridLayout.defaultColumnCount(viewportWidth: width), range.upperBound])
            .filter { range.contains($0) }.sorted()
        columns = inward ? (steps.last { $0 < columns } ?? steps.first ?? 2)
            : (steps.first { $0 > columns } ?? steps.last ?? 5)
    }
}
