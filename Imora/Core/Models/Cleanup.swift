import Foundation

// MARK: - library cleanup, gallery and imora

/// the queues the cleanup routes name. commits take every one but
/// duplicates, pages only the four list queues and counts every one but rewind.
nonisolated enum CleanupQueue: String, Codable, Hashable, Sendable {
    case rewind
    case spaceHogs = "space_hogs"
    case bursts
    case screenshots
    case blurry
    case duplicates

    var title: String {
        switch self {
        case .rewind: String(localized: "Rewind")
        case .spaceHogs: String(localized: "Space Hogs")
        case .bursts: String(localized: "Bursts")
        case .screenshots: String(localized: "Screenshots")
        case .blurry: String(localized: "Blurry")
        case .duplicates: String(localized: "Duplicates")
        }
    }
}

nonisolated enum CleanupStrictness: String, CaseIterable, Hashable, Sendable {
    case lenient, balanced, strict

    var title: String { rawValue.capitalized }
}

/// why a photo sits in the blurry queue. `all` only filters.
nonisolated enum CleanupBlurReason: String, CaseIterable, Codable, Hashable, Sendable {
    case all, blurry, dark, bright

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .blurry: String(localized: "Blurry")
        case .dark: String(localized: "Too Dark")
        case .bright: String(localized: "Overexposed")
        }
    }
}

nonisolated enum CleanupMediaFilter: String, CaseIterable, Hashable, Sendable {
    case all, image, video

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .image: String(localized: "Photos")
        case .video: String(localized: "Videos")
        }
    }
}

/// the query of a queue page or count. the server's defaults, so an
/// untouched filter sends what it would have assumed anyway.
nonisolated struct CleanupFilters: Hashable, Sendable {
    /// the server's minimum for space hogs, 100 MiB.
    static let defaultMinSize: Int64 = 104_857_600
    static let minSizes: [Int64] = [52_428_800, defaultMinSize, 524_288_000, 1_073_741_824]

    var strictness = CleanupStrictness.balanced
    var reason = CleanupBlurReason.all
    var hideFaces = true
    var media = CleanupMediaFilter.all
    var minSize = defaultMinSize

    func queryItems(for queue: CleanupQueue) -> [URLQueryItem] {
        switch queue {
        case .blurry:
            [
                URLQueryItem(name: "strictness", value: strictness.rawValue),
                URLQueryItem(name: "reason", value: reason.rawValue),
                URLQueryItem(name: "hideFaces", value: hideFaces ? "true" : "false"),
            ]
        case .spaceHogs:
            [
                URLQueryItem(name: "type", value: media.rawValue),
                URLQueryItem(name: "minSize", value: String(minSize)),
            ]
        default:
            []
        }
    }
}

/// one photo of a cleanup queue or rewind day.
nonisolated struct CleanupAsset: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: AssetType
    let originalFileName: String
    /// the local wall clock, written as utc.
    let localDateTime: String
    let thumbhash: String?
    let width: Double?
    let height: Double?
    /// milliseconds, nil for stills.
    let duration: Int?
    let fileSize: Int64
    var isFavorite: Bool
    let inAlbum: Bool
    let city: String?
    /// a keep in this queue already, rewind and bursts only.
    let kept: Bool
    let reason: CleanupBlurReason?
    let sharpness: Double?

    private enum CodingKeys: String, CodingKey {
        case id, type, originalFileName, localDateTime, thumbhash, width, height, duration, fileSize
        case isFavorite, inAlbum, city, kept, reason, sharpness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decode(AssetType.self, forKey: .type)) ?? .other
        originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        localDateTime = try container.decode(String.self, forKey: .localDateTime)
        thumbhash = try container.decodeIfPresent(String.self, forKey: .thumbhash)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        duration = Self.milliseconds(container, key: .duration)
        fileSize = Int64(try container.decodeIfPresent(Double.self, forKey: .fileSize) ?? 0)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        inAlbum = try container.decodeIfPresent(Bool.self, forKey: .inAlbum) ?? false
        city = try container.decodeIfPresent(String.self, forKey: .city)
        kept = try container.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        reason = try? container.decodeIfPresent(CleanupBlurReason.self, forKey: .reason)
        sharpness = try? container.decodeIfPresent(Double.self, forKey: .sharpness)
    }

    /// gallery keeps immich's `H:MM:SS.ffffff` text where imora sends milliseconds.
    private static func milliseconds(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? Int(seconds * 1000) : nil
    }

    var isVideo: Bool { type == .video }

    var localDate: Date { APIDate.parse(localDateTime) ?? .distantPast }

    var year: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: localDate)
    }

    var dateText: String {
        localDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    var ratio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return width / height
    }

    /// the shape the viewer pages through. the wall clock is kept as is with
    /// no offset, which is how the viewer shows it.
    func asAsset(ownerID: String) -> Asset {
        Asset(
            id: id,
            ownerId: ownerID,
            isImage: type == .image,
            isFavorite: isFavorite,
            isTrashed: false,
            visibility: .timeline,
            thumbhash: thumbhash,
            fileCreatedAt: localDate,
            localOffsetHours: 0,
            duration: duration,
            livePhotoVideoId: nil,
            ratio: ratio,
            city: city,
            country: nil,
            createdAt: nil,
            originalFileName: originalFileName
        )
    }
}

