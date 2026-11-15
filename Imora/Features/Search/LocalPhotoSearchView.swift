import Photos
import SwiftUI
import Photos

struct PhotoSearchSourcePicker: View {
    @Binding var source: PhotoSearchSource

    var body: some View {
        Menu {
            Picker("Search Source", selection: $source) {
                ForEach(PhotoSearchSource.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
        } label: {
            Label(source.title, systemImage: source.symbol)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Search Source")
        .accessibilityValue(source.title)
        .accessibilityIdentifier("search-source")
    }
}

/// Local search never mounts the server discovery/filter subtree.
struct LocalPhotoSearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Binding var source: PhotoSearchSource
    let query: String
    @State private var records: [LocalPhotoSearchRecord] = []
    @State private var timeline = TimelineModel(filter: TimelineFilter(order: "asc"), suppliedAssets: [])
    @State private var loading = false
    @State private var revision = 0
    @State private var loadGeneration = 0

    private struct Request: Hashable { let query: String; let revision: Int }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PhotoSearchSourcePicker(source: $source)
                Spacer(minLength: 8)
                Text("File Names & Dates").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            if PhotoAccess.shared.canAsk || PhotoAccess.shared.status == .denied || PhotoAccess.shared.status == .restricted {
                ContentUnavailableView {
                    Label("Search On Device", systemImage: "iphone")
                } description: {
                    Text("Allow photo access to search photos on this device.")
                } actions: {
                    if PhotoAccess.shared.canAsk {
                        Button("Allow Photo Access") {
                            Task { _ = await PhotoLibraryService.requestFullAccess(); await reload() }
                        }
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Manage Photo Access", destination: url)
                    }
                }
            } else if loading && records.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineScreen(title: "", filter: timeline.filter,
                    emptyMessage: String(localized: "No matching photos on this device."),
                    showsLargeTitle: false, suppliedModel: timeline, mergesLocalPhotos: true,
                    header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(timeline.flatAssets.count) results").font(.subheadline).foregroundStyle(.secondary)
                            if PhotoAccess.shared.status == .limited {
                                Text("Only photos you've allowed are searched.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.bottom, 6)
                    })
                    .accessibilityIdentifier("local-search-results")
            }
        }
        .toolbarVisibility(.visible, for: .navigationBar)
        .navigationTitle("")
        .task(id: session.client?.offlineAccountKey) { await reload() }
        .task(id: Request(query: query, revision: revision)) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let snapshot = records
            let requested = query
            let assets = await Task.detached(priority: .userInitiated) {
                LocalPhotoSearch.results(snapshot, query: requested)
            }.value
            guard !Task.isCancelled, requested == query else { return }
            timeline.replaceSuppliedAssets(assets, groupsByDate: true)
        }
        .onChange(of: session.realtime?.localGeneration) { _, _ in Task { await reload() } }
        .onChange(of: PhotoAccess.shared.status) { _, _ in Task { await reload() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
        .onDisappear { loadGeneration += 1 }
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let client = session.client
        loading = true
        let backedUp = Set(session.backup?.remoteIdentifierByLocalId.keys.map { $0 } ?? [])
        let loaded = await LocalPhotoSearch.records(backedUpLocalIDs: backedUp)
        guard generation == loadGeneration, session.client === client, !Task.isCancelled else { return }
        records = loaded
        revision += 1
        loading = false
    }
}
