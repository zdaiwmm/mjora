import SwiftUI

struct OfflineAlbumsScreen: View {
    @Environment(SessionStore.self) private var session
    private var downloads: OfflineAlbumDownloads { .shared }
    @State private var pendingRecovery: OfflineAlbumRecovery?
    @State private var confirmRecoveryRemoval = false

    var body: some View {
        List {
            if downloads.albums.isEmpty && downloads.recoveryEntries.isEmpty {
                ContentUnavailableView("No Offline Albums", systemImage: "arrow.down.circle",
                    description: Text("Open an album and choose Keep on This Device to download its photos, videos and Live Photos."))
            }
            ForEach(downloads.albums) { record in
                NavigationLink { OfflineAlbumScreen(album: record.album) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: record.album.albumName)
                        Text("\(record.completedCount) of \(record.items.count) items · \(record.bytes.formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !downloads.recoveryEntries.isEmpty {
                Section {
                    ForEach(downloads.recoveryEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(entry.reason == .unavailable ? String(localized: "Download Unavailable")
                                  : String(localized: "Incomplete Download"), systemImage: "exclamationmark.circle")
                            if entry.reason == .unavailable {
                                Text("This local download could not be read. Pull down to try again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Remove Local Copy", role: .destructive) {
                                pendingRecovery = entry; confirmRecoveryRemoval = true
                            }
                            .accessibilityIdentifier("offline-recovery-remove-\(entry.id)")
                        }
                        .accessibilityElement(children: .contain)
                    }
                } header: {
                    Text("Downloads Need Attention")
                } footer: {
                    Text("Open the original album to download it again.")
                }
                .accessibilityIdentifier("offline-recovery-section")
            }
            if let error = downloads.error { Text(verbatim: error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Offline Albums")
        .accessibilityIdentifier("offline-albums")
        .task(id: session.client?.context.id) { await downloads.attach(session.client) }
        .refreshable { await downloads.reload(refresh: true) }
        .confirmationDialog("Remove Incomplete Download?", isPresented: $confirmRecoveryRemoval, titleVisibility: .visible) {
            Button("Remove Local Copy", role: .destructive) {
                if let entry = pendingRecovery { Task { await downloads.removeRecovery(entry) } }
                pendingRecovery = nil
            }
            .accessibilityIdentifier("offline-recovery-confirm-remove")
        } message: {
            Text("Only this app's downloaded copies are removed. Server photos and your system photo library are kept.")
        }
    }
}

struct OfflineAlbumScreen: View {
    @Environment(SessionStore.self) private var session
    let album: Album
    @State private var assets: [Asset] = []
    @State private var viewer = ViewerPresentation()
    @Namespace private var photoNamespace
    @State private var confirmDownload = false
    @State private var confirmRemove = false
    @State private var refreshGeneration = 0
    private var downloads: OfflineAlbumDownloads { .shared }
    private var record: OfflineAlbum? { downloads.albums.first { $0.id == album.id } }
    private var working: Bool { downloads.workingIDs.contains(album.id) }
    private var availableCount: Int { assets.count }
    private var recordRevision: String {
        guard let record else { return "missing" }
        return "\(record.state.rawValue)|\(record.bytes)|\(record.updatedAt?.timeIntervalSince1970 ?? 0)|\(record.items.count)"
    }

    var body: some View {
        @Bindable var viewer = viewer
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if let record {
                        HStack {
                            Label(stateTitle(record), systemImage: availableCount == record.items.count && record.state == .ready
                                  ? "checkmark.circle" : "arrow.down.circle")
                            Spacer()
                            Text(record.bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        Text("\(availableCount) of \(record.items.count) items available offline")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("offline-album-progress")
                        if working {
                            ProgressView(value: Double(record.completedCount), total: Double(max(1, record.items.count)))
                        }
                        if let date = record.updatedAt {
                            Text("Saved \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = record.error { Text(verbatim: error).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Keep this album's photos, videos and Live Photos available without a connection.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        if working {
                            Button("Pause Download") { downloads.pause(album.id) }
                                .accessibilityIdentifier("offline-album-pause")
                        } else {
                            Button(record == nil ? String(localized: "Keep on This Device") : String(localized: "Download or Update")) {
                                confirmDownload = true
                            }
                            .accessibilityIdentifier("offline-album-download")
                        }
                        if record != nil {
                            Spacer()
                            Button("Remove Download", role: .destructive) { confirmRemove = true }
                                .accessibilityIdentifier("offline-album-remove")
                        }
                    }
                    .buttonStyle(.bordered)
                    Text("Downloads run while the app is open. Updates are manual. Signing out removes these copies; clearing the cache keeps them.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = downloads.error, record?.error != error {
                        Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                if assets.isEmpty {
                    ContentUnavailableView("Downloaded items appear here.", systemImage: "arrow.down.circle")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                        ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                            Button { viewer.present(assets: assets, initialIndex: index) } label: {
                                MemoryAssetImage(asset: asset)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .bottomTrailing) {
                                        if asset.isVideo || asset.isLivePhoto {
                                            Image(systemName: asset.isVideo ? "video.fill" : "livephoto")
                                                .font(.caption).foregroundStyle(.white).padding(6)
                                        }
                                    }
                                    .clipped()
                                    .matchedTransitionSource(id: asset.id, in: photoNamespace)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel([
                                asset.isVideo ? String(localized: "Video") : asset.isLivePhoto ? String(localized: "Live Photo") : String(localized: "Photo"),
                                PhotoDatePresentation.dateTime(wallClock: asset.localDate),
                            ].joined(separator: ", "))
                            .accessibilityIdentifier("offline-asset-\(asset.id)")
                        }
                    }
                }
            }
            .padding(.bottom, 90)
        }
        .background(Color(.systemBackground))
        .navigationTitle(album.albumName).navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(assets: route.assets, indexByAssetID: route.indexByAssetID,
                              initialIndex: route.initialIndex, presentationID: route.id,
                              zoomNamespace: photoNamespace,
                              onRequestDismissal: { viewer.complete(route.id) },
                              onDismissed: { viewer.complete(route.id) }) { _ in }
        }
        .task(id: session.client?.context.id) { await downloads.attach(session.client); await refreshAssets() }
        .onChange(of: recordRevision) { _, _ in Task { await refreshAssets() } }
        .confirmationDialog("Download Album", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("Download on Wi-Fi") { start(allowsCellular: false) }
            Button("Allow Cellular Download") { start(allowsCellular: true) }
        } message: {
            Text("Full photos and video playback files are kept on this device. Large albums can use substantial storage and mobile data.")
        }
        .confirmationDialog("Remove Offline Album?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { Task { await downloads.remove(album.id) } }
        } message: { Text("Only this app's downloaded copies are removed. Server photos and your system photo library are kept.") }
    }

    private func start(allowsCellular: Bool) {
        if let client = session.client { downloads.download(album, client: client, allowsCellular: allowsCellular) }
    }

    private func refreshAssets() async {
        guard let client = session.client else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let assets = if let record { await OfflineAlbumStore.shared.availableAssets(record, scope: client.mediaDisplayScope) } else { [Asset]() }
        guard session.client === client, client.context.isActive, generation == refreshGeneration else { return }
        self.assets = assets
    }

    private func stateTitle(_ record: OfflineAlbum) -> String {
        if record.state == .ready && availableCount != record.items.count { return String(localized: "Update Needed") }
        switch record.state {
        case .downloading: return working ? String(localized: "Downloading") : String(localized: "Download Paused")
        case .paused: return String(localized: "Download Paused")
        case .ready: return String(localized: "Available Offline")
        case .needsUpdate: return String(localized: "Update Needed")
        case .failed: return String(localized: "Download Incomplete")
        }
    }
}
