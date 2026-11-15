import Foundation
import Observation

@MainActor @Observable
final class PhotosEditedLibraryModel {
    private(set) var assets: [Asset] = []
    private(set) var isLoading = true
    private(set) var error: String?
    @ObservationIgnored private var page: PhotoFilterMetadata.Page?
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(page: PhotoFilterMetadata.Page? = nil) { self.page = page }

    func attach(_ client: ImoraClient, hub: RealtimeHub?) {
        hub?.addListener(self)
        guard clientIdentity != ObjectIdentifier(client) || page == nil else { return }
        generation += 1
        clientIdentity = ObjectIdentifier(client)
        assets = []
        page = { token in
            let (response, next) = try await client.search(PhotoMediaFilter.edited.cloudSearchFilter, token: token)
            return (response.assets.items.map { $0.asAsset() }, next)
        }
    }

    func refresh() async {
        generation += 1
        let requested = generation
        isLoading = true
        error = nil
        defer { if requested == generation { isLoading = false } }
        do {
            guard let page else { throw PhotoFilterMetadataError.editStatusUnavailable }
            let all = try await PhotoFilterMetadata.collectAll(page: page)
            guard !Task.isCancelled, requested == generation else { return }
            guard all.allSatisfy({ $0.isEdited != nil }) else { throw PhotoFilterMetadataError.editStatusUnavailable }
            assets = all.filter { $0.isEdited == true }
        } catch {
            guard !Task.isCancelled, requested == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func apply(_ change: TimelineAssetChange) {
        switch change {
        case .updated(let updates):
            let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            assets = assets.compactMap { asset in
                let updated = byID[asset.id] ?? asset
                return updated.isEdited == true ? updated : nil
            }
        case .removed(let ids): assets.removeAll { ids.contains($0.id) }
        case .restored(let restored):
            var seen = Set(assets.map(\.id))
            assets.append(contentsOf: restored.filter { $0.isEdited == true && seen.insert($0.id).inserted })
        }
    }
}

extension PhotosEditedLibraryModel: RealtimeListener {
    func realtimeAssetsRemoved(_ ids: Set<String>) { scheduleRefresh() }
    func realtimeAssetUpdated(_ detail: AssetDetail) { scheduleRefresh() }
    func realtimeResync() { scheduleRefresh() }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await self?.refresh()
        }
    }
}
