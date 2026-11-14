import Foundation
import CoreLocation
import SwiftUI

struct SearchTab: View {
    @Environment(SessionStore.self) private var session
    @Binding var query: String
    @Binding var searchScope: SearchFilter.TextType
    var submitRequest = 0
    /// moves focus in or out of the tab's search field, which the shell owns.
    let setSearchFocus: (Bool) -> Void

    @State private var model = SearchModel()
    @State private var discovery = SearchDiscoveryModel()
    @State private var recents = RecentSearches()
    @State private var activeSheet: FilterSheet?
    @State private var liveCounts = SearchOptionsModel()

    private var availableSearchModes: [SearchFilter.TextType] {
        SearchFilter.TextType.allCases.filter { mode in
            switch mode {
            case .context: session.features?.smartSearch != false
            case .ocr: session.features?.ocr == true
            case .filename, .description, .path: true
            }
        }
    }

    private var availableFilters: [FilterSheet] {
        FilterSheet.allCases.filter { category in
            switch category {
            case .people: session.preferences?.peopleEnabled != false
            case .tags: session.showsTags
            case .rating: session.preferences?.ratingsEnabled == true
            default: true
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            searchContent
        }
    }

    private var searchContent: some View {
        searchLayout
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(model.assets.isEmpty ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(.background, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .task(id: query) {
                if trimmedQuery.isEmpty {
                    submit()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                submit()
            }
            .onChange(of: searchScope) {
                submit()
                if trimmedQuery.isEmpty { setSearchFocus(true) }
            }
            .onChange(of: availableSearchModes, initial: true) {
                if !availableSearchModes.contains(searchScope), let first = availableSearchModes.first {
                    searchScope = first
                }
            }
            .task(id: trimmedQuery.isEmpty) {
                guard !trimmedQuery.isEmpty, let client = session.client else { return }
                await discovery.loadSuggestionSources(client: client,
                                                      includesTags: session.showsTags)
            }
            // a server without structured search, immich below 3.2, gallery or
            // imora, cannot match any person or sort by size or rating, so
            // those choices fall back to what it can.
            .onChange(of: session.capabilities.supportsStructuredSearch) { _, supportsV2 in
                guard supportsV2 == false else { return }
                applyFilter { next in
                    next.peopleMatch = .all
                    if next.sortOrder.requiresV2 { next.sortOrder = .relevance }
                }
            }
            .onChange(of: submitRequest) {
                recents.record(trimmedQuery, type: searchScope)
                submit()
            }
            .searchCounts(liveCounts, filter: model.filter, dimensions: [.availability, .total])
            .task(id: session.client == nil) {
                recents.load(account: session.client?.offlineAccountKey)
                guard let client = session.client else { return }
                model.attach(client)
                await discovery.load(client: client, includesPeople: session.preferences?.peopleEnabled != false)
            }
            .sheet(item: $activeSheet) { sheet in
                filterSheet(for: sheet)
                    .presentationDetents(sheet.prefersLargeSheet ? [.large] : [.medium, .large])
            }
            .navigationDestination(for: SearchDiscoveryLink.self) { link in
                discoveryScreen(link)
                    .toolbarVisibility(.visible, for: .navigationBar)
            }
            .navigationDestination(for: Person.self) { person in
                PersonScreen(person: person)
                    .toolbarVisibility(.visible, for: .navigationBar)
            }
            .navigationDestination(for: PlaceLink.self) { place in
                PlaceScreen(city: place.city, coordinate: place.coordinate)
                    .toolbarVisibility(.visible, for: .navigationBar)
            }
    }

    private var searchLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                searchModeMenu
                    .padding(.leading)
                FilterChipsRow(filter: model.filter, availableFilters: availableFilters,
                               counts: liveCounts.counts, activeSheet: $activeSheet) { category in
                    applyFilter { category.clear(from: &$0) }
                } onClearAll: {
                    clearFilters()
                }
            }
            .padding(.vertical, 6)
            .background(.background)
            if !suggestions.isEmpty {
                SearchSuggestionsStrip(suggestions: suggestions) { suggestion in
                    pick(clearingText: true) { suggestion.apply(to: &$0) }
                }
                .padding(.bottom, 8)
                .background(.background)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.hasActiveSearch {
                SearchResultsTimeline(search: model, onClearFilters: clearFiltersAction,
                                      total: liveCounts.total(
                                          for: model.filter,
                                          localTakenRange: session.capabilities.supportsLocalTakenRange
                                      ))
            } else {
                ScrollView {
                    SearchDiscoveryView(
                        model: discovery,
                        recents: recents,
                        onRecent: runRecent,
                        onPerson: { person in
                            pick { next in
                                if !next.people.contains(where: { $0.id == person.id }) { next.people.append(person) }
                            }
                        },
                        onPlace: { city in pick { $0.city = .value(city) } },
                        onCategory: { category in pick { category.apply(to: &$0) } }
                    )
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectHidden()
                .refreshable {
                    guard let client = session.client else { return }
                    let fresh = SearchDiscoveryModel()
                    await fresh.load(client: client, includesPeople: session.preferences?.peopleEnabled != false)
                    discovery = fresh
                }
            }
        }
        .animation(.snappy, value: suggestions.isEmpty)
    }

    private var clearFiltersAction: (() -> Void)? {
        guard model.filter.hasFilters else { return nil }
        return { clearFilters() }
    }

    private var searchModeMenu: some View {
        Menu {
            Picker("Search Type", selection: $searchScope) {
                ForEach(availableSearchModes) { mode in
                    Label {
                        Text(mode.title)
                        Text(mode.subtitle)
                    } icon: {
                        Image(systemName: mode.symbol)
                    }
                    .tag(mode)
                }
            }
        } label: {
            Image(systemName: searchScope.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Search Type")
        .accessibilityValue(searchScope.title)
        .accessibilityIdentifier("search-mode")
    }

    /// people, places and tags matching the typed text, offered as filters.
    private var suggestions: [SearchSuggestion] {
        guard !trimmedQuery.isEmpty else { return [] }
        return discovery.suggestions(for: trimmedQuery, excluding: model.filter).filter { suggestion in
            switch suggestion {
            case .person: session.preferences?.peopleEnabled != false
            case .tag: session.showsTags
            case .place: true
            }
        }
    }

    // MARK: - actions

    private var languageTag: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        guard let region = locale.region?.identifier else { return language }
        return "\(language)-\(region)"
    }

    private func submit() {
        applyFilter { $0.setText(trimmedQuery, type: searchScope) }
    }

    private func runRecent(_ entry: RecentSearch) {
        let type = availableSearchModes.contains(entry.type) ? entry.type : searchScope
        applyFilter { $0.setText(entry.text, type: type) }
        query = entry.text
        searchScope = type
        recents.record(entry.text, type: type)
        setSearchFocus(false)
    }

    /// applies a suggestion or discovery shortcut as a filter chip.
    private func pick(clearingText: Bool = false, _ mutate: (inout SearchFilter) -> Void) {
        if clearingText { query = "" }
        applyFilter { next in
            if clearingText { next.setText("", type: searchScope) }
            mutate(&next)
        }
        setSearchFocus(false)
    }

    private func clearFilters() {
        applyFilter { next in
            for category in FilterSheet.allCases { category.clear(from: &next) }
        }
    }

    private func applyFilter(_ mutate: (inout SearchFilter) -> Void) {
        var next = model.filter
        mutate(&next)
        next.language = languageTag
        model.apply(next)
    }

    @ViewBuilder private func filterSheet(for sheet: FilterSheet) -> some View {
        switch sheet {
        case .people:
            PeoplePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .location:
            LocationPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .camera:
            CameraPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .date:
            DatePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .mediaType:
            MediaTypePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .rating:
            RatingPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .display:
            DisplayOptionsSheet(filter: model.filter, onApply: applySheetFilter)
        case .tags:
            TagsPickerSheet(filter: model.filter, onApply: applySheetFilter)
        }
    }

    private func applySheetFilter(_ newFilter: SearchFilter) {
        applyFilter { $0 = newFilter }
    }

    @ViewBuilder private func discoveryScreen(_ link: SearchDiscoveryLink) -> some View {
        switch link {
        case .people:
            PeopleScreen()
        case .places:
            PlacesScreen()
        case .recentlyAdded:
            TimelineScreen(
                title: String(localized: "Recently Added"),
                filter: TimelineFilter(orderBy: "createdAt"),
                emptyIcon: "tray.and.arrow.down",
                emptyMessage: String(localized: "No photos yet"),
                showsLargeTitle: false
            )
        }
    }
}

private extension FilterSheet {
    var prefersLargeSheet: Bool {
        switch self {
        case .people, .tags, .location, .camera: true
        default: false
        }
    }
}

/// paged searches use the shared timeline for canned filters and places.
struct SearchResultsScreen: View {
    @Environment(SessionStore.self) private var session
    let title: String
    let baseFilter: SearchFilter
    var emptyIcon = "magnifyingglass"
    var emptyMessage = String(localized: "No results")

    @State private var model = SearchModel()

    var body: some View {
        SearchResultsTimeline(search: model, title: title)
            .task(id: session.client == nil) {
                if let client = session.client { model.attach(client) }
                model.apply(baseFilter)
            }
    }
}

struct PlaceScreen: View {
    @Environment(SessionStore.self) private var session
    let city: String
    var coordinate: CLLocationCoordinate2D?

    @State private var model = SearchModel()
    @State private var showMap = false

    var body: some View {
        SearchResultsTimeline(search: model, title: city)
            .toolbar {
                if coordinate != nil, session.features?.map != false {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Map", systemImage: "map") { showMap = true }
                            .accessibilityIdentifier("place-map")
                    }
                }
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(initialCoordinate: coordinate)
            }
            .task(id: session.client == nil) {
                if let client = session.client { model.attach(client) }
                var filter = SearchFilter()
                filter.city = .value(city)
                model.apply(filter)
            }
    }
}

nonisolated struct PlaceLink: Hashable {
    let city: String
    var latitude: Double?
    var longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
