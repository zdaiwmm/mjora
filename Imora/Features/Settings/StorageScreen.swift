import SwiftUI

/// storage overview: what the account occupies on the server and what imora
/// keeps on this device, with a way to reclaim the local caches. backup has
/// its own screen and is deliberately not represented here.
struct StorageScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var serverStorage: ServerStorage?
    @State private var imageBytes: Int64 = 0
    @State private var libraryBytes: Int64 = 0
    @State private var confirmClear = false
    @State private var isClearing = false
    @State private var shareStorage: SharePendingStorage.Snapshot?
    @State private var shareStorageUnavailable = false
    @State private var shareDiscardSnapshot: SharePendingStorage.Snapshot?
    @State private var confirmDiscardShares = false
    @State private var isDiscardingShares = false
    @State private var shareDiscardFailed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            serverSection
            deviceSection
            shareSection
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // local sizes first - they are instant and must not sit behind a
            // slow server round trip showing zero kb.
            await refreshLocalSizes()
            serverStorage = try? await session.client?.serverStorage()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshShareStorage() } }
        }
    }

    // MARK: - server

    @ViewBuilder private var serverSection: some View {
        if let user = session.user, let quota = user.quotaSizeInBytes, quota > 0 {
            Section("Server") {
                VStack(alignment: .leading, spacing: 8) {
                    let used = user.quotaUsageInBytes ?? 0
                    ProgressView(value: Double(used), total: Double(quota))
                        .tint(.indigo)
                    Text("\(ByteCountFormatStyle().format(used)) of \(ByteCountFormatStyle().format(quota)) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else if let serverStorage {
            Section("Server") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: serverStorage.diskUsagePercentage / 100)
                        .tint(.indigo)
                    Text("\(serverStorage.diskUse) of \(serverStorage.diskSize) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - device

    private var deviceSection: some View {
        Section {
            LabeledContent("Image Cache") {
                Text(byteText(imageBytes))
            }
            LabeledContent("Library Data") {
                Text(byteText(libraryBytes))
            }
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                if isClearing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Clear Cache")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isClearing || imageBytes + libraryBytes == 0)
            .accessibilityIdentifier("storage-clear-cache")
            // ios 26 morphs the dialog out of its source control, so it sits
            // on the button - on the screen root it floats detached.
            .confirmationDialog(
                "Clear \(byteText(imageBytes + libraryBytes)) of cached data?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    Task { await clearCache() }
                }
            } message: {
                Text("Photos download again as you browse, and offline browsing rebuilds on the next launch.")
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("Cached data is re-downloadable and separate from your backed up photos. Videos in use are cleared when playback finishes.")
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private var shareSection: some View {
        Section {
            if let shareStorage {
                LabeledContent(String(localized: "Share Temporary Copies")) {
                    Text(byteText(shareStorage.totalBytes))
                }
                Text(String(localized: "\(shareStorage.records.count) pending shares use \(byteText(shareStorage.knownBytes))."))
                    .font(.subheadline)
                ForEach(shareStorage.records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: record.filename)
                        if record.needsAttention || record.attempts >= 3 {
                            Text(String(localized: "Needs attention. Share this item again from its original source."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if shareStorage.untrackedBytes > 0 {
                    Text(String(localized: "\(byteText(shareStorage.untrackedBytes)) has no readable pending record. These copies may belong to an older share or an extension still preparing files and are kept when pending shares are discarded."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    shareDiscardSnapshot = shareStorage
                    confirmDiscardShares = true
                } label: {
                    if isDiscardingShares { ProgressView() }
                    else { Text(String(localized: "Discard Pending Shares")) }
                }
                .disabled(isDiscardingShares || shareStorage.records.isEmpty)
                .accessibilityIdentifier("storage-discard-pending-shares")
                .confirmationDialog(
                    String(localized: "Discard \(shareDiscardSnapshot?.records.count ?? 0) pending shares and their local temporary copies?"),
                    isPresented: $confirmDiscardShares,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Discard Pending Shares"), role: .destructive) {
                        let records = shareDiscardSnapshot?.records ?? []
                        Task { await discardShares(records) }
                    }
                } message: {
                    Text(String(localized: "This stops these pending uploads and removes their known temporary copies from this device. Original photos and files, existing server files, and copies without readable pending records remain."))
                }
            } else if shareStorageUnavailable {
                Text(String(localized: "Pending share storage is unavailable. Unlock the device and try again."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if shareDiscardFailed {
                Text(String(localized: "Some temporary copies could not be discarded. Review the remaining pending shares and try again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(String(localized: "Refresh Pending Shares")) {
                Task { await refreshShareStorage() }
            }
            .disabled(isDiscardingShares)
        } header: {
            Text(String(localized: "Pending Shares"))
        } footer: {
            Text(String(localized: "These local temporary copies include pending shares from all accounts on this device. Only the account that created a share can resume it while signed in. Shares needing attention must be shared again from their original source. Discarding a pending share cannot recall bytes already sent to the server."))
        }
    }

    private func refreshShareStorage() async {
        let snapshot = await Task.detached(priority: .utility) {
            guard let store = ShareTransfer.queueStore else { return nil as SharePendingStorage.Snapshot? }
            return try? SharePendingStorage.snapshot(store: store)
        }.value
        shareStorage = snapshot
        shareStorageUnavailable = snapshot == nil
    }

    private func discardShares(_ records: [ShareQueueRecord]) async {
        isDiscardingShares = true
        ShareUploadCoordinator.shared.cancelAll()
        let failures = await Task.detached(priority: .userInitiated) {
            guard let store = ShareTransfer.queueStore else { return records.count }
            return SharePendingStorage.discard(records, store: store)
        }.value
        shareDiscardFailed = failures > 0
        await refreshShareStorage()
        isDiscardingShares = false
    }

    private func refreshLocalSizes() async {
        let sizes = await Task.detached(priority: .utility) {
            (
                ImageLoader.shared.diskUsage(),
                TimelineCache.diskUsage() + OfflineCache.diskUsage() + ControlledMediaStore.diskUsage()
            )
        }.value
        imageBytes = sizes.0
        libraryBytes = sizes.1
        await refreshShareStorage()
    }

    private func clearCache() async {
        isClearing = true
        await Task.detached(priority: .userInitiated) {
            ImageLoader.shared.clearCache()
            TimelineCache.removeAll()
            OfflineCache.removeAll()
            ControlledMediaStore.clearCache()
        }.value
        await refreshLocalSizes()
        isClearing = false
    }
}
