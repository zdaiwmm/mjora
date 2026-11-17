import Foundation
import SwiftUI

struct AlbumsTab: View {
    @Environment(SessionStore.self) private var session

    private enum Filter: String, CaseIterable {
        case all = "All"
        case mine = "Mine"
        case shared = "Shared"

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .mine: String(localized: "Mine")
            case .shared: String(localized: "Shared")
            }
        }
    }

    @State private var layout: CollectionsLayout
    @State private var showLayoutEditor = false
    @State private var showPinnedEditor = false
    @State private var showSettings = false
    private let layoutStore = CollectionsLayoutStore()
    @State private var albums: [Album] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isLoading = false
    /// distinguishes "nothing yet" from "the server says none", so the first
    /// frame shows a spinner instead of flashing the empty state.
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var loadTask: Task<Void, Never>?
    @State private var isCreating = false
    @State private var showCreate = false
    @State private var newAlbumName = ""
    @State private var path = NavigationPath()
    @State private var pendingRemovalIDs = Set<String>()
    @State private var removalNavigation = AlbumRemovalNavigation()
    @State private var albumLoadGate = LatestAlbumLoadGate()
    @State private var pendingAlbumLoadGate = LatestAlbumLoadGate()
    private var router: NotificationRouter { .shared }

    init(account: String? = nil) {
        _layout = State(initialValue: CollectionsLayoutStore().load(account: account))
    }

    private var visibleAlbums: [Album] {
        var result = albums
        switch filter {
        case .all: break
        case .mine: result = result.filter { $0.owner?.id == session.user?.id }
        case .shared: result = result.filter(\.shared)
        }
        if !searchText.isEmpty {
            result = result.filter { $0.albumName.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        NavigationStack(path: $path) {
            CollectionsHome(albums: albums, isLoading: !hasLoaded || isLoading,
                            loadFailed: loadFailed, layout: $layout,
                            onRetry: reload, onEditPins: { showPinnedEditor = true })
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) {
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .black, location: 0.25),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: 130)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("Collections").font(.largeTitle.bold()).fixedSize()
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showCreate = true } label: { Label("New Album", systemImage: "plus") }
                                .accessibilityIdentifier("albums-create")
                            Button { showPinnedEditor = true } label: { Label("Edit Pinned Collections", systemImage: "pin") }
                            Button { showLayoutEditor = true } label: { Label("Customize Collections", systemImage: "arrow.up.arrow.down") }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityIdentifier("collections-layout-menu")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            ProfileAvatar(size: 36).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityIdentifier("profile-avatar")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .navigationDestination(for: Album.self) { album in
                    AlbumDetailScreen(album: album, onAlbumChanged: upsertAlbum,
                        onAlbumRemoved: removeAlbum, onAlbumRestored: restoreAlbum,
                        onAlbumRemovalCommitted: commitAlbumRemoval,
                        isPinned: layout.pinnedIDs.contains("album:\(album.id)"),
                        onTogglePinned: { layout.togglePin("album:\(album.id)") })
                }
                .navigationDestination(for: CollectionsRoute.self) { route in
                    switch route {
                    case .albums: allAlbumsPage
                    case .map: MapScreen()
                    case .recent:
                        TimelineScreen(title: String(localized: "Recently Added"),
                                       filter: TimelineFilter(orderBy: "createdAt"), showsLargeTitle: false)
                    case .media(let media): PhotosMediaTimeline(media: media, title: media.title)
                    case .deviceMedia(let media):
                        DeviceLibraryScreen(session: session, navigationTarget: .constant(nil), mediaFilter: media)
                            .navigationTitle(media.title).navigationBarTitleDisplayMode(.inline)
                    case .memories:
                        ScrollView {
                            MemoryLane(showsHeading: false, cardWidth: 250, cardHeight: 250,
                                       cornerRadius: 26, showsEmptyPlaceholder: true)
                                .padding(.top, 16)
                        }.navigationTitle("Memories").navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationDestination(for: LibraryDestination.self) { LibraryDestinationScreen(destination: $0) }
                .navigationDestination(for: Person.self) { PersonScreen(person: $0) }
                .navigationDestination(for: PlaceLink.self) { PlaceScreen(city: $0.city, coordinate: $0.coordinate) }
                .navigationDestination(for: SharedSpace.self) { SpaceScreen(space: $0) }
                .navigationDestination(for: CleanupRoute.self) { CleanupRouteScreen(route: $0) }
                .task {
                    await load()
                }
                .task(id: router.pendingAlbumID) { await openPendingAlbum() }
                .onAppear { if !albums.isEmpty { reload() } }
                .onChange(of: session.realtime?.albumsGeneration ?? 0) { reload() }
                .onChange(of: layout) { _, value in
                    layoutStore.save(value, account: session.client?.offlineAccountKey)
                }
                .onChange(of: path.count) { _, _ in session.lockedFolder?.lock() }
                .sheet(isPresented: $showLayoutEditor) { CollectionsLayoutEditor(layout: $layout) }
                .sheet(isPresented: $showPinnedEditor) { PinnedCollectionsEditor(layout: $layout, albums: albums) }
                .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .tint(.primary)
        .alert("New Album", isPresented: $showCreate) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") { Task { await createAlbum() } }
                .disabled(isCreating || newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
        }
    }

    private var allAlbumsPage: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 20) {
                ForEach(visibleAlbums) { album in
                    NavigationLink(value: album) { AlbumCard(album: album) }
                        .buttonStyle(PressableCardStyle())
                        .disabled(album.isPending)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .navigationTitle("All Albums")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Album name")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Albums", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("albums-filter")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .disabled(isCreating)
                    .accessibilityIdentifier("albums-create")
            }
        }
        .overlay {
            if albums.isEmpty, !hasLoaded { ProgressView() }
            else if albums.isEmpty, loadFailed {
                ContentUnavailableView {
                    Label("Couldn't load albums", systemImage: "wifi.exclamationmark")
                } actions: { Button("Retry", action: reload) }
            } else if visibleAlbums.isEmpty {
                if searchText.isEmpty { ContentUnavailableView("No albums", systemImage: "rectangle.stack") }
                else { ContentUnavailableView.search(text: searchText) }
            }
        }
    }

    /// restarts the fetch, cancelling the one in flight: a burst of realtime
    /// album events or quick tab hops would otherwise stack whole-list
    /// downloads whose results are thrown away by the gate anyway.
    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        let ticket = albumLoadGate.begin()
        isLoading = true
        let account = client.offlineAccountKey
        // a fresh tab paints the last known list first, and keeps it when the
        // server is unreachable. read and decoded off main - with enough
        // albums the file is megabytes and this used to hitch the tab open.
        if albums.isEmpty, let account {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Album].self, key: "albums", account: account)
            }.value
            // Pending rows are session projections. Persisting one could leave
            // a ghost album after the app is terminated mid-request.
            if let cached, albums.isEmpty, albumLoadGate.accepts(ticket) {
                albums = cached.filter { !$0.isPending }
            }
        }
        let fetched = try? await client.albums()
        guard albumLoadGate.accepts(ticket) else { return }
        if let fetched {
            loadFailed = false
            let pending = albums.filter(\.isPending)
            let currentByID = Dictionary(
                albums.lazy.filter { !$0.isPending }.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let reconciled = fetched
                .filter { !pendingRemovalIDs.contains($0.id) }
                .filter { fetched in !pending.contains { $0.id == fetched.id } }
                .map { fetched in
                    currentByID[fetched.id]?.reconcilingServerVersion(fetched) ?? fetched
                }
                .sorted { $0.updatedAt > $1.updatedAt }
            let merged = pending + reconciled
            // most reloads confirm what is already on screen; skipping the
            // assignment spares a full grid diff over every album.
            if albums != merged {
                albums = merged
                if let account {
                    let snapshot = merged.filter { !$0.isPending }
                    Task.detached(priority: .utility) {
                        OfflineCache.store(snapshot, key: "albums", account: account)
                    }
                }
            }
        } else if !Task.isCancelled {
            loadFailed = true
        }
        isLoading = false
        hasLoaded = true
    }

    private func createAlbum() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = session.client, !name.isEmpty, !isCreating else { return }
        let pending = Album.pending(name: name, owner: session.user)
        isCreating = true
        defer { isCreating = false }
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't create the album."),
            apply: {
                newAlbumName = ""
                upsertAlbum(pending)
            },
            rollback: {
                removeProjectedAlbum(id: pending.id)
                newAlbumName = name
            },
            request: { try await client.createAlbum(name: name) },
            commit: { replaceAlbum(id: pending.id, with: $0) }
        )
    }

    private func upsertAlbum(_ album: Album) {
        invalidateAlbumLoads()
        if let index = albums.firstIndex(where: { $0.id == album.id }) {
            albums[index] = album
        } else {
            albums.insert(album, at: 0)
        }
    }

    private func replaceAlbum(id: String, with album: Album) {
        invalidateAlbumLoads()
        albums.removeAll { $0.id == id || $0.id == album.id }
        albums.insert(album, at: 0)
    }

    private func removeAlbum(_ album: Album) {
        removalNavigation.record(id: album.id, path: path)
        invalidateAlbumLoads()
        pendingRemovalIDs.insert(album.id)
        albums.removeAll { $0.id == album.id }
    }

    private func restoreAlbum(_ album: Album) {
        pendingRemovalIDs.remove(album.id)
        upsertAlbum(album)
        // Reopen only when the user stayed on the albums root. If they already
        // navigated elsewhere while the request failed, restoring the list row
        // is the least surprising precise rollback.
        if removalNavigation.shouldReopen(id: album.id, current: path) { path.append(album) }
    }

    private func commitAlbumRemoval(_ albumID: String) {
        removalNavigation.commit(id: albumID)
        layout.removeAlbum(albumID)
        invalidateAlbumLoads()
        pendingRemovalIDs.remove(albumID)
    }

    private func removeProjectedAlbum(id: String) {
        invalidateAlbumLoads()
        albums.removeAll { $0.id == id }
    }

    private func invalidateAlbumLoads() {
        albumLoadGate.invalidate()
        isLoading = false
    }

    private func openPendingAlbum() async {
        guard let id = router.pendingAlbumID else { return }
        guard let client = session.client else {
            // Preserve the previous one-shot notification behavior when no
            // authenticated client is available to resolve the destination.
            router.pendingAlbumID = nil
            return
        }
        let ticket = pendingAlbumLoadGate.begin()
        let album = try? await client.album(id: id)
        guard pendingAlbumLoadGate.accepts(ticket), router.pendingAlbumID == id else { return }
        router.pendingAlbumID = nil
        guard let album, !Task.isCancelled else { return }
        path = NavigationPath()
        path.append(album)
    }
}

