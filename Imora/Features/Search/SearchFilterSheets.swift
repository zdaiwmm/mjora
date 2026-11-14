import Foundation
import SwiftUI

nonisolated enum FilterSheet: String, CaseIterable, Identifiable {
    case people, date, location, tags, mediaType, camera, rating, display
    var id: String { rawValue }
}

struct FilterChipsRow: View {
    let filter: SearchFilter
    let availableFilters: [FilterSheet]
    /// dims the chips whose list has nothing in the current scope.
    let counts: SearchCounts?
    @Binding var activeSheet: FilterSheet?
    let onRemove: (FilterSheet) -> Void
    let onClearAll: () -> Void

    /// active filters lead so they stay in view on a narrow screen.
    private var visibleFilters: [FilterSheet] {
        let shown = FilterSheet.allCases.filter {
            availableFilters.contains($0) || $0.summary(for: filter) != nil
        }
        return shown.filter { $0.summary(for: filter) != nil } + shown.filter { $0.summary(for: filter) == nil }
    }

    private var activeCount: Int {
        FilterSheet.allCases.count { $0.summary(for: filter) != nil }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(visibleFilters) { category in
                    chip(category)
                }
                if activeCount > 1 {
                    Button("Clear All", action: onClearAll)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("filter-clear-all")
                }
            }
            .padding(.horizontal)
            .animation(.snappy, value: visibleFilters)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("filter-chips")
    }

    private func chip(_ category: FilterSheet) -> some View {
        let summary = category.summary(for: filter)
        return HStack(spacing: 0) {
            Button {
                activeSheet = category
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: summary == nil ? category.symbol : category.activeSymbol)
                        .imageScale(.small)
                    Text(summary ?? category.title)
                        .lineLimit(1)
                    if summary == nil {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, summary == nil ? 14 : 4)
                .frame(minHeight: 36)
                .contentShape(.capsule)
            }
            .accessibilityLabel(category.title)
            .accessibilityValue(summary ?? String(localized: "Any"))
            .accessibilityHint("Opens the \(category.title) filter.")
            .accessibilityIdentifier("filter-chip-\(category.rawValue)")

            if let summary {
                Button {
                    onRemove(category)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Remove \(category.title) filter: \(summary)")
            }
        }
        .font(.subheadline.weight(summary == nil ? .regular : .semibold))
        .foregroundStyle(summary == nil ? Color.primary : Color.accentColor)
        .background(summary == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor.opacity(0.15)),
                    in: .capsule)
        .frame(minHeight: 44)
        .buttonStyle(.plain)
        .opacity(summary == nil && counts?.isAvailable(category) == false ? 0.4 : 1)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

// MARK: - sheet scaffold

/// filters stay unchanged until applied or explicitly cleared.
private struct FilterSheetScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var canClear = true
    /// what applying would show, on servers that count it.
    var total: Int?
    let onClear: () -> Void
    let onApply: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear Filter", role: .destructive) {
                            onClear()
                            dismiss()
                        }
                        .disabled(!canClear)
                        .accessibilityIdentifier("filter-clear")
                    }
                    if let total {
                        ToolbarItem(placement: .status) {
                            Text(total == 1 ? "1 Result" : "\(total.formatted()) Results")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: total)
                                .accessibilityIdentifier("filter-total")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply", role: .confirm) {
                            onApply()
                            dismiss()
                        }
                        .accessibilityIdentifier("filter-apply")
                    }
                }
        }
    }
}

private extension SearchFilter {
    func with(_ mutate: (inout SearchFilter) -> Void) -> SearchFilter {
        var next = self
        mutate(&next)
        return next
    }
}

// MARK: - people

