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
            Section("Keep Selected Albums") {
                ForEach(albums) { album in
                    Toggle(album.name, isOn: Binding(get: { protectedAlbums.contains(album.id) }, set: { selected in
                        if selected { protectedAlbums.insert(album.id) } else { protectedAlbums.remove(album.id) }
                    }))
                }
                if albums.isEmpty { Text("No local albums available.").foregroundStyle(.secondary) }
            }
            Section {
                Button {
                    scan()
                } label: {
                    if isBusy { Label("Verifying with server...", systemImage: "hourglass") }
                    else { Label("Scan and Preview", systemImage: "doc.text.magnifyingglass") }
                }
                .disabled(isBusy || session.backup == nil)
                .accessibilityIdentifier("cleanup-scan-preview")
                if isBusy { Button("Cancel Verification", role: .cancel) { task?.cancel() } }
            } footer: {
                Text("Only verified server copies can be removed. Unknown dates, cloud-deleted items, and incomplete Live Photos stay on this device.")
            }
            if let report {
                Section("Cleanup Preview") {
                    if let cutoff = report.retention?.cutoff {
                        LabeledContent("Eligible Before", value: cutoff.formatted(date: .complete, time: .shortened))
                    }
                    LabeledContent("Time Zone", value: report.retention?.timeZoneIdentifier ?? TimeZone.current.identifier)
                    LabeledContent("Ready to Remove", value: report.eligibleMedia.text)
                    LabeledContent("Kept on Device", value: report.keptMedia.text)
                    LabeledContent("Estimated Space", value: report.estimatedOriginalBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? String(localized: "not yet known"))
                    ForEach(CleanupRetentionReason.allCases, id: \.self) { reason in
                        if let count = report.retainedReasons[reason], count.total > 0 {
                            LabeledContent(reason.title, value: count.text)
                        }
                    }
                    Text("An item can have more than one reason to keep it. The kept total counts each item once.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Verify and Remove \(report.eligibleMedia.text)", role: .destructive) { confirmation = true }
                        .disabled(report.eligible.isEmpty || isBusy)
                        .accessibilityIdentifier("cleanup-confirm-preview")
                }
            }
            if let outcome { Section { Text(outcome).accessibilityIdentifier("cleanup-outcome") } }
            Section {
                Text("If iCloud Photos is enabled, deleting here also deletes from iCloud and other devices on the same account. Space is released according to the system's Recently Deleted handling.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Clean Up Device")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: policy) { _, _ in task?.cancel(); report = nil; outcome = nil }
        .onDisappear { task?.cancel() }
        .task { loadAlbums() }
        .confirmationDialog("Remove Verified Device Copies?", isPresented: $confirmation, titleVisibility: .visible) {
            if let report {
                Button("Verify and Remove \(report.eligibleMedia.text)", role: .destructive) { remove(report) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Server originals will be read and checked again. Your retention choices will be rechecked before the system deletion confirmation.")
        }
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
            } catch {
                if !Task.isCancelled { ErrorToastCenter.shared.show(String(localized: "Couldn't verify cleanup candidates"), error: error) }
            }
        }
    }

    private func remove(_ preview: CleanupReport) {
        guard let backup = session.backup, preview.retention?.policy == policy else { report = nil; return }
        isBusy = true
        task = Task {
            defer { isBusy = false; report = nil }
            do {
                let result = try await backup.performCleanup(report: preview)
                outcome = String(localized: "Removed \(result.deletedMedia.text). Kept \(result.keptMedia.text).")
            } catch {
                if !Task.isCancelled { ErrorToastCenter.shared.show(String(localized: "Couldn't clean up this device"), error: error) }
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
