import Foundation
import SwiftUI

/// adapts paged matches to the same timeline used by photos, albums, and people.
struct SearchResultsTimeline: View {
    let search: SearchModel
    var title = ""
    var onClearFilters: (() -> Void)?
    /// the exact match count, when the server counts it.
    var total: Int?

    var body: some View {
        SearchTimelineContent(search: search, title: title, onClearFilters: onClearFilters, total: total)
            .id(search.queryRevision)
    }
}

private struct SearchTimelineContent: View {
    let search: SearchModel
    let title: String
    let onClearFilters: (() -> Void)?
    let total: Int?
    let revision: Int

    @State private var timeline: TimelineModel
    @State private var scrollResetTrigger = 0

    init(search: SearchModel, title: String, onClearFilters: (() -> Void)?, total: Int?) {
        self.search = search
        self.title = title
        self.onClearFilters = onClearFilters
        self.total = total
        revision = search.queryRevision
        let filter = TimelineFilter(visibility: search.filter.isArchive ? .archive : .timeline,
                                    isFavorite: search.filter.isFavorite ? true : nil)
        let timeline = TimelineModel(filter: filter, suppliedAssets: search.assets,
                                     groupsSuppliedAssetsByDate: search.filter.effectiveSortOrder.groupsByDate)
        timeline.onAssetsChanged = { [weak search, revision = search.queryRevision] change in
            search?.applyTimelineChange(change, revision: revision)
        }
        _timeline = State(initialValue: timeline)
    }

    var body: some View {
        TimelineScreen(title: title, filter: timeline.filter, showsLargeTitle: false,
                       showsEmptyState: false, hidesScrollEdgeEffect: true,
                       scrollResetTrigger: scrollResetTrigger,
                       suppliedModel: timeline, footer: { SearchResultsFooter(model: search) }) {
            SearchResultsHeader(model: search, total: total)
        }
        .refreshable { await search.refresh() }
        .onChange(of: search.assets) { synchronizeTimeline() }
        .onChange(of: search.filter.sortOrder) {
            synchronizeTimeline()
            scrollResetTrigger += 1
        }
        .overlay {
            if search.assets.isEmpty {
                if search.isLoading {
                    SearchLoadingState()
                } else {
                    SearchEmptyState(failed: search.loadFailed, onRetry: search.retry,
                                     onClearFilters: onClearFilters)
                }
            }
        }
        .accessibilityIdentifier("search-timeline")
    }

    private func synchronizeTimeline() {
        guard search.queryRevision == revision else { return }
        timeline.replaceSuppliedAssets(search.assets,
                                       groupsByDate: search.filter.effectiveSortOrder.groupsByDate)
    }
}

private struct SearchResultsFooter: View {
    @Environment(\.timelineFooterIsVisible) private var isVisible
    let model: SearchModel

    var body: some View {
        if !model.assets.isEmpty {
            Group {
                if model.isLoading {
                    ProgressView()
                } else if model.loadFailed {
                    Button("Couldn't load more. Retry", action: model.retry)
                } else if !model.hasMore {
                    Text(endNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Button("Load More Results", action: model.loadMore)
                        .onChange(of: isVisible, initial: true) { _, visible in
                            if visible { model.loadMore() }
                        }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical)
        }
    }

    /// smart search matching any of several people is one page on 3.2, so
    /// running out there does not mean nothing else matches.
    private var endNote: String {
        let capped = model.filter.usesSmartSearch && model.filter.matchesAnyPerson
            && model.assets.count >= SearchRequest.smartSinglePageSize
        return capped ? String(localized: "Showing the best \(model.assets.count.formatted()) matches") : String(localized: "End of results")
    }
}
