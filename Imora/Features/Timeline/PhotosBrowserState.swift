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
    case all, favorites, photos, videos, livePhotos, edited, notInAlbum, screenshots
    case panoramas, selfPortraits, highFrameRate, timeLapses, screenRecordings, raw, bursts

    static let mediaTypes: [Self] = [.photos, .videos, .livePhotos, .panoramas, .selfPortraits,
        .highFrameRate, .timeLapses, .screenRecordings, .raw, .bursts]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All Items")
        case .favorites: String(localized: "Favorites")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        case .livePhotos: String(localized: "Live Photos")
        case .edited: String(localized: "Edited")
        case .notInAlbum: String(localized: "Not in an Album")
        case .screenshots: String(localized: "Screenshots")
        case .panoramas: String(localized: "Panoramas")
        case .selfPortraits: String(localized: "Selfies")
        case .highFrameRate: String(localized: "High Frame Rate")
        case .timeLapses: String(localized: "Time-Lapse")
        case .screenRecordings: String(localized: "Screen Recordings")
        case .raw: String(localized: "RAW")
        case .bursts: String(localized: "Bursts")
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.3x3"
        case .favorites: "heart"
        case .photos: "photo"
        case .videos: "video"
        case .livePhotos: "livephoto"
        case .edited: "slider.horizontal.3"
        case .notInAlbum: "rectangle.stack.badge.minus"
        case .screenshots: "camera.viewfinder"
        case .panoramas: "pano"
        case .selfPortraits: "person.crop.rectangle"
        case .highFrameRate: "gauge.with.dots.needle.67percent"
        case .timeLapses: "timelapse"
        case .screenRecordings: "record.circle"
        case .raw: "camera"
        case .bursts: "square.3.layers.3d"
        }
    }
    var deviceCategory: MediaCategory? {
        switch self {
        case .photos: .photo
        case .videos: .video
        case .livePhotos: .livePhoto
        case .screenshots: .screenshot
        case .edited: .edited
        case .panoramas: .panorama
        case .selfPortraits: .selfPortrait
        case .highFrameRate: .highFrameRate
        case .timeLapses: .timeLapse
        case .screenRecordings: .screenRecording
        case .raw: .raw
        case .bursts: .burst
        case .all, .favorites, .notInAlbum: nil
        }
    }
    var requiresDeviceFacts: Bool {
        [.panoramas, .selfPortraits, .highFrameRate, .timeLapses, .screenRecordings, .raw, .bursts].contains(self)
    }
    func isAvailable(onDevice: Bool) -> Bool { onDevice || !requiresDeviceFacts }

    var cloudSearchFilter: SearchFilter {
        var filter = SearchFilter()
        filter.sortOrder = .newest
        switch self {
        case .photos: filter.mediaType = .image
        case .videos: filter.mediaType = .video
        case .livePhotos: filter.mediaType = .image; filter.isMotion = true
        case .favorites: filter.isFavorite = true
        case .notInAlbum: filter.notInAlbum = true
        case .all, .edited, .screenshots, .panoramas, .selfPortraits, .highFrameRate,
                .timeLapses, .screenRecordings, .raw, .bursts: break
        }
        return filter
    }

    func includes(_ asset: Asset, facts: MediaFactsSnapshot? = nil) -> Bool {
        switch self {
        case .all: true
        case .favorites: asset.isFavorite
        case .photos: asset.isImage
        case .videos: asset.isVideo
        case .livePhotos: asset.isLivePhoto
        case .edited: asset.isEdited == true
        case .notInAlbum: asset.isInAppAlbum == false
        case .screenshots: asset.isScreenshot == true
        case .panoramas, .selfPortraits, .highFrameRate, .timeLapses, .screenRecordings, .raw, .bursts:
            if let identifier = asset.localIdentifier, let category = deviceCategory {
                facts?.value(category, for: identifier) == .yes
            } else { false }
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
    let coverBucketID: String?

    var representativeBucketID: String { coverBucketID ?? bucketIDs[0] }
    var date: Date { TimelineModel.bucketDate(representativeBucketID)! }
    var title: String {
        month == nil ? String(year) : date.formatted(.dateTime.year().month(.wide).utc())
    }

    static func years(in sections: [TimelineSection], preferredAssetID: String? = nil) -> [Self] {
        periods(in: sections, groupedByYear: true, year: nil, preferredAssetID: preferredAssetID)
    }
    static func months(in sections: [TimelineSection], year: Int? = nil, preferredAssetID: String? = nil) -> [Self] {
        periods(in: sections, groupedByYear: false, year: year, preferredAssetID: preferredAssetID)
    }

    private static func periods(in sections: [TimelineSection], groupedByYear: Bool, year: Int?, preferredAssetID: String?) -> [Self] {
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
            let loaded = values.flatMap { value in
                (value.0.days ?? []).flatMap(\.assets).map { (asset: $0, bucketID: value.0.id) }
            }
            let chosen = loaded.first(where: { $0.asset.id == preferredAssetID }) ?? loaded.first
            return Self(id: key, year: first.1, month: groupedByYear ? nil : first.2,
                        count: values.reduce(0) { $0 + $1.0.count }, bucketIDs: values.map { $0.0.id },
                        cover: chosen?.asset, coverBucketID: chosen?.bucketID)
        }
    }
}

