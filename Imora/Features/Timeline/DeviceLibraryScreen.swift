import SwiftUI

/// A device-only projection. Supplied assets never request server time buckets.
struct DeviceLibraryScreen: View {
    @Binding var navigationTarget: TimelineNavigationTarget?
    var photosConfiguration: PhotosToolbarConfiguration? = nil
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = TimelineModel(filter: TimelineFilter(order: "asc"), suppliedAssets: [])
    @State private var loadTask: Task<Void, Never>?
    @State private var allAssets: [Asset] = []
    @State private var filterLoading = true
    @State private var filterError: String?
    @State private var loadID = UUID()
    @State private var albumMembership = PhotoAppAlbumMembershipCache.shared

    var body: some View {
        TimelineScreen(title: "", filter: model.filter, emptyMessage: String(localized: "No accessible photos on this device."),
            showsLargeTitle: false, photosConfiguration: photosConfiguration,
            showsEmptyState: !filterLoading && filterError == nil, suppliedModel: model,
            mergesLocalPhotos: true, navigationTarget: $navigationTarget, header: {
                if photosConfiguration?.controls.mediaFilter == .notInAlbum {
                    Text("App cloud albums. Albums in the device Photos app are separate.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if PhotoAccess.shared.canAsk {
                    Button("Allow Photo Access") {
                        Task { _ = await PhotoLibraryService.requestFullAccess(); reload() }
                    }
                    .padding()
                }
                if PhotoAccess.shared.isBlocked, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Manage Photo Access", destination: url).padding()
                        .accessibilityIdentifier("device-manage-photo-access")
                }
                if photosConfiguration == nil {
                    Text("\(model.flatAssets.count) items on this device")
                        .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                        .accessibilityIdentifier("device-library-count")
                }
            })
            .task(id: session.client.map(ObjectIdentifier.init)) {
                session.realtime?.addListener(albumMembership)
                reload()
            }
            .refreshable {
                albumMembership.invalidate(account: session.client?.offlineAccountKey)
                reload()
                await loadTask?.value
            }
            .onChange(of: photosConfiguration?.controls.mediaFilter) { _, _ in reload() }
            .onChange(of: photosConfiguration?.controls.sortByAdded) { _, _ in applyPresentation() }
            .onChange(of: session.realtime?.localGeneration) { _, _ in reload() }
            .onChange(of: albumMembership.generation) { _, _ in
                if photosConfiguration?.controls.mediaFilter == .notInAlbum { reload() }
            }
            .onChange(of: PhotoAccess.shared.status) { _, _ in reload() }
            .onChange(of: scenePhase) { _, value in
                if value == .active {
                    albumMembership.invalidate(account: session.client?.offlineAccountKey)
                    reload()
                }
            }
            .onDisappear { loadTask?.cancel() }
            .overlay {
                if filterLoading && !model.hasRestoredLaunchViewport {
                    ProgressView(photosConfiguration?.controls.mediaFilter == .notInAlbum
                                 ? String(localized: "Checking App album membership") : String(localized: "Loading photos"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
                } else if let filterError {
                    ContentUnavailableView {
                        Label("Couldn't check this filter", systemImage: "wifi.exclamationmark")
                    } description: { Text(filterError) } actions: { Button("Retry", action: reload) }
                    .background(Color(.systemBackground))
                }
            }
    }

    private func reload() {
        loadTask?.cancel()
        let requested = UUID()
        loadID = requested
        let client = session.client
        let selectedFilter = photosConfiguration?.controls.mediaFilter ?? .all
        filterError = nil
        filterLoading = true
        loadTask = Task {
            defer { if loadID == requested { filterLoading = false } }
            if let client {
                model.suppliedLaunchContext = "device|\(selectedFilter.rawValue)|\(photosConfiguration?.controls.sortByAdded == true ? "added" : "date")"
                model.attach(client, preparesLaunchViewport: true)
                await model.waitForLaunchLayout()
                guard !Task.isCancelled else { return }
                await model.load()
            }
            var assets: [Asset]
            if PhotoLibraryService.hasFullAccess, let backup = session.backup {
                assets = await backup.localTimelineAssets().map { $0.device.asAsset(backedUp: $0.backedUp) }
            } else {
                assets = await PhotoLibraryService.browsableAssets().map { $0.asAsset(backedUp: false) }
            }
            guard !Task.isCancelled, session.client === client else { return }
            do {
                if selectedFilter == .edited {
                    assets = await PhotoFilterMetadata.editedDeviceAssets(assets)
                } else if selectedFilter == .notInAlbum {
                    let backup = session.backup
                    let knownPairs = backup?.remoteIdentifierByLocalId ?? [:]
                    let verified = knownPairs.filter { backup?.hasVerifiedBackup(localIdentifier: $0.key) == true }
                    let uncertain = Set(knownPairs.keys).subtracting(verified.keys)
                    let localIDs = Set(assets.compactMap(\.localIdentifier))
                    let needsServer = verified.keys.contains(where: { localIDs.contains($0) })
                    let unfiled: Set<String>
                    if needsServer {
                        guard let client else { throw PhotoFilterMetadataError.albumMembershipUnavailable }
                        let remoteIDs = Set(verified.filter { localIDs.contains($0.key) }.values)
                        unfiled = try await albumMembership.unfiledIDs(account: client.offlineAccountKey, remoteIDs: remoteIDs) { id in
                            try await !client.albums(assetID: id).isEmpty
                        }
                    } else { unfiled = [] }
                    assets = try PhotoFilterMetadata.applyingAppAlbumMembership(to: assets,
                        verifiedRemoteByLocal: verified, unfiledRemoteIDs: unfiled, uncertainLocalIDs: uncertain)
                }
                guard !Task.isCancelled, session.client === client, loadID == requested else { return }
                allAssets = assets
                applyPresentation()
            } catch {
                guard !Task.isCancelled, session.client === client, loadID == requested else { return }
                filterError = error.localizedDescription
            }
        }
    }

    private func applyPresentation() {
        guard let controls = photosConfiguration?.controls else {
            model.replaceSuppliedAssets(allAssets, groupsByDate: true)
            return
        }
        let visible = allAssets.filter { controls.mediaFilter.includes($0) }.sorted {
            controls.sortByAdded ? $0.uploadLocalDate < $1.uploadLocalDate : $0.localDate < $1.localDate
        }
        model.replaceSuppliedAssets(visible, groupsByDate: true)
    }
}
