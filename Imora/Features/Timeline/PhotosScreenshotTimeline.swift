import SwiftUI

/// Cloud matches use server subtype metadata or exact device/server pairings.
/// Filenames and image dimensions cannot establish a screenshot subtype.
struct PhotosScreenshotTimeline: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let configuration: PhotosToolbarConfiguration?
    let title: String
    @State private var library = PhotosScreenshotLibraryModel()
    @State private var timeline = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])

    var body: some View {
        TimelineScreen(title: title, filter: timeline.filter, showsLargeTitle: false,
                       photosConfiguration: configuration, showsEmptyState: !library.isLoading && library.error == nil,
                       suppliedModel: timeline, footer: {
            VStack(spacing: 8) {
                Text("\(library.assets.count) items")
                    .accessibilityIdentifier("photos-filter-count")
                if library.hasUnclassifiedPhotos {
                    Text("Some cloud photos have no screenshot classification.")
                }
            }
            .font(.footnote).foregroundStyle(.secondary).padding()
        })
        .task(id: session.client?.context.id) { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: library.assets, initial: true) { _, assets in
            timeline.replaceSuppliedAssets(assets, groupsByDate: true)
        }
        .overlay {
            if timeline.isEmpty, library.isLoading {
                ProgressView("Loading photos")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
                    .accessibilityIdentifier("photos-screenshot-loading")
            } else if timeline.isEmpty, let error = library.error {
                ContentUnavailableView {
                    Label("Couldn't check this filter", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button("Retry") { Task { await refresh() } } }
                    .background(Color(.systemBackground))
            }
        }
    }

    private func refresh() async {
        guard let client = session.client else { return }
        let pairs = session.backup?.remoteIdentifierByLocalId ?? [:]
        let deviceAssets = await PhotoLibraryService.browsableAssets()
        guard !Task.isCancelled, session.client === client else { return }
        let known = Dictionary(deviceAssets.compactMap { asset -> (String, Bool)? in
            guard let remoteID = pairs[asset.localIdentifier] else { return nil }
            return (remoteID, asset.isScreenshot)
        }, uniquingKeysWith: { _, latest in latest })
        await library.refresh(client: client, deviceClassification: known)
    }
}

@MainActor @Observable
final class PhotosScreenshotLibraryModel {
    private(set) var assets: [Asset] = []
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var hasUnclassifiedPhotos = false
    @ObservationIgnored private var generation = 0

    static func matches(_ asset: Asset, knownScreenshots: Set<String>) -> Bool {
        asset.isImage && (asset.isScreenshot ?? knownScreenshots.contains(asset.id))
    }

    func refresh(client: ImoraClient, deviceClassification: [String: Bool]) async {
        generation += 1
        let requested = generation
        isLoading = true
        error = nil
        defer { if requested == generation { isLoading = false } }
        do {
            let account = client.offlineAccountKey
            var known: Set<String> = await Task.detached {
                guard let account else { return [] }
                return OfflineCache.value(Set<String>.self, key: "screenshot-classification", account: account) ?? []
            }.value
            for (id, isScreenshot) in deviceClassification {
                if isScreenshot { known.insert(id) } else { known.remove(id) }
            }
            let all = try await PhotoFilterMetadata.collectAll { token in
                let (response, next) = try await client.search(PhotoMediaFilter.photos.cloudSearchFilter, token: token)
                return (response.assets.items.map { $0.asAsset() }, next)
            }
            guard !Task.isCancelled, requested == generation, client.context.isActive else { return }
            assets = all.filter { Self.matches($0, knownScreenshots: known) }
            hasUnclassifiedPhotos = all.contains { $0.isScreenshot == nil && deviceClassification[$0.id] == nil && !known.contains($0.id) }
            if let account {
                await Task.detached {
                    OfflineCache.store(known, key: "screenshot-classification", account: account)
                }.value
            }
        } catch {
            guard !Task.isCancelled, requested == generation, client.context.isActive else { return }
            self.error = error.localizedDescription
        }
    }
}