/// a queue's size. `analysedPercent` is set on the queues that wait for the
/// quality job, until it has seen the whole library.
nonisolated struct CleanupQueueCount: Decodable, Hashable, Sendable {
    let count: Int
    let bytes: Int64
    let analysedPercent: Double?

    var isAnalysing: Bool { (analysedPercent ?? 100) < 100 }
}

nonisolated struct CleanupTotals: Decodable, Hashable, Sendable {
    let count: Int
    let bytes: Int64
}

nonisolated struct CleanupCalendarDay: Decodable, Hashable, Sendable {
    /// month * 100 + day, 229 included.
    let monthDay: Int
    let assetCount: Int
    let reviewedAt: String?

    var isReviewed: Bool { reviewedAt != nil && assetCount > 0 }
}

nonisolated struct CleanupCalendar: Decodable, Hashable, Sendable {
    let days: [CleanupCalendarDay]
    let daysReviewed: Int
    let streak: Int
}

nonisolated struct CleanupRewindYear: Decodable, Hashable, Sendable {
    let year: Int
    let count: Int
}

nonisolated struct CleanupBurstGroup: Decodable, Identifiable, Hashable, Sendable {
    let groupId: String
    /// `burstId` for a camera burst, `timeWindow` for shots found close in time and look.
    let source: String
    var assets: [CleanupAsset]
    let suggestedKeepId: String

    var id: String { groupId }
    var isCameraBurst: Bool { source == "burstId" }
}

nonisolated struct CleanupQueuePage: Decodable, Sendable {
    let items: [CleanupAsset]
    let groups: [CleanupBurstGroup]
    let nextCursor: String?
}

nonisolated struct CleanupCommit: Encodable, Sendable {
    let queue: CleanupQueue
    var trashIds: [String]? = nil
    var favoriteIds: [String]? = nil
    var keepIds: [String]? = nil
    var completeMonthDay: Int? = nil
}

nonisolated struct CleanupCommitResult: Decodable, Sendable {
    struct Skipped: Decodable, Sendable {
        let id: String
        let reason: String
    }

    let trashed: [String]
    let favorited: Int
    let kept: Int
    let skipped: [Skipped]
}

/// the photos of a lookup that a shared space holds, and those of an external library.
nonisolated struct CleanupInSpaces: Decodable, Sendable {
    let assetIds: [String]
    let externalAssetIds: [String]
}

/// dates as the cleanup routes name them, month * 100 + day.
nonisolated enum CleanupMonthDay {
    /// a leap year, so 29 February is a date like any other.
    private static let leapYear = 2000

    static func today(_ now: Date = Date()) -> Int {
        let parts = Calendar.current.dateComponents([.month, .day], from: now)
        return (parts.month ?? 1) * 100 + (parts.day ?? 1)
    }

    static func date(_ monthDay: Int) -> Date {
        let parts = DateComponents(year: leapYear, month: monthDay / 100, day: monthDay % 100, hour: 12)
        return Calendar.current.date(from: parts) ?? Date()
    }

    /// the date `delta` days away, wrapping round the year.
    static func shift(_ monthDay: Int, by delta: Int) -> Int {
        guard let shifted = Calendar.current.date(byAdding: .day, value: delta, to: date(monthDay)) else {
            return monthDay
        }
        return today(shifted)
    }

    static func label(_ monthDay: Int) -> String {
        date(monthDay).formatted(.dateTime.month(.wide).day())
    }

    static func daysIn(month: Int) -> Int {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][max(0, min(11, month - 1))]
    }

    static func monthName(_ month: Int) -> String {
        date(month * 100 + 1).formatted(.dateTime.month(.abbreviated))
    }

    /// the first date after `from`, round the year, with photos and not reviewed yet.
    static func nextUnreviewed(in days: [CleanupCalendarDay], after from: Int) -> Int? {
        let candidates = days
            .filter { $0.monthDay != from && $0.assetCount > 0 && $0.reviewedAt == nil }
            .map(\.monthDay)
            .sorted()
        return candidates.first { $0 > from } ?? candidates.first
    }
}