struct AlbumRemovalNavigation {
    private var parents: [String: NavigationPath] = [:]

    mutating func record(id: String, path: NavigationPath) {
        var parent = path
        if !parent.isEmpty { parent.removeLast() }
        parents[id] = parent
    }

    mutating func shouldReopen(id: String, current: NavigationPath) -> Bool {
        guard let parent = parents.removeValue(forKey: id) else { return false }
        return parent == current
    }

    mutating func commit(id: String) { parents.removeValue(forKey: id) }
}

struct AlbumCard: View {
    @Environment(SessionStore.self) private var session
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // clear square keeps the fill image bounded to the grid cell.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbID = album.albumThumbnailAssetId, let client = session.client {
                        RemoteImage(url: client.thumbnailURL(assetID: thumbID), targetPixelSize: 640)
                    } else {
                        Rectangle()
                            .fill(Color(.secondarySystemFill))
                            .overlay {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.albumName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(album.assetCount == 1 ? String(localized: "1 item") : String(localized: "\(album.assetCount) items"))
                    if album.shared {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// sheet used by multi-select to add assets to an album.
struct AlbumPickerSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var request: AlbumAddSelection
    private var assetIDs: [String] { request.assetIDs }
    private var localIdentifiers: [String] { request.localIdentifiers }
    let onApplied: () -> Void
    let onRollback: (Set<String>) -> Void

    init(assetIDs: [String], localIdentifiers: [String] = [], sourceAccountGeneration: UUID? = nil,
         onApplied: @escaping () -> Void, onRollback: @escaping (Set<String>) -> Void) {
        _request = State(initialValue: AlbumAddSelection(assetIDs: assetIDs,
            localIdentifiers: localIdentifiers, accountGeneration: sourceAccountGeneration))
        self.onApplied = onApplied
        self.onRollback = onRollback
    }

    @State private var albums: [Album] = []
    @State private var newAlbumName = ""
    @State private var showCreate = false
    @State private var isWorking = false
    @State private var isLoading = true

    var body: some View {
        if localIdentifiers.isEmpty {
            remotePicker
        } else {
            AddToAlbumSheet(assetIDs: assetIDs, localIdentifiers: localIdentifiers,
                            sourceAccountGeneration: request.accountGeneration) { _ in onApplied() }
        }
    }

    private var remotePicker: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                    .disabled(isWorking || isLoading)
                }
                Section {
                    ForEach(albums) { album in
                        Button {
                            Task { await add(to: album) }
                        } label: {
                            HStack(spacing: 12) {
                                if let thumbID = album.albumThumbnailAssetId, let client = session.client {
                                    RemoteImage(url: client.thumbnailURL(assetID: thumbID), targetPixelSize: 120)
                                        .frame(width: 44, height: 44)
                                        .clipShape(.rect(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.secondarySystemFill))
                                        .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading) {
                                    Text(album.albumName)
                                        .foregroundStyle(.primary)
                                    Text("\(album.assetCount) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(isWorking || isLoading)
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            // without this the sheet reads as "you have no albums" for the
            // whole length of a slow fetch. no empty state on purpose - the
            // new album row is the affordance and an overlay would cover it.
            .overlay {
                if isLoading && albums.isEmpty {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                defer { isLoading = false }
                // the albums tab's offline copy paints the owned subset
                // instantly while the fresh list loads.
                if albums.isEmpty, let client = session.client, let account = client.offlineAccountKey {
                    let cached = await Task.detached(priority: .userInitiated) {
                        OfflineCache.value([Album].self, key: "albums", account: account)
                    }.value
                    if let cached, albums.isEmpty {
                        let ownerID = session.user?.id
                        albums = cached
                            .filter { !$0.isPending && (ownerID == nil || $0.owner?.id == ownerID) }
                            .sorted { $0.updatedAt > $1.updatedAt }
                    }
                }
                if let fetched = try? await session.client?.albums(isOwned: true) {
                    albums = fetched.sorted { $0.updatedAt > $1.updatedAt }
                }
            }
            .alert("New Album", isPresented: $showCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Create & Add") {
                    Task { await createAndAdd() }
                }
                .disabled(
                    isWorking
                        || newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func add(to album: Album) async {
        guard let client = session.client, !isWorking else { return }
        let requested = Set(assetIDs)
        let optimistic = album.withAssetCountDelta(requested.count)
        isWorking = true
        defer { isWorking = false }
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't add the selected items to the album."),
            apply: {
                replaceAlbum(id: album.id, with: optimistic)
                dismiss()
                onApplied()
            },
            rollback: {
                replaceAlbum(id: album.id, with: album)
                onRollback(requested)
            },
            request: { try await client.addAssets(albumID: album.id, ids: Array(requested)) },
            commit: { results in
                let outcome = BulkMutationOutcome(requestedIDs: requested, results: results)
                replaceAlbum(
                    id: album.id,
                    with: album.withAssetCountDelta(outcome.successfulIDs.count)
                )
                reportBulkFailures(outcome)
                if !outcome.failedIDs.isEmpty { onRollback(outcome.failedIDs) }
            }
        )
    }

    private func createAndAdd() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = session.client, !name.isEmpty, !isWorking else { return }
        let requested = Set(assetIDs)
        let pending = Album.pending(name: name, assetCount: requested.count)
        isWorking = true
        defer { isWorking = false }
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't create the album."),
            apply: {
                newAlbumName = ""
                albums.insert(pending, at: 0)
                dismiss()
                onApplied()
            },
            rollback: {
                albums.removeAll { $0.id == pending.id }
                newAlbumName = name
                onRollback(requested)
            },
            request: { try await client.createAlbum(name: name, assetIds: assetIDs) },
            commit: { replaceAlbum(id: pending.id, with: $0) }
        )
    }

    private func replaceAlbum(id: String, with replacement: Album) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index] = replacement
    }

    private func reportBulkFailures(_ outcome: BulkMutationOutcome) {
        guard !outcome.failedIDs.isEmpty else { return }
        ErrorToastCenter.shared.show(
            outcome.failedIDs.count == 1 ? String(localized: "Couldn't add 1 selected item to the album.") : String(localized: "Couldn't add \(outcome.failedIDs.count) selected items to the album.")
        )
    }
}
