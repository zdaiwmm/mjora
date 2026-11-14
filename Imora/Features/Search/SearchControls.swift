import Foundation
import SwiftUI

extension FilterSheet {
    var title: String {
        switch self {
        case .people: String(localized: "People")
        case .location: String(localized: "Location")
        case .camera: String(localized: "Camera")
        case .date: String(localized: "Date")
        case .mediaType: String(localized: "Media")
        case .rating: String(localized: "Rating")
        case .display: String(localized: "Library")
        case .tags: String(localized: "Tags")
        }
    }

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .location: "mappin.and.ellipse"
        case .camera: "camera"
        case .date: "calendar"
        case .mediaType: "photo.on.rectangle"
        case .rating: "star"
        case .display: "square.stack"
        case .tags: "tag"
        }
    }

    var activeSymbol: String {
        switch self {
        case .people: "person.2.fill"
        case .location: "mappin.circle.fill"
        case .camera: "camera.fill"
        case .date: "calendar"
        case .mediaType: "photo.fill.on.rectangle.fill"
        case .rating: "star.fill"
        case .display: "square.stack.fill"
        case .tags: "tag.fill"
        }
    }

    /// what the chip shows once set, the way the web chips swap their label.
    func summary(for filter: SearchFilter) -> String? {
        switch self {
        case .people:
            guard let first = filter.people.first else { return nil }
            let name = first.name.isEmpty ? String(localized: "Unnamed Person") : first.name
            guard filter.people.count > 1 else { return name }
            let others = filter.people.count - 1
            return filter.peopleMatch == .any
                ? String(localized: "\(name) or \(others) more")
                : String(localized: "\(name) + \(others) more")
        case .location:
            return joined([filter.city, filter.state, filter.country].compactMap { $0?.label })
        case .camera:
            return joined([filter.make, filter.model, filter.lensModel].compactMap { $0?.label })
        case .date:
            return filter.dateLabel ?? joined([filter.takenAfter, filter.takenBefore].compactMap {
                $0?.formatted(date: .abbreviated, time: .omitted)
            })
        case .mediaType:
            return filter.mediaType == .all ? nil : filter.mediaType.title
        case .rating:
            switch filter.rating {
            case .any: return nil
            case .unrated: return String(localized: "Unrated")
            case .stars(let count): return count == 1 ? String(localized: "1 Star") : String(localized: "\(count) Stars")
            }
        case .display:
            return joined([
                filter.isFavorite ? String(localized: "Favorites") : nil,
                filter.notInAlbum ? String(localized: "Not in Any Album") : nil,
                filter.isArchive ? String(localized: "Archive") : nil,
            ].compactMap(\.self))
        case .tags:
            if filter.isUntagged { return String(localized: "Untagged") }
            guard let first = filter.tags.first else { return nil }
            return filter.tags.count == 1 ? first.name : String(localized: "\(first.name) + \(filter.tags.count - 1) more")
        }
    }

    func clear(from filter: inout SearchFilter) {
        switch self {
        case .people:
            filter.people = []
            filter.peopleMatch = .all
        case .location:
            filter.country = nil
            filter.state = nil
            filter.city = nil
        case .camera:
            filter.make = nil
            filter.model = nil
            filter.lensModel = nil
        case .date:
            filter.takenAfter = nil
            filter.takenBefore = nil
            filter.dateLabel = nil
            filter.dateSelectionID = nil
        case .mediaType: filter.mediaType = .all
        case .rating: filter.rating = .any
        case .display:
            filter.notInAlbum = false
            filter.isArchive = false
            filter.isFavorite = false
        case .tags:
            filter.tags = []
            filter.isUntagged = false
        }
    }

    private func joined(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

struct SearchResultsHeader: View {
    @Environment(SessionStore.self) private var session
    let model: SearchModel
    var total: Int?

    /// size and rating orders need search v2, and only apply to metadata search.
    private var sortOrders: [SearchFilter.SortOrder] {
        let smart = model.filter.usesSmartSearch
        let v2 = session.capabilities.supportsStructuredSearch
        return SearchFilter.SortOrder.allCases.filter { order in
            switch order {
            case .relevance: smart
            case .newest, .oldest: true
            case .largest: !smart && v2
            case .highestRated: !smart && v2 && session.preferences?.ratingsEnabled == true
            }
        }
    }

    private var countText: String? {
        let count = model.assets.count
        if model.isLoading, count == 0 { return nil }
        if model.loadFailed, count == 0 { return nil }
        if model.hasMore, let total, total >= count {
            return total == 1 ? String(localized: "1 Result") : String(localized: "\(total.formatted()) Results")
        }
        if model.hasMore {
            return count == 1 ? String(localized: "1+ Result") : String(localized: "\(count.formatted())+ Results")
        }
        return count == 1 ? String(localized: "1 Result") : String(localized: "\(count.formatted()) Results")
    }

    var body: some View {
        HStack(alignment: .center) {
            Group {
                if let countText {
                    Text(countText)
                        .contentTransition(.numericText())
                } else {
                    Text("Searching...")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.headline)
            .animation(.snappy, value: countText)
            .accessibilityIdentifier("search-result-count")

            Spacer()

            Menu {
                Picker("Sort By", selection: Binding(
                    get: { model.filter.effectiveSortOrder },
                    set: { model.setSortOrder($0) }
                )) {
                    ForEach(sortOrders) { order in
                        Label(order.title, systemImage: order.symbol).tag(order)
                    }
                }
            } label: {
                Label(model.filter.effectiveSortOrder.title, systemImage: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Sort Results")
            .accessibilityValue(model.filter.effectiveSortOrder.title)
            .accessibilityIdentifier("search-sort")
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

struct SearchEmptyState: View {
    let failed: Bool
    let onRetry: () -> Void
    var onClearFilters: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(failed ? "Couldn't Search" : "No Results",
                  systemImage: failed ? "wifi.exclamationmark" : "magnifyingglass")
        } description: {
            Text(failed
                 ? "Check your connection and try again. Your search and filters are kept."
                 : onClearFilters == nil
                    ? "Try a synonym, a more general word, or another search type."
                    : "Try a different search or remove some filters.")
        } actions: {
            if failed {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.glassProminent)
            } else if let onClearFilters {
                Button("Clear Filters", action: onClearFilters)
                    .buttonStyle(.glass)
            }
        }
    }
}

struct SearchLoadingState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Searching your library")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }
}

#Preview(String(localized: "Search Loading")) {
    SearchLoadingState()
}

#Preview(String(localized: "No Results")) {
    SearchEmptyState(failed: false, onRetry: {}, onClearFilters: {})
}

#Preview(String(localized: "Search Error")) {
    SearchEmptyState(failed: true, onRetry: {})
}
