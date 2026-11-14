import Foundation
import Observation

nonisolated struct SearchRemoval {
    fileprivate let generation: Int
    fileprivate let placements: [(index: Int, asset: Asset)]
    var isEmpty: Bool { placements.isEmpty }
}

/// pages through matches and optionally orders loaded smart matches by date.
@MainActor
@Observable
final class SearchModel {
    typealias Search = @Sendable (SearchFilter, SearchPageToken?) async throws -> (SearchResponse, SearchPageToken?)

    private(set) var filter = SearchFilter()
    private(set) var assets: [Asset] = []
    /// false once the server said there is nothing past the loaded pages.
    private(set) var hasMore = true
    private(set) var isLoading = false
    private(set) var hasActiveSearch = false
    /// a failed page remains retryable without discarding earlier matches.
    private(set) var loadFailed = false

    @ObservationIgnored private var client: ImoraClient?
    @ObservationIgnored private var search: Search?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// nil before the first page, then the server's pointer to the next one.
    @ObservationIgnored private var nextToken: SearchPageToken?
    /// bumped on query changes so stale responses and their defers are ignored.
    private var generation = 0
    @ObservationIgnored private var externalRemovalRollbacks: [String: SearchRemoval] = [:]
    /// arrival order: relevance for smart search, the server's order otherwise.
    @ObservationIgnored private var rank: [String: Int] = [:]

    var queryRevision: Int { generation }

    init(search: Search? = nil) {
        self.search = search
    }

    func attach(_ client: ImoraClient) {
        guard self.client == nil else { return }
        self.client = client
        search = { filter, token in try await client.search(filter, token: token) }
        // a filter applied while the session was still signing in silently
        // no-opped; run it now that requests can actually go out.
        if hasActiveSearch, assets.isEmpty, hasMore {
            loadMore()
        }
    }

    /// smart-search sort changes reorder loaded matches without restarting.
    /// empty filters return to discovery unless allowEmpty requests the library.
    func apply(_ newFilter: SearchFilter, allowEmpty: Bool = false) {
        let searchable = allowEmpty || !newFilter.isEmpty
        guard newFilter != filter || searchable != hasActiveSearch else { return }
        var previous = filter
        previous.sortOrder = newFilter.sortOrder
        if hasActiveSearch, newFilter.usesSmartSearch, previous == newFilter {
            filter = newFilter
            sortLoadedMatches()
            return
        }
        filter = newFilter
        generation += 1
        externalRemovalRollbacks = [:]
        searchTask?.cancel()
        assets = []
        rank = [:]
        nextToken = nil
        hasMore = true
        loadFailed = false
        // set before the task runs, not inside it: the task body lands a
        // runloop turn later, and the frame in between rendered a false
        // "no results" flash on every submit.
        isLoading = searchable
        hasActiveSearch = searchable
        guard hasActiveSearch else { return }
        let requested = generation
        searchTask = Task { await loadNextPage(requested) }
    }

    func loadMore() {
        guard hasActiveSearch, hasMore, !isLoading else { return }
        loadFailed = false
        isLoading = true
        let requested = generation
        searchTask = Task { await loadNextPage(requested) }
    }

    func setSortOrder(_ order: SearchFilter.SortOrder) {
        var next = filter
        next.sortOrder = order
        apply(next, allowEmpty: hasActiveSearch)
    }

    func retry() {
        loadMore()
    }

    func refresh() async {
        guard hasActiveSearch else { return }
        let current = filter
        clear()
        apply(current, allowEmpty: true)
        await searchTask?.value
    }

    func clear() {
        generation += 1
        externalRemovalRollbacks = [:]
        searchTask?.cancel()
        filter = SearchFilter()
        assets = []
        rank = [:]
        nextToken = nil
        hasMore = true
        isLoading = false
        loadFailed = false
        hasActiveSearch = false
    }

