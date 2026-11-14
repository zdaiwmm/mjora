import Foundation

/// smart queries use relevance search; text and filters use metadata search.
nonisolated struct SearchFilter: Equatable {
    enum TextType: String, CaseIterable, Identifiable, Codable {
        case context
        case filename
        case description
        case path
        case ocr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .context: String(localized: "Smart Search")
            case .filename: String(localized: "File Name")
            case .description: String(localized: "Description")
            case .path: String(localized: "Folder or Path")
            case .ocr: String(localized: "Text in Photos")
            }
        }

        var subtitle: String {
            switch self {
            case .context: String(localized: "Describe what is in the photo.")
            case .filename: String(localized: "Match the original file name.")
            case .description: String(localized: "Match the description you added.")
            case .path: String(localized: "Match any part of the original file path.")
            case .ocr: String(localized: "Find text recognized in images.")
            }
        }

        var prompt: String {
            switch self {
            case .context: String(localized: "Describe a photo or moment")
            case .filename: String(localized: "IMG_1234.JPG or PNG")
            case .description: String(localized: "Search descriptions")
            case .path: String(localized: "Folder or path")
            case .ocr: String(localized: "Text in your photos")
            }
        }

        var symbol: String {
            switch self {
            case .context: "sparkles"
            case .filename: "doc"
            case .description: "text.bubble"
            case .path: "folder"
            case .ocr: "text.viewfinder"
            }
        }
    }

    enum MediaType: String, CaseIterable, Identifiable {
        case all
        case image
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "Photos & Videos")
            case .image: String(localized: "Photos")
            case .video: String(localized: "Videos")
            }
        }

        var symbol: String {
            switch self {
            case .all: "photo.on.rectangle"
            case .image: "photo"
            case .video: "video"
            }
        }

        /// uppercase wire value, nil means no type filter.
        var wireValue: String? {
            switch self {
            case .all: nil
            case .image: "IMAGE"
            case .video: "VIDEO"
            }
        }
    }

    /// any = no filter, unrated = explicit null, stars = 1...5.
    enum Rating: Hashable {
        case any
        case unrated
        case stars(Int)
    }

    /// an exif value to match. unknown matches assets where the server has none.
    enum Facet: Hashable {
        case unknown
        case value(String)

        var label: String {
            switch self {
            case .unknown: String(localized: "Unknown")
            case .value(let value): value
            }
        }

        /// nil for unknown, which the server reads as "is null".
        var wireValue: String? {
            switch self {
            case .unknown: nil
            case .value(let value): value
            }
        }
    }

    /// how several selected people combine. any needs search v2.
    enum Match: String, CaseIterable, Identifiable {
        case all
        case any

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All Selected")
            case .any: String(localized: "Any Selected")
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case relevance, newest, oldest, largest, highestRated

        var id: String { rawValue }

        var title: String {
            switch self {
            case .relevance: String(localized: "Best Match")
            case .newest: String(localized: "Newest First")
            case .oldest: String(localized: "Oldest First")
            case .largest: String(localized: "Largest First")
            case .highestRated: String(localized: "Highest Rated")
            }
        }

        var symbol: String {
            switch self {
            case .relevance: "sparkle.magnifyingglass"
            case .newest: "arrow.down"
            case .oldest: "arrow.up"
            case .largest: "externaldrive"
            case .highestRated: "star"
            }
        }

        /// only date orders read naturally as month and day sections.
        var groupsByDate: Bool { self == .newest || self == .oldest }

        /// server-side orders that only search v2 accepts.
        var requiresV2: Bool { self == .largest || self == .highestRated }
    }

    var text = ""
    var textType: TextType = .context
    /// bcp47-ish tag sent with smart search, e.g. "en-US".
    var language: String?
    /// smart search by visual similarity to this asset instead of a query.
    var queryAssetID: String?

    var people: [Person] = []
    var peopleMatch: Match = .all
    var tags: [Tag] = []
    /// only assets without any tag, exclusive with tags.
    var isUntagged = false
    var country: Facet?
    var state: Facet?
    var city: Facet?
    var make: Facet?
    var model: Facet?
    var lensModel: Facet?
    var takenAfter: Date?
    var takenBefore: Date?
    /// human label for the chip, set by the date picker ("Last 30 Days").
    var dateLabel: String?
    /// Stable selection identity; display text must not determine picker state.
    var dateSelectionID: String?
    var rating: Rating = .any
    var notInAlbum = false
    var isArchive = false
    var isFavorite = false
    var mediaType: MediaType = .all
    var sortOrder: SortOrder = .relevance

    var usesSmartSearch: Bool {
        (textType == .context && !text.isEmpty) || queryAssetID != nil
    }

    /// relevance only exists for smart search, and size or rating orders only
    /// for metadata search; each falls back to the closest valid order.
    var effectiveSortOrder: SortOrder {
        if usesSmartSearch {
            return sortOrder.requiresV2 ? .relevance : sortOrder
        }
        return sortOrder == .relevance ? .newest : sortOrder
    }

    /// true when matching any of several people, which only search v2 can express.
    var matchesAnyPerson: Bool { peopleMatch == .any && people.count > 1 }

    var isEmpty: Bool {
        text.isEmpty && queryAssetID == nil && !hasFilters
    }

    /// anything beyond the query text.
    var hasFilters: Bool {
        !people.isEmpty || !tags.isEmpty || isUntagged
            || country != nil || state != nil || city != nil
            || make != nil || model != nil || lensModel != nil
            || takenAfter != nil || takenBefore != nil
            || rating != .any
            || notInAlbum || isArchive || isFavorite
            || mediaType != .all
    }

    /// replaces the query text. the type only sticks while there is text, so
    /// switching modes on an empty field never restarts a filter-only search.
    mutating func setText(_ text: String, type: TextType) {
        queryAssetID = nil
        self.text = text
        textType = text.isEmpty ? .context : type
    }
}
