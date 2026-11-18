import Foundation
import Observation
import Photos

/// Owns one search page's metadata and its publication fences. No network or
/// original-resource access belongs to this model.
@MainActor
@Observable
final class LocalPhotoSearchModel {
    struct Context: Hashable, Sendable {
        let sessionID: UUID?
        let permissionEpoch: Int
        let authorization: Int
        let isActive: Bool

        var canRead: Bool {
            isActive && (authorization == PHAuthorizationStatus.authorized.rawValue
                || authorization == PHAuthorizationStatus.limited.rawValue)
        }
    }

    enum Phase { case inactive, loading, ready }
    typealias Loader = @Sendable (Set<String>) async -> [LocalPhotoSearchRecord]
    typealias Visibility = @Sendable (Set<String>) async -> Set<String>
    typealias Matcher = @Sendable ([LocalPhotoSearchRecord], String) async -> [Asset]

    let timeline = TimelineModel(filter: TimelineFilter(order: "asc"), suppliedAssets: [])
    private(set) var phase = Phase.inactive
    private(set) var context: Context?
    private(set) var metadataRevision = 0
    private(set) var results: [Asset] = []
    @ObservationIgnored private var records: [LocalPhotoSearchRecord] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private let visible: Visibility
    @ObservationIgnored private let match: Matcher

    init(load: @escaping Loader = { await LocalPhotoSearch.records(backedUpLocalIDs: $0) },
         visible: @escaping Visibility = { await LocalPhotoSearch.visibleIdentifiers(in: $0) },
         match: @escaping Matcher = { records, query in
             await Task.detached(priority: .userInitiated) {
                 LocalPhotoSearch.results(records, query: query)
             }.value
         }) {
        self.load = load
        self.visible = visible
        self.match = match
    }

    func invalidate() {
        generation &+= 1
        queryGeneration &+= 1
        context = nil
        phase = .inactive
        records = []
        publish([])
    }

    func reload(context requested: Context, backedUpLocalIDs: Set<String>) async {
        guard !Task.isCancelled else { return }
        invalidate()
        context = requested
        guard requested.canRead else { return }
        phase = .loading
        let request = generation
        let loaded = await load(backedUpLocalIDs)
        guard isCurrent(request, context: requested), !Task.isCancelled else { return }
        let identifiers = Set(loaded.compactMap { $0.asset.localIdentifier })
        let allowed = await visible(identifiers)
        guard isCurrent(request, context: requested), !Task.isCancelled else { return }
        records = loaded.filter { $0.asset.localIdentifier.map(allowed.contains) == true }
        phase = .ready
        metadataRevision &+= 1
    }

    func search(_ query: String, context requested: Context) async {
        queryGeneration &+= 1
        let queryRequest = queryGeneration
        let request = generation
        guard phase == .ready, isCurrent(request, context: requested) else { return }
        let matched = await match(records, query)
        guard isCurrent(request, context: requested), queryRequest == queryGeneration,
              !Task.isCancelled else { return }
        let allowed = await visible(Set(matched.compactMap(\.localIdentifier)))
        guard isCurrent(request, context: requested), queryRequest == queryGeneration,
              !Task.isCancelled else { return }
        publish(matched.filter { $0.localIdentifier.map(allowed.contains) == true })
    }

    private func isCurrent(_ request: Int, context requested: Context) -> Bool {
        request == generation && context == requested && requested.canRead
    }

    private func publish(_ assets: [Asset]) {
        results = assets
        timeline.replaceSuppliedAssets(assets, groupsByDate: true)
    }
}