    /// in-place mutation used when the viewer reports favorite changes.
    func updateAssets(ids: Set<String>, _ transform: (inout Asset) -> Void) {
        for index in assets.indices where ids.contains(assets[index].id) {
            transform(&assets[index])
        }
    }

    func removeAssets(ids: Set<String>) {
        _ = removeAssetsForOptimisticAction(ids: ids)
    }

    func applyTimelineChange(_ change: TimelineAssetChange, revision: Int) {
        guard revision == generation else { return }
        switch change {
        case .updated(let updates):
            let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            updateAssets(ids: Set(byID.keys)) { asset in
                if let updated = byID[asset.id] { asset = updated }
            }
        case .removed(let ids):
            removeAssets(ids: ids)
        case .restored(let restored):
            var existing = Set(assets.map(\.id))
            assets.append(contentsOf: restored.filter { existing.insert($0.id).inserted })
            sortLoadedMatches()
        }
    }

    func beginExternalOptimisticRemoval(id: String) {
        guard externalRemovalRollbacks[id] == nil else { return }
        externalRemovalRollbacks[id] = removeAssetsForOptimisticAction(ids: [id])
    }

    func commitExternalOptimisticRemoval(id: String) {
        externalRemovalRollbacks[id] = nil
        removeAssets(ids: [id])
    }

    func rollbackExternalOptimisticRemoval(id: String) {
        guard let removal = externalRemovalRollbacks.removeValue(forKey: id) else { return }
        restore(removal, ids: [id])
    }

    func removeAssetsForOptimisticAction(ids: Set<String>) -> SearchRemoval {
        let placements = assets.enumerated().compactMap { index, asset in
            ids.contains(asset.id) ? (index, asset) : nil
        }
        assets.removeAll { ids.contains($0.id) }
        return SearchRemoval(generation: generation, placements: placements)
    }

    /// a token from an old query must never inject assets into a new result.
    func restore(_ removal: SearchRemoval, ids: Set<String>? = nil) {
        guard removal.generation == generation else { return }
        let wanted = ids
        for placement in removal.placements
            .filter({ wanted?.contains($0.asset.id) ?? true })
            .sorted(by: { $0.index < $1.index })
        where !assets.contains(where: { $0.id == placement.asset.id }) {
            assets.insert(placement.asset, at: min(placement.index, assets.count))
        }
        sortLoadedMatches()
    }

    /// the server orders metadata results; smart results are ranked by
    /// relevance and can be re-sorted by date here without a new request.
    private func sortLoadedMatches() {
        let order = filter.effectiveSortOrder
        let byDate = filter.usesSmartSearch && order != .relevance
        assets.sort { lhs, rhs in
            if byDate, lhs.fileCreatedAt != rhs.fileCreatedAt {
                return order == .oldest
                    ? lhs.fileCreatedAt < rhs.fileCreatedAt
                    : lhs.fileCreatedAt > rhs.fileCreatedAt
            }
            return rank[lhs.id, default: .max] < rank[rhs.id, default: .max]
        }
    }

    private func loadNextPage(_ requested: Int) async {
        guard requested == generation else { return }
        guard let search, hasMore else {
            isLoading = false
            loadFailed = self.search == nil
            return
        }
        defer {
            // a superseded load must not clear the successor's spinner.
            if requested == generation { isLoading = false }
        }

        do {
            let currentFilter = filter
            try Task.checkCancellation()
            let (response, next) = try await search(currentFilter, nextToken)
            guard requested == generation, !Task.isCancelled else { return }
            let items = response.assets.items.map { $0.asAsset() }
                .filter { rank[$0.id] == nil }
            for asset in items { rank[asset.id] = rank.count }
            nextToken = next
            hasMore = next != nil
            assets.append(contentsOf: items)
            if currentFilter.usesSmartSearch { sortLoadedMatches() }
            loadFailed = false
        } catch {
            guard requested == generation, !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
