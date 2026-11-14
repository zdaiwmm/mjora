import Foundation

/// where the next page of results starts. servers before 3.2 count pages,
/// search v2 hands back an opaque cursor.
nonisolated enum SearchPageToken: Hashable, Sendable {
    case page(Int)
    case cursor(String)
}

/// minimal json tree for the nested search v2 filter objects.
nonisolated indirect enum SearchJSON: Encodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([SearchJSON])
    case object([String: SearchJSON])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func eq(_ value: SearchJSON) -> SearchJSON { .object(["eq": value]) }
    static func strings(_ values: [String]) -> SearchJSON { .array(values.map(SearchJSON.string)) }
}

/// one page request against /search/smart or /search/metadata.
///
/// 3.2 deprecated every flat field and rejects mixing them with the new
/// filter, orderBy and cursor, so a body is wholly one shape. metadata
/// search moves to v2 with cursors. smart search stays on the flat shape,
/// which still pages, unless the filter needs v2: smart v2 has no cursor
/// yet and answers with a single page.
nonisolated struct SearchRequest: Encodable, Sendable {
    enum Shape: Equatable, Sendable {
        case legacy(page: Int)
        case v2(cursor: String?)
    }

    let filter: SearchFilter
    let shape: Shape
    /// the flat takenAfter and takenBefore are wall clock days, see `takenRange`.
    let localTakenRange: Bool

    static let smartPageSize = 100
    static let legacyMetadataPageSize = 1_000
    static let metadataPageSize = 250
    /// smart v2 returns a single page, so it asks for a generous one.
    static let smartSinglePageSize = 500

    init(filter: SearchFilter, token: SearchPageToken?, supportsV2: Bool, localTakenRange: Bool = false) {
        self.filter = filter
        self.localTakenRange = localTakenRange
        let v2 = supportsV2 && (!filter.usesSmartSearch || filter.matchesAnyPerson)
        switch (v2, token) {
        case (true, .cursor(let cursor)): shape = .v2(cursor: cursor)
        case (true, _): shape = .v2(cursor: nil)
        case (false, .page(let page)): shape = .legacy(page: page)
        case (false, _): shape = .legacy(page: 1)
        }
    }

    var path: String { filter.usesSmartSearch ? "search/smart" : "search/metadata" }

    var pageSize: Int {
        switch (shape, filter.usesSmartSearch) {
        case (.legacy, true): Self.smartPageSize
        case (.legacy, false): Self.legacyMetadataPageSize
        case (.v2, true): Self.smartSinglePageSize
        case (.v2, false): Self.metadataPageSize
        }
    }

    /// the token for the page after this one, nil when this was the last.
    func nextToken(in page: SearchAssetPage) -> SearchPageToken? {
        guard !page.items.isEmpty else { return nil }
        switch shape {
        case .v2:
            return page.nextCursor.map(SearchPageToken.cursor)
        case .legacy(let current):
            guard let next = page.nextPage.flatMap(Int.init), next > current else { return nil }
            return .page(next)
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        if filter.usesSmartSearch {
            if let queryAssetID = filter.queryAssetID {
                try container.encode(queryAssetID, forKey: Key("queryAssetId"))
            } else {
                try container.encode(filter.text, forKey: Key("query"))
            }
            try container.encodeIfPresent(filter.language, forKey: Key("language"))
        }
        try container.encode(pageSize, forKey: Key("size"))
        try container.encode(true, forKey: Key("withExif"))

        switch shape {
        case .legacy(let page):
            try encodeLegacy(into: &container)
            try container.encode(page, forKey: Key("page"))
        case .v2(let cursor):
            try container.encode(SearchJSON.object(v2Filter), forKey: Key("filter"))
            if !filter.usesSmartSearch {
                try container.encode(v2Order, forKey: Key("orderBy"))
                try container.encodeIfPresent(cursor, forKey: Key("cursor"))
            }
        }
    }

    // MARK: - flat shape

    /// mirrors the web client: visibility always, favorite and not-in-album
    /// only when true, null tags for untagged and null values for unknown.
    private func encodeLegacy(into container: inout KeyedEncodingContainer<Key>) throws {
        if !filter.usesSmartSearch, !filter.text.isEmpty {
            let key = switch filter.textType {
            case .context, .filename: "originalFileName"
            case .description: "description"
            case .path: "originalPath"
            case .ocr: "ocr"
            }
            try container.encode(filter.text, forKey: Key(key))
        }

        let facets: [(String, SearchFilter.Facet?)] = [
            ("country", filter.country), ("state", filter.state), ("city", filter.city),
            ("make", filter.make), ("model", filter.model), ("lensModel", filter.lensModel),
        ]
        for (key, facet) in facets {
            guard let facet else { continue }
            try container.encode(facet.wireValue, forKey: Key(key))
        }

        let taken = takenRange
        try container.encodeIfPresent(taken.after, forKey: Key("takenAfter"))
        try container.encodeIfPresent(taken.before, forKey: Key("takenBefore"))

        try container.encode(filter.isArchive ? "archive" : "timeline", forKey: Key("visibility"))

        switch filter.rating {
        case .any: break
        case .unrated: try container.encodeNil(forKey: Key("rating"))
        case .stars(let count): try container.encode(count, forKey: Key("rating"))
        }

        if filter.isFavorite { try container.encode(true, forKey: Key("isFavorite")) }
        if filter.isMotion { try container.encode(true, forKey: Key("isMotion")) }
        if filter.notInAlbum { try container.encode(true, forKey: Key("isNotInAlbum")) }

        if !filter.people.isEmpty {
            try container.encode(filter.people.map(\.id), forKey: Key("personIds"))
        }
        if filter.isUntagged {
            try container.encodeNil(forKey: Key("tagIds"))
        } else if !filter.tags.isEmpty {
            try container.encode(filter.tags.map(\.id), forKey: Key("tagIds"))
        }

        if let type = filter.mediaType.wireValue {
            try container.encode(type, forKey: Key("type"))
        }
        if !filter.usesSmartSearch {
            try container.encode(filter.effectiveSortOrder == .oldest ? "asc" : "desc", forKey: Key("order"))
        }
    }

    /// the flat date bounds. a server with local taken ranges compares the
    /// wall clock time with an exclusive end, so it gets utc midnight of the
    /// first day and of the day after the last, like gallery's mobile app.
    /// older servers compare instants and get the picked ones.
    private var takenRange: (after: String?, before: String?) {
        Self.takenRange(of: filter, localTakenRange: localTakenRange)
    }

    static func takenRange(of filter: SearchFilter, localTakenRange: Bool) -> (after: String?, before: String?) {
        guard localTakenRange else {
            return (filter.takenAfter?.ISO8601Format(), filter.takenBefore?.ISO8601Format())
        }
        return (
            filter.takenAfter.flatMap { Self.utcMidnight(ofLocalDay: $0, addingDays: 0) },
            filter.takenBefore.flatMap { Self.utcMidnight(ofLocalDay: $0, addingDays: 1) }
        )
    }

    private static func utcMidnight(ofLocalDay date: Date, addingDays days: Int) -> String? {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let midnight = utc.date(from: day),
              let shifted = utc.date(byAdding: .day, value: days, to: midnight)
        else { return nil }
        return shifted.ISO8601Format()
    }

    // MARK: - search v2

    /// v2 no longer hides trash by default, and its implicit visibility also
    /// lets hidden live-photo halves through, so both are always explicit.
    var v2Filter: [String: SearchJSON] {
        var tree: [String: SearchJSON] = [
            "visibility": .eq(.string(filter.isArchive ? "archive" : "timeline")),
            "trashedAt": .eq(.null),
        ]

        if !filter.usesSmartSearch, !filter.text.isEmpty {
            switch filter.textType {
            case .context, .filename: tree["originalFileName"] = .object(["like": .string(filter.text)])
            case .description: tree["description"] = .object(["like": .string(filter.text)])
            case .path: tree["originalPath"] = .object(["like": .string(filter.text)])
            case .ocr: tree["ocr"] = .object(["matches": .string(filter.text)])
            }
        }

        let facets: [(String, SearchFilter.Facet?)] = [
            ("country", filter.country), ("state", filter.state), ("city", filter.city),
            ("make", filter.make), ("model", filter.model), ("lensModel", filter.lensModel),
        ]
        for (key, facet) in facets {
            guard let facet else { continue }
            tree[key] = .eq(facet.wireValue.map(SearchJSON.string) ?? .null)
        }

        var takenAt: [String: SearchJSON] = [:]
        if let takenAfter = filter.takenAfter { takenAt["gte"] = .string(takenAfter.ISO8601Format()) }
        if let takenBefore = filter.takenBefore { takenAt["lte"] = .string(takenBefore.ISO8601Format()) }
        if !takenAt.isEmpty { tree["takenAt"] = .object(takenAt) }

        switch filter.rating {
        case .any: break
        case .unrated: tree["rating"] = .eq(.null)
        case .stars(let count): tree["rating"] = .eq(.int(count))
        }

        if filter.isFavorite { tree["isFavorite"] = .eq(.bool(true)) }
        if filter.isMotion { tree["isMotion"] = .eq(.bool(true)) }
        if filter.notInAlbum { tree["hasAlbums"] = .eq(.bool(false)) }

        if !filter.people.isEmpty {
            tree["personIds"] = .object([filter.peopleMatch.rawValue: .strings(filter.people.map(\.id))])
        }
        if filter.isUntagged {
            tree["hasTags"] = .eq(.bool(false))
        } else if !filter.tags.isEmpty {
            tree["tagIds"] = .object(["all": .strings(filter.tags.map(\.id))])
        }

        if let type = filter.mediaType.wireValue {
            tree["type"] = .eq(.string(type))
        }
        return tree
    }

    /// local date so the order agrees with the day sections results render in.
    private var v2Order: SearchJSON {
        let order = filter.effectiveSortOrder
        let field = switch order {
        case .largest: "fileSizeInBytes"
        case .highestRated: "rating"
        default: "localDateTime"
        }
        return .object([
            "field": .string(field),
            "direction": .string(order == .oldest ? "asc" : "desc"),
        ])
    }
}
