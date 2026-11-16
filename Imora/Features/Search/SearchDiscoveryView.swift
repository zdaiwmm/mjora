import Foundation
import SwiftUI

/// people and places shown before anything is typed, loaded once per session,
/// plus the names typed text is matched against.
@MainActor
@Observable
final class SearchDiscoveryModel {
    private(set) var people: [Person] = []
    private(set) var places: [ExploreItem] = []
    private(set) var hasLoaded = false
    /// every visible named person, for matching typed text.
    private(set) var namedPeople: [Person] = []
    private(set) var cities: [String] = []
    private(set) var tags: [Tag] = []
    @ObservationIgnored private weak var loadedClient: ImoraClient?
    @ObservationIgnored private weak var suggestionClient: ImoraClient?

    func load(client: ImoraClient, includesPeople: Bool) async {
        guard loadedClient !== client else { return }
        loadedClient = client
        async let placesTask = try? client.explorePlaces()
        if includesPeople {
            // the shared people cache paints instantly on a slow server.
            if people.isEmpty, let account = client.offlineAccountKey {
                let cached = await Task.detached(priority: .userInitiated) {
                    OfflineCache.value([Person].self, key: "people", account: account)
                }.value
                if let cached, people.isEmpty { adopt(cached) }
            }
            if let response = try? await client.people() {
                adopt(response.people)
            }
        }
        if let explore = await placesTask {
            places = explore.first { $0.fieldName == "exifInfo.city" }?.items ?? []
        }
        hasLoaded = true
    }

    /// every city and tag, fetched the first time something is typed.
    func loadSuggestionSources(client: ImoraClient, includesTags: Bool) async {
        guard suggestionClient !== client else { return }
        suggestionClient = client
        async let citiesTask = try? client.searchSuggestions(type: "city")
        if includesTags, let fetched = try? await client.tags() {
            tags = fetched
        }
        cities = (await citiesTask ?? []).compactMap { facet in
            if case .value(let city) = facet { return city }
            return nil
        }
    }

    /// people, places and tags whose name contains the text, prefix matches
    /// first, leaving out what the filter already holds.
    func suggestions(for text: String, excluding filter: SearchFilter, limit: Int = 6) -> [SearchSuggestion] {
        guard text.count >= 2 else { return [] }
        func rank(_ name: String) -> Int? {
            guard name.localizedStandardContains(text) else { return nil }
            return name.lowercased().hasPrefix(text.lowercased()) ? 0 : 1
        }
        let chosenPeople = Set(filter.people.map(\.id))
        let chosenTags = Set(filter.tags.map(\.id))
        var matches: [(rank: Int, suggestion: SearchSuggestion)] = []
        for person in namedPeople where !chosenPeople.contains(person.id) {
            if let rank = rank(person.name) { matches.append((rank, .person(person))) }
        }
        let places = Set(cities + self.places.map(\.value))
        for city in places.sorted() where filter.city != .value(city) {
            if let rank = rank(city) { matches.append((rank, .place(city))) }
        }
        for tag in tags where !chosenTags.contains(tag.id) {
            if let rank = rank(tag.name) { matches.append((rank, .tag(tag))) }
        }
        return matches.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(limit)
            .map(\.element.suggestion)
    }

    private func adopt(_ all: [Person]) {
        let visible = all.filter { $0.isHidden != true }
        namedPeople = visible.filter { !$0.name.isEmpty }
        people = Self.featured(visible)
    }

    /// favorites first, then named people, the way the web orders its picker.
    private static func featured(_ visible: [Person]) -> [Person] {
        let named = visible.filter { !$0.name.isEmpty }
        let pool = named.isEmpty ? visible : named
        return pool.enumerated().sorted { lhs, rhs in
            let l = lhs.element.isFavorite == true
            let r = rhs.element.isFavorite == true
            return l != r ? l : lhs.offset < rhs.offset
        }.map(\.element).prefix(20).map(\.self)
    }
}

/// something typed text can turn into a filter.
nonisolated enum SearchSuggestion: Identifiable, Hashable {
    case person(Person)
    case place(String)
    case tag(Tag)

    var id: String {
        switch self {
        case .person(let person): "person:\(person.id)"
        case .place(let city): "place:\(city)"
        case .tag(let tag): "tag:\(tag.id)"
        }
    }

    var title: String {
        switch self {
        case .person(let person): person.name
        case .place(let city): PhotoPlaceName.localized(city)
        case .tag(let tag): tag.value
        }
    }

    var kind: String {
        switch self {
        case .person: String(localized: "Person")
        case .place: String(localized: "Place")
        case .tag: String(localized: "Tag")
        }
    }

    func apply(to filter: inout SearchFilter) {
        switch self {
        case .person(let person): filter.people.append(person)
        case .place(let city): filter.city = .value(city)
        case .tag(let tag):
            filter.isUntagged = false
            filter.tags.append(tag)
        }
    }
}