nonisolated struct PhotoScrollRequest: Equatable {
    let id = UUID()
    let bucketID: String?
    var assetID: String? = nil
}

nonisolated struct PhotoPeriodAnchor {
    let asset: Asset
    let bucketID: String
    var scrollOffset: CGFloat? = nil
}

@MainActor @Observable
final class PhotosGridControls {
    var columns = 3
    var usesOriginalAspectRatio = false
    var groupsByDate = false
    var sortByAdded = false
    var mediaFilter: PhotoMediaFilter = .all
    var isSelecting = false
    var browsingPast = false
    var mode: PhotoBrowseMode = .all {
        didSet { if oldValue != mode { onModeChange?(oldValue, mode) } }
    }
    var periodAnchor: PhotoPeriodAnchor?
    var showsAllBackupStatuses = false {
        didSet { visualStore.save(PhotosVisualPreferences(showsAllBackupStatuses: showsAllBackupStatuses), account: visualAccount) }
    }
    @ObservationIgnored var onModeChange: ((PhotoBrowseMode, PhotoBrowseMode) -> Void)?
    @ObservationIgnored private var visualAccount: String?
    @ObservationIgnored private var visualStore = PhotosVisualPreferencesStore()

    func loadVisualPreferences(account: String?) {
        guard visualAccount != account else { return }
        visualAccount = account
        showsAllBackupStatuses = visualStore.load(account: account).showsAllBackupStatuses
    }
    var selectedYear: Int?
    var scrollRequest: PhotoScrollRequest?
    @ObservationIgnored var viewportWidth: CGFloat = 393
    @ObservationIgnored var scrollOffset: CGFloat?
    @ObservationIgnored var isRestoring = false

    func observeScroll(offset: CGFloat, endOffset: CGFloat, isUserScrolling: Bool) {
        guard !isRestoring else { return }
        let previous = scrollOffset
        scrollOffset = offset
        guard mode == .all else { return }
        if endOffset <= 0 || endOffset - offset <= 8 {
            browsingPast = false
        } else if isUserScrolling, let previous, offset < previous {
            browsingPast = true
        }
    }

    func zoomIn(viewportWidth: CGFloat) { adjustZoom(inward: true, width: viewportWidth) }
    func zoomOut(viewportWidth: CGFloat) { adjustZoom(inward: false, width: viewportWidth) }
    func reveal(bucketID: String?, assetID: String? = nil) {
        if bucketID == nil { periodAnchor = nil }
        scrollRequest = PhotoScrollRequest(bucketID: bucketID, assetID: assetID)
        mode = .all
    }

    private func adjustZoom(inward: Bool, width: CGFloat) {
        let range = AssetGridLayout.columnRange(viewportWidth: width)
        let steps = Set([2, 3, 5, AssetGridLayout.defaultColumnCount(viewportWidth: width), range.upperBound])
            .filter { range.contains($0) }.sorted()
        columns = inward ? (steps.last { $0 < columns } ?? steps.first ?? 2)
            : (steps.first { $0 > columns } ?? steps.last ?? 5)
    }
}