struct PeoplePickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var people: [Person] = []
    /// by id: the people in the filter were captured whenever it was applied,
    /// and any server-side edit since - a rename, a new portrait - makes the
    /// refetched value compare unequal to the one held here.
    @State private var selected: [String] = []
    @State private var match: SearchFilter.Match
    @State private var searchText = ""
    @State private var isLoadingPeople = true
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _selected = State(initialValue: filter.people.map(\.id))
        _match = State(initialValue: filter.peopleMatch)
    }

    private var supportsMatch: Bool { session.capabilities.supportsStructuredSearch }

    /// picks first, then favorites, then named people, like the web panel.
    private var visible: [Person] {
        let chosen = Set(selected)
        let filtered = searchText.isEmpty
            ? people
            : people.filter { $0.name.localizedStandardContains(searchText) }
        return filtered.enumerated().sorted { lhs, rhs in
            let l = (chosen.contains(lhs.element.id), lhs.element.isFavorite == true, !lhs.element.name.isEmpty)
            let r = (chosen.contains(rhs.element.id), rhs.element.isFavorite == true, !rhs.element.name.isEmpty)
            if l != r { return l.0 != r.0 ? l.0 : l.1 != r.1 ? l.1 : l.2 }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var title: String {
        selected.isEmpty ? String(localized: "People") : String(localized: "\(selected.count) Selected")
    }

    private var draft: SearchFilter {
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Dictionary(filter.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picked = selected.compactMap { byID[$0] ?? known[$0] }
        return filter.with {
            $0.people = picked
            $0.peopleMatch = picked.count > 1 && supportsMatch ? match : .all
        }
    }

    var body: some View {
        FilterSheetScaffold(title: title, canClear: !filter.people.isEmpty, total: counts.counts?.total) {
            onApply(filter.with { $0.people = []; $0.peopleMatch = .all })
        } onApply: {
            onApply(draft)
        } content: {
            ScrollView {
                if supportsMatch, selected.count > 1 {
                    Picker("Match", selection: $match) {
                        ForEach(SearchFilter.Match.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityIdentifier("people-match")
                    Text(match == .all
                         ? "Photos with everyone you selected."
                         : "Photos with at least one of the people you selected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(visible) { person in
                        personCell(person)
                    }
                }
                .padding()
                .animation(.snappy, value: selected)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter people")
            .overlay {
                // keyed on the load, not on emptiness - a server with no
                // recognized faces used to spin here forever.
                if isLoadingPeople, people.isEmpty {
                    ProgressView()
                } else if people.isEmpty {
                    ContentUnavailableView("No People", systemImage: "person.2.slash",
                                           description: Text("People appear here once faces are recognized."))
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .task {
                defer { isLoadingPeople = false }
                // the shared people cache paints instantly on a slow server.
                if people.isEmpty, let account = session.client?.offlineAccountKey {
                    let cached = await Task.detached(priority: .userInitiated) {
                        OfflineCache.value([Person].self, key: "people", account: account)
                    }.value
                    if let cached, people.isEmpty {
                        people = cached.filter { !($0.isHidden ?? false) }
                    }
                }
                if let response = try? await session.client?.people() {
                    people = response.people.filter { !($0.isHidden ?? false) }
                }
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.people, .total])
    }

    private func personCell(_ person: Person) -> some View {
        let isSelected = selected.contains(person.id)
        let count = counts.counts?.person(person, among: people)
        return Button {
            if let index = selected.firstIndex(of: person.id) {
                selected.remove(at: index)
            } else {
                selected.append(person.id)
            }
        } label: {
            VStack(spacing: 6) {
                PersonPortrait(person: person, size: 76)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.title3)
                                .background(Circle().fill(.background))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(person.name.isEmpty ? String(localized: "No Name") : person.name)
                    .font(.footnote)
                    .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let count {
                    Text(count.formatted())
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .dimmedWhenEmpty(isSelected ? nil : count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.name.isEmpty ? String(localized: "Unnamed person") : person.name)
        .accessibilityValue(count.map { $0 == 1 ? "1 photo" : "\($0.formatted()) photos" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

/// circular face thumbnail with a monogram while it loads or when missing.
struct PersonPortrait: View {
    @Environment(SessionStore.self) private var session
    let person: Person
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(.fill.tertiary)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.tertiary)
            if let url = session.personThumbnailURL(person) {
                RemoteImage(url: url, targetPixelSize: size * 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

// MARK: - facet lists

/// one exif value picked from a pushed, searchable list, the settings-app
/// way of choosing from hundreds of cities or camera models.
private struct FacetRow: View {
    let title: String
    let stableID: String
    @Binding var selection: SearchFilter.Facet?
    let options: [SearchFilter.Facet]?
    var isEnabled = true
    var count: (SearchFilter.Facet) -> Int? = { _ in nil }

    var body: some View {
        NavigationLink {
            FacetListView(title: title, selection: $selection, options: options, count: count)
        } label: {
            LabeledContent(title) {
                Text(selection?.label ?? String(localized: "Any"))
                    .foregroundStyle(selection == nil ? .secondary : .primary)
            }
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("facet-\(stableID)")
    }
}

private struct FacetListView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var selection: SearchFilter.Facet?
    let options: [SearchFilter.Facet]?
    let count: (SearchFilter.Facet) -> Int?

    @State private var searchText = ""

    private var visible: [SearchFilter.Facet] {
        let all = options ?? []
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.label.localizedStandardContains(searchText) }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                row(String(localized: "Any"), value: nil)
            }
            ForEach(visible, id: \.self) { facet in
                let count = count(facet)
                row(facet.label, value: facet, count: count)
                    .foregroundStyle(facet == .unknown ? .secondary : .primary)
                    .dimmedWhenEmpty(selection == facet ? nil : count)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Search \(title)"))
        .overlay {
            if options == nil {
                ProgressView()
            } else if !searchText.isEmpty, visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func row(_ label: String, value: SearchFilter.Facet?, count: Int? = nil) -> some View {
        Button {
            selection = value
            dismiss()
        } label: {
            HStack {
                Text(label)
                Spacer()
                SearchCountLabel(count: count)
                if selection == value {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

// MARK: - location

struct LocationPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var country: SearchFilter.Facet?
    @State private var state: SearchFilter.Facet?
    @State private var city: SearchFilter.Facet?
    @State private var countries: [SearchFilter.Facet]?
    @State private var states: [SearchFilter.Facet]?
    @State private var cities: [SearchFilter.Facet]?
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _country = State(initialValue: filter.country)
        _state = State(initialValue: filter.state)
        _city = State(initialValue: filter.city)
    }

    var body: some View {
        let draft = filter.with { $0.country = country; $0.state = state; $0.city = city }
        let known = counts.counts
        return FilterSheetScaffold(title: String(localized: "Location"),
                                   canClear: filter.country != nil || filter.state != nil || filter.city != nil,
                                   total: known?.total) {
            onApply(filter.with { $0.country = nil; $0.state = nil; $0.city = nil })
        } onApply: {
            onApply(draft)
        } content: {
            Form {
                Section {
                    FacetRow(title: String(localized: "Country"), stableID: "country", selection: $country, options: countries) { known?.country($0) }
                    FacetRow(title: String(localized: "State"), stableID: "state", selection: $state, options: states)
                    FacetRow(title: String(localized: "City"), stableID: "city", selection: $city, options: cities) { [country] in
                        known?.city($0, in: country)
                    }
                } footer: {
                    Text("Each choice narrows the next. Unknown finds photos without that location detail.")
                }
            }
            .onChange(of: country) { old, new in
                guard old != new else { return }
                state = nil
                city = nil
            }
            .onChange(of: state) { old, new in
                guard old != new else { return }
                city = nil
            }
            .task {
                // the country list never depends on the selection; once.
                guard let client = session.client else { return }
                countries = (try? await client.searchSuggestions(type: "country")) ?? []
            }
            // task id cancellation drops slow answers for an old parent, so
            // country a's cities never land under country b.
            .task(id: [country, state]) {
                guard let client = session.client else { return }
                states = nil
                cities = nil
                async let statesTask = try? client.searchSuggestions(type: "state", country: country)
                async let citiesTask = try? client.searchSuggestions(type: "city", country: country, state: state)
                let states = (await statesTask) ?? []
                let cities = (await citiesTask) ?? []
                guard !Task.isCancelled else { return }
                self.states = states
                self.cities = cities
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.places, .total])
    }
}

// MARK: - camera

struct CameraPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var make: SearchFilter.Facet?
    @State private var model: SearchFilter.Facet?
    @State private var lensModel: SearchFilter.Facet?
    @State private var makes: [SearchFilter.Facet]?
    @State private var models: [SearchFilter.Facet]?
    @State private var lensModels: [SearchFilter.Facet]?
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _make = State(initialValue: filter.make)
        _model = State(initialValue: filter.model)
        _lensModel = State(initialValue: filter.lensModel)
    }

    var body: some View {
        let draft = filter.with { $0.make = make; $0.model = model; $0.lensModel = lensModel }
        let known = counts.counts
        return FilterSheetScaffold(title: String(localized: "Camera"),
                                   canClear: filter.make != nil || filter.model != nil || filter.lensModel != nil,
                                   total: known?.total) {
            onApply(filter.with { $0.make = nil; $0.model = nil; $0.lensModel = nil })
        } onApply: {
            onApply(draft)
        } content: {
            Form {
                Section {
                    FacetRow(title: String(localized: "Make"), stableID: "make", selection: $make, options: makes) { known?.make($0) }
                    FacetRow(title: String(localized: "Model"), stableID: "model", selection: $model, options: models) { [make] in
                        known?.model($0, of: make)
                    }
                    FacetRow(title: String(localized: "Lens"), stableID: "lens", selection: $lensModel, options: lensModels)
                } footer: {
                    Text("Each choice narrows the next.")
                }
            }
            .onChange(of: make) { old, new in
                guard old != new else { return }
                model = nil
                lensModel = nil
            }
            .onChange(of: model) { old, new in
                guard old != new else { return }
                lensModel = nil
            }
            .task {
                guard let client = session.client else { return }
                makes = (try? await client.searchSuggestions(type: "camera-make")) ?? []
            }
            // same stale-response guard as the location sheet.
            .task(id: make) {
                guard let client = session.client else { return }
                models = nil
                let models = (try? await client.searchSuggestions(type: "camera-model", make: make)) ?? []
                guard !Task.isCancelled else { return }
                self.models = models
            }
            .task(id: [make, model]) {
                guard let client = session.client else { return }
                lensModels = nil
                let lenses = (try? await client.searchSuggestions(type: "camera-lens-model", make: make, model: model)) ?? []
                guard !Task.isCancelled else { return }
                lensModels = lenses
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.cameras, .total])
    }
}

// MARK: - date

struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var showCustomRange = false
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var year: Int
    @State private var counts = SearchOptionsModel()

    private enum Preset: String, CaseIterable, Identifiable {
        case last30Days, thisYear, lastYear

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last30Days: String(localized: "Last 30 Days")
            case .thisYear: String(localized: "This Year")
            case .lastYear: String(localized: "Last Year")
            }
        }

        var symbol: String {
            switch self {
            case .last30Days: "calendar.badge.clock"
            case .thisYear: "calendar"
            case .lastYear: "calendar.badge.minus"
            }
        }

        /// the year the preset covers, nil when it is not a whole one.
        func year(now: Date = Date(), calendar: Calendar = .current) -> Int? {
            let currentYear = calendar.component(.year, from: now)
            switch self {
            case .last30Days: return nil
            case .thisYear: return currentYear
            case .lastYear: return currentYear - 1
            }
        }

        func range(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
            let currentYear = calendar.component(.year, from: now)
            switch self {
            case .last30Days:
                let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
                return (start, now)
            case .thisYear:
                return (DatePickerSheet.startOfYear(currentYear, calendar: calendar), now)
            case .lastYear:
                return (DatePickerSheet.startOfYear(currentYear - 1, calendar: calendar),
                        DatePickerSheet.endOfYear(currentYear - 1, calendar: calendar))
            }
        }
    }

    /// only the years with photos once the server counts them.
    private var years: [Int] {
        let all = (1900...Calendar.current.component(.year, from: Date())).reversed()
        guard let known = counts.counts, known.months != nil else { return Array(all) }
        return all.filter { $0 == year || (known.year($0) ?? 0) > 0 }
    }

    private var draft: SearchFilter {
        guard showCustomRange else { return filter }
        let (start, end) = customBounds
        return filter.with { next in
            next.takenAfter = start
            next.takenBefore = end
        }
    }

    private var customBounds: (Date, Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: customStart)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
        return (start, end)
    }

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        let calendar = Calendar.current
        let end = filter.takenBefore ?? Date()
        let start = filter.takenAfter ?? calendar.date(byAdding: .month, value: -1, to: end) ?? end
        _customStart = State(initialValue: min(start, end))
        _customEnd = State(initialValue: end)
        _year = State(initialValue: max(1900, min(calendar.component(.year, from: start),
                                                 calendar.component(.year, from: Date()))))
        let isPreset = Preset.allCases.contains { $0.rawValue == filter.dateSelectionID }
        let isYear = filter.dateSelectionID == "year"
        _showCustomRange = State(initialValue: (filter.takenAfter != nil || filter.takenBefore != nil) && !isPreset && !isYear)
    }

    var body: some View {
        FilterSheetScaffold(title: String(localized: "Date Taken"), canClear: filter.takenAfter != nil || filter.takenBefore != nil,
                            total: counts.counts?.total) {
            onApply(filter.with { next in
                next.takenAfter = nil
                next.takenBefore = nil
                next.dateLabel = nil
                next.dateSelectionID = nil
            })
        } onApply: {
            if showCustomRange {
                applyCustomRange()
            }
        } content: {
            Form {
                Section {
                    ForEach(Preset.allCases) { preset in
                        let count = preset.year().flatMap { counts.counts?.year($0) }
                        Button {
                            let (start, end) = preset.range()
                            apply(start: start, end: end, label: preset.title, selectionID: preset.rawValue)
                        } label: {
                            HStack {
                                Label {
                                    Text(preset.title)
                                        .foregroundStyle(Color.primary)
                                } icon: {
                                    Image(systemName: preset.symbol)
                                        .foregroundStyle(.tint)
                                }
                                Spacer()
                                SearchCountLabel(count: count)
                                if filter.dateSelectionID == preset.rawValue {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .dimmedWhenEmpty(filter.dateSelectionID == preset.rawValue ? nil : count)
                        .accessibilityIdentifier("date-\(preset.rawValue)")
                    }
                }

                Section {
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { value in
                            if let count = counts.counts?.year(value) {
                                Text("\(String(value)) \u{00B7} \(count.formatted())").tag(value)
                            } else {
                                Text(String(value)).tag(value)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    Button("Show Photos From \(String(year))") { applyYear() }
                } header: {
                    Text("Year")
                }

                Section {
                    Toggle("Custom Range", isOn: $showCustomRange.animation(.snappy))
                    if showCustomRange {
                        DatePicker("Start", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                        DatePicker("End", selection: $customEnd, in: customStart...max(customStart, Date()),
                                   displayedComponents: .date)
                    }
                } footer: {
                    if showCustomRange {
                        Text("Apply to search between these dates, both included.")
                    }
                }
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.time, .total])
    }

    nonisolated static func startOfYear(_ year: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
    }

    nonisolated static func endOfYear(_ year: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? Date()
    }

    private func applyYear() {
        let calendar = Calendar.current
        let end = min(Date(), Self.endOfYear(year, calendar: calendar))
        apply(start: Self.startOfYear(year, calendar: calendar), end: end, label: String(localized: "In \(String(year))"), selectionID: "year")
    }

    private func apply(start: Date, end: Date, label: String, selectionID: String) {
        onApply(filter.with { next in
            next.takenAfter = start
            next.takenBefore = end
            next.dateLabel = label
            next.dateSelectionID = selectionID
        })
        dismiss()
    }

    private func applyCustomRange() {
        let calendar = Calendar.current
        let (start, end) = customBounds
        let sameDay = calendar.isDate(customStart, inSameDayAs: customEnd)
        let label = sameDay
            ? customStart.formatted(date: .abbreviated, time: .omitted)
            : (customStart..<max(customStart, customEnd)).formatted(.interval.day().month(.abbreviated).year())
        onApply(filter.with { next in
            next.takenAfter = start
            next.takenBefore = end
            next.dateLabel = label
            next.dateSelectionID = "custom"
        })
    }
}

// MARK: - media type

struct MediaTypePickerSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var selection: SearchFilter.MediaType
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _selection = State(initialValue: filter.mediaType)
    }

    var body: some View {
        FilterSheetScaffold(title: String(localized: "Media Type"), canClear: filter.mediaType != .all, total: counts.counts?.total) {
            onApply(filter.with { $0.mediaType = .all })
        } onApply: {
            onApply(filter.with { $0.mediaType = selection })
        } content: {
            List(SearchFilter.MediaType.allCases) { type in
                let count = counts.counts?.mediaType(type)
                Button {
                    selection = type
                } label: {
                    HStack {
                        Label {
                            Text(type.title)
                                .foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: type.symbol)
                                .foregroundStyle(.tint)
                        }
                        Spacer()
                        SearchCountLabel(count: count)
                        if selection == type {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .dimmedWhenEmpty(selection == type ? nil : count)
                .accessibilityAddTraits(selection == type ? .isSelected : [])
                .accessibilityIdentifier("media-type-\(type.rawValue)")
            }
        }
        .searchCounts(counts, filter: filter.with { $0.mediaType = selection }, dimensions: [.mediaTypes, .total])
    }
}

// MARK: - rating

struct RatingPickerSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var selection: SearchFilter.Rating
    @State private var counts = SearchOptionsModel()

    private let options: [SearchFilter.Rating] = [.stars(5), .stars(4), .stars(3), .stars(2), .stars(1), .unrated]

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _selection = State(initialValue: filter.rating)
    }

    var body: some View {
        FilterSheetScaffold(title: String(localized: "Rating"), canClear: filter.rating != .any, total: counts.counts?.total) {
            onApply(filter.with { $0.rating = .any })
        } onApply: {
            onApply(filter.with { $0.rating = selection })
        } content: {
            List(options, id: \.self) { option in
                let count = counts.counts?.rating(option)
                Button {
                    selection = option
                } label: {
                    HStack {
                        switch option {
                        case .any, .unrated:
                            Label("Unrated", systemImage: "star.slash")
                                .foregroundStyle(.primary)
                        case .stars(let count):
                            HStack(spacing: 3) {
                                ForEach(0..<5, id: \.self) { index in
                                    Image(systemName: index < count ? "star.fill" : "star")
                                        .font(.footnote)
                                        .foregroundStyle(index < count ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                                }
                            }
                            .accessibilityElement()
                            .accessibilityLabel(count == 1 ? String(localized: "1 star") : String(localized: "\(count) stars"))
                        }
                        Spacer()
                        SearchCountLabel(count: count)
                        if selection == option {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .dimmedWhenEmpty(selection == option ? nil : count)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .searchCounts(counts, filter: filter.with { $0.rating = selection }, dimensions: [.ratings, .total])
    }
}

// MARK: - display options

struct DisplayOptionsSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var notInAlbum: Bool
    @State private var isArchive: Bool
    @State private var isFavorite: Bool
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _notInAlbum = State(initialValue: filter.notInAlbum)
        _isArchive = State(initialValue: filter.isArchive)
        _isFavorite = State(initialValue: filter.isFavorite)
    }

    var body: some View {
        let draft = filter.with { $0.notInAlbum = notInAlbum; $0.isArchive = isArchive; $0.isFavorite = isFavorite }
        let availability = counts.counts?.availability
        return FilterSheetScaffold(title: String(localized: "Library"), canClear: filter.notInAlbum || filter.isArchive || filter.isFavorite,
                                   total: counts.counts?.total) {
            onApply(filter.with { $0.notInAlbum = false; $0.isArchive = false; $0.isFavorite = false })
        } onApply: {
            onApply(draft)
        } content: {
            Form {
                Section {
                    Toggle(isOn: $isFavorite) {
                        Label("Favorites", systemImage: "heart")
                    }
                    .dimmedWhenEmpty(!isFavorite && availability?.hasFavorites == false ? 0 : nil)
                    .accessibilityIdentifier("display-favorite")
                    Toggle(isOn: $notInAlbum) {
                        Label("Not in Any Album", systemImage: "rectangle.stack.badge.minus")
                    }
                    .dimmedWhenEmpty(!notInAlbum && availability?.hasAssetsNotInAlbum == false ? 0 : nil)
                    .accessibilityIdentifier("display-not-in-album")
                }
                Section {
                    Toggle(isOn: $isArchive) {
                        Label("Search Archive", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("display-archive")
                } footer: {
                    Text("Search archived items instead of your main photo library.")
                }
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.availability, .total])
    }
}

// MARK: - tags

struct TagsPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var tags: [Tag] = []
    @State private var selected: Set<String>
    @State private var isUntagged: Bool
    @State private var searchText = ""
    @State private var isLoadingTags = true
    @State private var counts = SearchOptionsModel()

    init(filter: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.filter = filter
        self.onApply = onApply
        _selected = State(initialValue: Set(filter.tags.map(\.id)))
        _isUntagged = State(initialValue: filter.isUntagged)
    }

    private var visible: [Tag] {
        let sorted = tags.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.value.localizedStandardContains(searchText) }
    }

    private var draft: SearchFilter {
        let known = Dictionary((tags + filter.tags).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return filter.with {
            $0.isUntagged = isUntagged
            $0.tags = isUntagged ? [] : selected.compactMap { known[$0] }
                .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        }
    }

    var body: some View {
        FilterSheetScaffold(title: selected.isEmpty || isUntagged ? String(localized: "Tags") : String(localized: "\(selected.count) Selected"),
                            canClear: !filter.tags.isEmpty || filter.isUntagged,
                            total: counts.counts?.total) {
            onApply(filter.with { $0.tags = []; $0.isUntagged = false })
        } onApply: {
            onApply(draft)
        } content: {
            List {
                if searchText.isEmpty {
                    Section {
                        Toggle(isOn: $isUntagged.animation(.snappy)) {
                            Label("Untagged Only", systemImage: "tag.slash")
                        }
                        .accessibilityIdentifier("tags-untagged")
                    } footer: {
                        Text(isUntagged
                             ? "Shows photos and videos without any tag."
                             : "Photos must have every tag you select. A parent tag includes its children.")
                    }
                }
                if !isUntagged {
                    Section {
                        ForEach(visible) { tag in
                            tagRow(tag)
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter tags")
            .overlay {
                if isLoadingTags, tags.isEmpty {
                    ProgressView()
                } else if !isUntagged, tags.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "tag.slash",
                                           description: Text("Tags you add to photos appear here."))
                } else if !isUntagged, !searchText.isEmpty, visible.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .task {
                defer { isLoadingTags = false }
                tags = (try? await session.client?.tags()) ?? []
            }
        }
        .searchCounts(counts, filter: draft, dimensions: [.tags, .total])
    }

    private func tagRow(_ tag: Tag) -> some View {
        let isSelected = selected.contains(tag.id)
        let depth = tag.value.count { $0 == "/" }
        let count = counts.counts?.tag(tag.id)
        return Button {
            if isSelected {
                selected.remove(tag.id)
            } else {
                selected.insert(tag.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(tag.name, systemImage: depth > 0 ? "tag" : "tag.fill")
                        .foregroundStyle(.primary)
                    if depth > 0 {
                        Text(tag.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 30)
                    }
                }
                Spacer()
                SearchCountLabel(count: count)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        .dimmedWhenEmpty(isSelected ? nil : count)
        .accessibilityLabel(tag.value)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