/// typed text offered as filters, the way photos turns a name into a token.
struct SearchSuggestionsStrip: View {
    let suggestions: [SearchSuggestion]
    let onPick: (SearchSuggestion) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            icon(suggestion)
                            Text(suggestion.title)
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .frame(minHeight: 40)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .background(.fill.quaternary, in: .capsule)
                    .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
                    .accessibilityLabel("\(suggestion.kind): \(suggestion.title)")
                    .accessibilityHint("Adds it as a filter.")
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("search-suggestions")
    }

    @ViewBuilder private func icon(_ suggestion: SearchSuggestion) -> some View {
        switch suggestion {
        case .person(let person):
            PersonPortrait(person: person, size: 28)
        case .place:
            symbol("mappin", tint: .red)
        case .tag:
            symbol("tag.fill", tint: .orange)
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

nonisolated enum SearchDiscoveryLink: Hashable {
    case people
    case places
    case recentlyAdded
}

/// shortcuts that apply a filter in place, so they combine with a query.
nonisolated enum SearchCategory: String, CaseIterable, Identifiable {
    case videos, favorites, notInAlbum, thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: String(localized: "Videos")
        case .favorites: String(localized: "Favorites")
        case .notInAlbum: String(localized: "Not in an Album")
        case .thisYear: String(localized: "This Year")
        }
    }

    var symbol: String {
        switch self {
        case .videos: "play.rectangle.fill"
        case .favorites: "heart.fill"
        case .notInAlbum: "rectangle.stack.badge.minus"
        case .thisYear: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .videos: .blue
        case .favorites: .pink
        case .notInAlbum: .orange
        case .thisYear: .green
        }
    }

    func apply(to filter: inout SearchFilter) {
        switch self {
        case .videos: filter.mediaType = .video
        case .favorites: filter.isFavorite = true
        case .notInAlbum: filter.notInAlbum = true
        case .thisYear:
            let calendar = Calendar.current
            let year = calendar.component(.year, from: Date())
            filter.takenAfter = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            filter.takenBefore = Date()
            filter.dateLabel = String(localized: "This Year")
            filter.dateSelectionID = "thisYear"
        }
    }
}

struct SearchDiscoveryView: View {
    @Environment(SessionStore.self) private var session
    let model: SearchDiscoveryModel
    let recents: RecentSearches
    let onRecent: (RecentSearch) -> Void
    let onPerson: (Person) -> Void
    let onPlace: (String) -> Void
    let onCategory: (SearchCategory) -> Void

    private var showsPeople: Bool { session.preferences?.peopleEnabled != false }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !recents.items.isEmpty {
                recentSection
            }
            if showsPeople, !model.people.isEmpty {
                peopleSection
            }
            if !model.places.isEmpty {
                placesSection
            }
            browseSection
        }
        .padding(.vertical)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: recents.items)
    }

    // MARK: - sections

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
                .font(.subheadline)
        }
        .padding(.horizontal)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(String(localized: "Recent Searches")) {
                Button("Clear") { recents.clear() }
                    .accessibilityLabel("Clear Recent Searches")
                    .accessibilityIdentifier("recent-searches-clear")
            }
            VStack(spacing: 0) {
                ForEach(recents.items.prefix(5)) { entry in
                    Button {
                        onRecent(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(entry.text)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: entry.type.symbol)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel(entry.type.title)
                        }
                        .padding(.horizontal)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", systemImage: "xmark", role: .destructive) {
                            recents.remove(entry)
                        }
                    }
                    .accessibilityAction(named: "Remove") { recents.remove(entry) }
                }
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(String(localized: "People")) {
                NavigationLink("See All", value: SearchDiscoveryLink.people)
                    .accessibilityIdentifier("discovery-people-all")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.people) { person in
                        Button {
                            onPerson(person)
                        } label: {
                            VStack(spacing: 8) {
                                PersonPortrait(person: person, size: 72)
                                Text(person.name.isEmpty ? String(localized: "No Name") : person.name)
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.name.isEmpty ? String(localized: "Unnamed person") : person.name)
                        .accessibilityHint("Searches for photos of this person.")
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(String(localized: "Places")) {
                NavigationLink("See All", value: SearchDiscoveryLink.places)
                    .accessibilityIdentifier("discovery-places-all")
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(model.places, id: \.value) { place in
                        Button {
                            onPlace(place.value)
                        } label: {
                            placeCard(place)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PhotoPlaceName.localized(place.value))
                        .accessibilityHint("Searches for photos taken here.")
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    /// the image is laid into a fixed frame so a wide photo cannot widen the
    /// card and push the city name out of view.
    private func placeCard(_ place: ExploreItem) -> some View {
        Rectangle()
            .fill(.fill.tertiary)
            .frame(width: 140, height: 140)
            .overlay {
                if let client = session.client {
                    RemoteImage(url: client.thumbnailURL(assetID: place.data.id, cacheKey: place.data.thumbhash), targetPixelSize: 400,
                                thumbhash: place.data.thumbhash)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(PhotoPlaceName.localized(place.value))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(10)
            }
            .clipShape(.rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(String(localized: "Browse")) { EmptyView() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                NavigationLink(value: SearchDiscoveryLink.recentlyAdded) {
                    tile(title: String(localized: "Recently Added"), symbol: "tray.and.arrow.down.fill", tint: .indigo)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quick-link-recentlyAdded")
                ForEach(SearchCategory.allCases) { category in
                    Button {
                        onCategory(category)
                    } label: {
                        tile(title: category.title, symbol: category.symbol, tint: category.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("quick-link-\(category.rawValue)")
                }
            }
            .padding(.horizontal)
        }
    }

    private func tile(title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }
}
