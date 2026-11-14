import Foundation
import Observation
import SwiftUI

/// one `POST /search/options` body: the filter in the flat search shape and
/// the lists to count. each list ignores its own filter, so its counts say
/// what switching to an option would leave.
nonisolated struct SearchOptionsRequest: Encodable, Equatable, Sendable {
    enum Dimension: String, CaseIterable, Sendable {
        case availability, total, time, people, tags, places, cameras, ratings, mediaTypes
    }

    let filter: SearchFilter
    let dimensions: Set<Dimension>
    let localTakenRange: Bool

    /// nil when the endpoint cannot express the filter: a path query, or any
    /// of several people, which it reads as all of them.
    init?(filter: SearchFilter, dimensions: Set<Dimension>, localTakenRange: Bool) {
        if !filter.usesSmartSearch, !filter.text.isEmpty, filter.textType == .path { return nil }
        if filter.matchesAnyPerson { return nil }
        var normalized = filter
        normalized.sortOrder = .relevance
        normalized.dateLabel = nil
        normalized.dateSelectionID = nil
        self.filter = normalized
        self.dimensions = dimensions
        self.localTakenRange = localTakenRange
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
        } else if !filter.text.isEmpty {
            let key = switch filter.textType {
            case .description: "description"
            case .ocr: "ocr"
            case .context, .filename, .path: "originalFileName"
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

        let taken = SearchRequest.takenRange(of: filter, localTakenRange: localTakenRange)
        try container.encodeIfPresent(taken.after, forKey: Key("takenAfter"))
        try container.encodeIfPresent(taken.before, forKey: Key("takenBefore"))
        try container.encode(filter.isArchive ? "archive" : "timeline", forKey: Key("visibility"))

        switch filter.rating {
        case .any: break
        case .unrated: try container.encodeNil(forKey: Key("rating"))
        case .stars(let count): try container.encode(count, forKey: Key("rating"))
        }
        if filter.isFavorite { try container.encode(true, forKey: Key("isFavorite")) }
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
        let ordered = Dimension.allCases.filter(dimensions.contains).map(\.rawValue)
        try container.encode(ordered, forKey: Key("dimensions"))
    }
}

/// `SearchOptionsResponseDto`, only the requested parts present.
nonisolated struct SearchOptionsResponse: Decodable, Sendable {
    struct Availability: Decodable, Equatable, Sendable {
        var hasAssets: Bool?
        var hasPeople: Bool?
        var hasTags: Bool?
        var hasPlaces: Bool?
        var hasCameras: Bool?
        var hasRatings: Bool?
        var hasImages: Bool?
        var hasVideos: Bool?
        var hasFavorites: Bool?
        var hasAssetsInAlbum: Bool?
        var hasAssetsNotInAlbum: Bool?
    }

    struct Month: Decodable, Sendable {
        let timeBucket: String
        let count: Int
    }

    struct PersonCount: Decodable, Sendable {
        let id: String?
        let filterId: String?
        let count: Int?
    }

    struct TagCount: Decodable, Sendable {
        let id: String
        let count: Int?
    }

    struct CityCount: Decodable, Sendable {
        let city: String
        let count: Int?
    }

    struct CountryCount: Decodable, Sendable {
        let country: String
        let count: Int?
        let cities: [CityCount]?
    }

    struct ModelCount: Decodable, Sendable {
        let model: String
        let count: Int?
    }

    struct MakeCount: Decodable, Sendable {
        let make: String
        let count: Int?
        let models: [ModelCount]?
    }

    struct RatingCount: Decodable, Sendable {
        let rating: Int
        let count: Int
    }

    struct MediaTypeCount: Decodable, Sendable {
        let type: String
        let count: Int
    }

    let stale: Bool?
    let availability: Availability?
    let total: Int?
    let timeBuckets: [Month]?
    let people: [PersonCount]?
    let tags: [TagCount]?
    let countries: [CountryCount]?
    let cameraMakes: [MakeCount]?
    let ratings: [RatingCount]?
    let mediaTypes: [MediaTypeCount]?
}

/// the counts the filter sheets and chips read. a missing list means no
/// counts, so its options show as they always did. an option a loaded list
/// leaves out counts zero.
nonisolated struct SearchCounts: Equatable, Sendable {
    var availability: SearchOptionsResponse.Availability?
    var total: Int?
    /// by year, then month.
    var months: [Int: [Int: Int]]?
    var people: [String: Int]?
    var tags: [String: Int]?
    var countries: [String: Int]?
    var cities: [String: [String: Int]]?
    var makes: [String: Int]?
    var models: [String: [String: Int]]?
    var ratings: [Int: Int]?
    var mediaTypes: [String: Int]?

    init(_ response: SearchOptionsResponse) {
        availability = response.availability
        total = response.total
        months = response.timeBuckets.map { buckets in
            var months: [Int: [Int: Int]] = [:]
            for bucket in buckets {
                let parts = bucket.timeBucket.prefix(7).split(separator: "-")
                guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { continue }
                months[year, default: [:]][month, default: 0] += bucket.count
            }
            return months
        }
        people = response.people.map { people in
            var counts: [String: Int] = [:]
            for person in people {
                for id in [person.filterId, person.id].compactMap(\.self) {
                    counts[id] = person.count ?? 0
                }
            }
            return counts
        }
        tags = response.tags.map { Dictionary($0.map { ($0.id, $0.count ?? 0) }, uniquingKeysWith: max) }
        countries = response.countries.map { Dictionary($0.map { ($0.country, $0.count ?? 0) }, uniquingKeysWith: +) }
        cities = response.countries.map { countries in
            Dictionary(countries.map { country in
                (country.country, Dictionary((country.cities ?? []).map { ($0.city, $0.count ?? 0) }, uniquingKeysWith: +))
            }, uniquingKeysWith: { first, _ in first })
        }
        makes = response.cameraMakes.map { Dictionary($0.map { ($0.make, $0.count ?? 0) }, uniquingKeysWith: +) }
        models = response.cameraMakes.map { makes in
            Dictionary(makes.map { make in
                (make.make, Dictionary((make.models ?? []).map { ($0.model, $0.count ?? 0) }, uniquingKeysWith: +))
            }, uniquingKeysWith: { first, _ in first })
        }
        ratings = response.ratings.map { Dictionary($0.map { ($0.rating, $0.count) }, uniquingKeysWith: +) }
        mediaTypes = response.mediaTypes.map { Dictionary($0.map { ($0.type, $0.count) }, uniquingKeysWith: +) }
    }

    /// unnamed people are left out of the list, so only named ones count zero.
    /// nil when no listed id matches the people shown, so a server keying
    /// people differently never dims everyone.
    func person(_ person: Person, among shown: [Person]) -> Int? {
        guard let people, shown.contains(where: { people[$0.id] != nil }) else { return nil }
        return people[person.id] ?? (person.name.isEmpty ? nil : 0)
    }

    func tag(_ id: String) -> Int? {
        tags.map { $0[id] ?? 0 }
    }

    func country(_ facet: SearchFilter.Facet) -> Int? {
        guard case .value(let name) = facet else { return nil }
        return countries.map { $0[name] ?? 0 }
    }

    /// within the picked country, across all of them otherwise.
    func city(_ facet: SearchFilter.Facet, in country: SearchFilter.Facet?) -> Int? {
        guard case .value(let name) = facet, let cities else { return nil }
        if case .value(let country) = country { return cities[country]?[name] ?? 0 }
        return cities.values.reduce(0) { $0 + ($1[name] ?? 0) }
    }

    func make(_ facet: SearchFilter.Facet) -> Int? {
        guard case .value(let name) = facet else { return nil }
        return makes.map { $0[name] ?? 0 }
    }

    func model(_ facet: SearchFilter.Facet, of make: SearchFilter.Facet?) -> Int? {
        guard case .value(let name) = facet, let models else { return nil }
        if case .value(let make) = make { return models[make]?[name] ?? 0 }
        return models.values.reduce(0) { $0 + ($1[name] ?? 0) }
    }

    /// a rating filter is a minimum, so a star counts what is rated that or more.
    func rating(_ rating: SearchFilter.Rating) -> Int? {
        guard case .stars(let stars) = rating, let ratings else { return nil }
        return ratings.reduce(0) { $0 + ($1.key >= stars ? $1.value : 0) }
    }

    func mediaType(_ type: SearchFilter.MediaType) -> Int? {
        guard let mediaTypes else { return nil }
        guard let wire = type.wireValue else { return mediaTypes.values.reduce(0, +) }
        return mediaTypes[wire] ?? 0
    }

    func year(_ year: Int) -> Int? {
        months.map { $0[year]?.values.reduce(0, +) ?? 0 }
    }

    /// whether the list behind a chip has anything for the whole scope.
    func isAvailable(_ sheet: FilterSheet) -> Bool? {
        guard let availability else { return nil }
        return switch sheet {
        case .people: availability.hasPeople
        case .date: availability.hasAssets
        case .location: availability.hasPlaces
        case .tags: availability.hasTags
        case .camera: availability.hasCameras
        case .rating: availability.hasRatings
        case .mediaType:
            availability.hasImages.flatMap { images in availability.hasVideos.map { images || $0 } }
        case .display: nil
        }
    }
}

/// the counts of the latest filter, debounced and dropped when superseded.
/// every older answer stays on screen until the next one lands, so options
/// never flicker while picking.
@MainActor
@Observable
final class SearchOptionsModel {
    private(set) var counts: SearchCounts?
    @ObservationIgnored private var loaded: SearchOptionsRequest?

    private static let debounce = Duration.milliseconds(150)
    private static let staleRetry = Duration.seconds(2)
    private static let staleRetryLimit = Duration.seconds(30)

    /// the total only while it belongs to this filter.
    func total(for filter: SearchFilter, localTakenRange: Bool) -> Int? {
        guard let loaded, loaded.dimensions.contains(.total),
              loaded.filter == SearchOptionsRequest(filter: filter, dimensions: [], localTakenRange: localTakenRange)?.filter
        else { return nil }
        return counts?.total
    }

    /// run from `task(id:)`, which cancels it when the request changes. a
    /// stale answer from the server's cache is asked again a little later.
    func load(_ request: SearchOptionsRequest?, client: ImoraClient?) async {
        guard let request, let client else {
            counts = nil
            loaded = nil
            return
        }
        guard request != loaded else { return }
        do { try await Task.sleep(for: Self.debounce) } catch { return }
        var retry = Self.staleRetry
        while true {
            let response: SearchOptionsResponse
            do {
                response = try await client.searchOptions(request)
            } catch {
                guard !Task.isCancelled else { return }
                counts = nil
                loaded = nil
                return
            }
            guard !Task.isCancelled else { return }
            counts = SearchCounts(response)
            loaded = request
            guard response.stale == true, retry <= Self.staleRetryLimit else { return }
            do { try await Task.sleep(for: retry) } catch { return }
            retry *= 2
        }
    }
}

private struct SearchCountsModifier: ViewModifier {
    @Environment(SessionStore.self) private var session
    let model: SearchOptionsModel
    let filter: SearchFilter
    let dimensions: Set<SearchOptionsRequest.Dimension>

    private var request: SearchOptionsRequest? {
        let capabilities = session.capabilities
        guard capabilities.supportsSearchOptions else { return nil }
        return SearchOptionsRequest(filter: filter, dimensions: dimensions,
                                    localTakenRange: capabilities.supportsLocalTakenRange)
    }

    func body(content: Content) -> some View {
        content.task(id: request) {
            await model.load(request, client: session.client)
        }
    }
}

extension View {
    /// keeps `model` on the counts of `filter`, on servers with `POST /search/options`.
    func searchCounts(_ model: SearchOptionsModel, filter: SearchFilter,
                      dimensions: Set<SearchOptionsRequest.Dimension>) -> some View {
        modifier(SearchCountsModifier(model: model, filter: filter, dimensions: dimensions))
    }
}

/// a count beside an option, quieter than its label.
struct SearchCountLabel: View {
    let count: Int?

    var body: some View {
        if let count {
            Text(count.formatted())
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

extension View {
    /// an option that would return nothing stays pickable but steps back.
    func dimmedWhenEmpty(_ count: Int?) -> some View {
        opacity(count == 0 ? 0.4 : 1)
    }
}
