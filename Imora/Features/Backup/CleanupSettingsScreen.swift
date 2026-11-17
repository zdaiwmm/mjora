import Photos
import SwiftUI

struct CleanupSettingsScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var days = 30
    @State private var customDate = Date()
    @State private var preserveFavorites = true
    @State private var protectedAlbums: Set<String> = []
    @State private var albums: [AlbumOption] = []
    @State private var report: CleanupReport?
    @State private var task: Task<Void, Never>?
    @State private var isBusy = false
    @State private var confirmation = false
    @State private var showsPreview = false
    @State private var outcome: String?

    private struct AlbumOption: Identifiable { let id: String; let name: String }
    private var policy: CleanupRetentionPolicy {
        .init(retentionDays: days > 0 ? days : nil, customStartDate: days == -1 ? customDate : nil,
              preserveFavorites: preserveFavorites, protectedAlbumIDs: protectedAlbums)
    }

    var body: some View {
        List {
            Section("Keep on This Device") {
                Picker("Keep Recent Items", selection: $days) {
                    ForEach([7, 30, 90, 180, 365], id: \.self) { Text("Last \($0) days").tag($0) }
                    Text("Custom Start Date").tag(-1)
                    Text("No Time Limit").tag(0)
                }
                .accessibilityIdentifier("cleanup-retention-days")
                if days == -1 { DatePicker("Keep Items From", selection: $customDate, displayedComponents: .date) }
                Toggle("Keep Favorites", isOn: $preserveFavorites)
                    .accessibilityIdentifier("cleanup-keep-favorites")
            }
            .disabled(isBusy)
            Section("Keep Selected Albums") {
                ForEach(albums) { album in
                    Toggle(album.name, isOn: Binding(get: { protectedAlbums.contains(album.id) }, set: { selected in
                        if selected { protectedAlbums.insert(album.id) } else { protectedAlbums.remove(album.id) }
                    }))
                }
                if albums.isEmpty { Text("No local albums available.").foregroundStyle(.secondary) }
            }
            .disabled(isBusy)
            Section {
                Button(action: scan) {
                    if isBusy { ProgressView("Verifying with server...") }
                    else { Label("Scan and Preview", systemImage: "doc.text.magnifyingglass") }
                }
                .disabled(isBusy || session.backup == nil)
                .accessibilityIdentifier("cleanup-scan-preview")
                if isBusy { Button("Cancel Verification", role: .cancel) { task?.cancel() } }
            }
        }
        .navigationTitle("Clean Up Device")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: policy) { _, _ in task?.cancel(); report = nil; outcome = nil; showsPreview = false }
        .onDisappear { task?.cancel() }
        .task { loadAlbums() }
        .navigationDestination(isPresented: $showsPreview) { previewScreen }
    }

    private var previewScreen: some View {
        List {
            if let outcome {
                Section {
                    Label("Cleanup Complete", systemImage: "checkmark.circle")
                    Text(outcome).accessibilityIdentifier("cleanup-outcome")
                }
            } else if let report {
                Section {
                    LabeledContent("Ready to Remove", value: report.eligibleMedia.text)
                    LabeledContent("Kept on Device", value: report.keptMedia.text)
                    LabeledContent("Estimated Space", value: report.estimatedOriginalBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? String(localized: "not yet known"))
                }
                Section {
                    if let cutoff = report.retention?.cutoff {
                        LabeledContent("Eligible Before", value: cutoff.formatted(date: .complete, time: .shortened))
                    }
                    DisclosureGroup("Retention Details") {
                        ForEach(CleanupRetentionReason.allCases, id: \.self) { reason in
                            if let count = report.retainedReasons[reason], count.total > 0 {
                                LabeledContent(reason.title, value: count.text)
                            }
                        }
                    }
                }
                Section {
                    Button("Verify and Remove \(report.eligibleMedia.text)", role: .destructive) { confirmation = true }
                        .disabled(report.eligible.isEmpty || isBusy)
                        .accessibilityIdentifier("cleanup-confirm-preview")
                        .confirmationDialog("Remove Verified Device Copies?", isPresented: $confirmation, titleVisibility: .visible) {
                            Button("Verify and Remove \(report.eligibleMedia.text)", role: .destructive) { remove(report) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Device copies will be removed after verification. If iCloud Photos is enabled, this also removes them from iCloud and synced devices.")
                        }
                    if isBusy {
                        ProgressView("Verifying with server...")
                        Button("Cancel Verification", role: .cancel) { task?.cancel() }
                    }
                }
            }
        }
        .navigationTitle(outcome == nil ? String(localized: "Cleanup Preview") : String(localized: "Cleanup Complete"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private func loadAlbums() {
        guard PhotoLibraryService.hasFullAccess else { return }
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums = (0..<result.count).map { index in
            let album = result.object(at: index)
            return AlbumOption(id: album.localIdentifier, name: album.localizedTitle ?? String(localized: "Album"))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func scan() {
        guard let backup = session.backup else { return }
        let selectedPolicy = policy
        report = nil; outcome = nil; isBusy = true
        task = Task {
            defer { isBusy = false }
            do {
                let preview = try await backup.cleanUpCandidates(retentionPolicy: selectedPolicy)
                try Task.checkCancellation()
                guard policy == selectedPolicy else { return }
                report = preview
                showsPreview = true
            } catch {
                if !Task.isCancelled { ErrorToastCenter.shared.show(String(localized: "Couldn't verify cleanup candidates"), error: error) }
            }
        }
    }

    private func remove(_ preview: CleanupReport) {
        guard let backup = session.backup, preview.retention?.policy == policy else { report = nil; showsPreview = false; return }
        isBusy = true
        task = Task {
            defer { isBusy = false; report = nil }
            do {
                let result = try await backup.performCleanup(report: preview)
                outcome = String(localized: "Removed \(result.deletedMedia.text). Kept \(result.keptMedia.text).")
            } catch {
                showsPreview = false
                if !Task.isCancelled && !PhotoLibraryService.isUserCancelled(error) { ErrorToastCenter.shared.show(String(localized: "Couldn't clean up this device"), error: error) }
            }
        }
    }
}

private extension CleanupRetentionReason {
    var title: String {
        switch self {
        case .recent: String(localized: "Recent Items")
        case .favorite: String(localized: "Favorites")
        case .album: String(localized: "Protected Albums")
        case .unknownDate: String(localized: "Unknown Date")
        case .unverified: String(localized: "Not Verified")
        case .cloudDeleted: String(localized: "Deleted in Cloud")
        }
    }
}
