import Foundation
import SwiftUI

nonisolated struct AlbumMembershipUpdate: Equatable {
    nonisolated enum Change: Equatable {
        case project(Album)
        case commit(Album)
        case rollback(String)
        case replace(String, Album)
    }

    let id = UUID()
    let operationID: UUID
    let assetID: String
    let change: Change
}

/// App albums are cloud albums. Local items cross that boundary only through
/// the explicit backup confirmation, never while opening/browsing this sheet.
struct AddToAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    @State private var selection: AlbumAddSelection
    private var assetIDs: [String] { selection.assetIDs }
    private var localIdentifiers: [String] { selection.localIdentifiers }
    private var sourceAccountGeneration: UUID? { selection.accountGeneration }
    let onMembershipUpdate: (AlbumMembershipUpdate) -> Void
    let onDone: (String) -> Void

    init(assetIDs: [String], localIdentifiers: [String] = [], sourceAccountGeneration: UUID? = nil,
         onMembershipUpdate: @escaping (AlbumMembershipUpdate) -> Void = { _ in }, onDone: @escaping (String) -> Void) {
        _selection = State(initialValue: AlbumAddSelection(assetIDs: assetIDs,
            localIdentifiers: localIdentifiers, accountGeneration: sourceAccountGeneration))
        self.onMembershipUpdate = onMembershipUpdate; self.onDone = onDone
    }

    private enum Action { case add(Album), create(String) }
    @State private var albums: [Album] = []
    @State private var containingIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var query = ""
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var preparation: AlbumBackupPreparation?
    @State private var consentGeneration: UUID?
    @State private var pendingAction: Action?
    @State private var showBackupConfirmation = false
    @State private var completedBackupCount = 0
    @State private var errorMessage: String?
    @State private var creationNeedsReview = false

    private var isCurrentAccount: Bool {
        guard let generation = preparation?.accountGeneration, let client = session.client else { return false }
        return client.context.isActive && client.context.id == generation
    }
    private var localCount: Int { Set(localIdentifiers).count }
    private var visibleAlbums: [Album] {
        query.isEmpty ? albums : albums.filter { $0.albumName.localizedCaseInsensitiveContains(query) }
    }
    private var isCreating: Bool { if case .create = pendingAction { true } else { false } }

    var body: some View {
        NavigationStack {
            List {
                if !localIdentifiers.isEmpty {
                    Section {
                        Text("App albums are stored on your server. Device items must be backed up before they can be added.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if isWorking {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(completedBackupCount < localCount
                                     ? String(localized: "Backing Up \(min(completedBackupCount + 1, localCount)) of \(localCount)")
                                     : String(localized: "Adding to App Album…"))
                                ProgressView(value: Double(completedBackupCount), total: Double(max(localCount, 1)))
                            }
                            .accessibilityIdentifier("album-backup-progress")
                        } else if completedBackupCount > 0 {
                            Text("\(completedBackupCount) of \(localCount) items backed up. Completed backups are kept for retry.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button { showNewAlbum = true } label: { Label("New Album", systemImage: "plus") }
                        .disabled(isWorking || isLoading || !isCurrentAccount)
                        .accessibilityIdentifier("add-to-album-new")
                        .alert("New Album", isPresented: $showNewAlbum) {
                            TextField("Album name", text: $newAlbumName)
                            Button(localIdentifiers.isEmpty ? String(localized: "Create") : String(localized: "Continue")) {
                                choose(.create(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            .disabled(isWorking || newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel", role: .cancel) {}
                        }
                }
                Section {
                    ForEach(visibleAlbums) { album in albumRow(album) }
                } footer: {
                    if !isLoading, albums.isEmpty { Text("No albums yet. Create one to get started.") }
                }
            }
            .overlay { if isLoading { ProgressView() } }
            .searchable(text: $query, prompt: "Search albums")
            .navigationTitle(localIdentifiers.isEmpty ? String(localized: "Add to Album") : String(localized: "Add to App Album"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isWorking) }
            }
            .task { await load() }
            .confirmationDialog(isCreating ? String(localized: "Back Up and Create Album") : String(localized: "Back Up and Add to Album"),
                                isPresented: $showBackupConfirmation, titleVisibility: .visible) {
                Button(isCreating ? String(localized: "Back Up and Create Album") : String(localized: "Back Up and Add to Album")) {
                    guard isCurrentAccount, let action = pendingAction else { return }
                    consentGeneration = preparation?.accountGeneration
                    Task { await perform(action) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will back up the selected device items to your server, then add them to the App album.")
            }
            .alert("Couldn't Add to Album", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                if creationNeedsReview {
                    Button("Refresh App Albums") {
                        creationNeedsReview = false; pendingAction = nil
                        Task { await load() }
                    }
                } else if isCurrentAccount {
                    Button("Try Again") {
                        if let action = pendingAction { Task { await perform(action) } }
                        else { Task { await load() } }
                    }
                }
                Button("Keep Selection", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onChange(of: session.client?.context.id) {
                if preparation != nil && !isCurrentAccount { errorMessage = AlbumBackupPreparation.Failure.accountChanged.localizedDescription }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func albumRow(_ album: Album) -> some View {
        let alreadyIn = localIdentifiers.isEmpty && assetIDs.count == 1 && containingIDs.contains(album.id)
        return Button { choose(.add(album)) } label: {
            HStack(spacing: 12) {
                if let client = session.client, let cover = album.albumThumbnailAssetId {
                    RemoteImage(url: client.thumbnailURL(assetID: cover), targetPixelSize: 120)
                        .frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 48, height: 48)
                        .overlay { Image(systemName: "rectangle.stack").foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.albumName).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("^[\(album.assetCount) item](inflect: true)")
                        if album.shared { Text("·"); Text("Shared") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyIn { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
            }
        }
        .disabled(alreadyIn || isWorking || !isCurrentAccount)
    }

    private func choose(_ action: Action) {
        guard !isWorking, isCurrentAccount else { return }
        pendingAction = action
        creationNeedsReview = false
        if !localIdentifiers.isEmpty && consentGeneration != preparation?.accountGeneration {
            showBackupConfirmation = true
        } else { Task { await perform(action) } }
    }

    private func load() async {
        defer { isLoading = false }
        guard let client = session.client else { errorMessage = String(localized: "Connect to your server to choose an App album."); return }
        if preparation == nil {
            preparation = AlbumBackupPreparation(localIdentifiers: localIdentifiers, accountGeneration: sourceAccountGeneration ?? client.context.id)
        }
        guard isCurrentAccount else { errorMessage = AlbumBackupPreparation.Failure.accountChanged.localizedDescription; return }
        if albums.isEmpty, let account = client.offlineAccountKey {
            let cached = await Task.detached(priority: .userInitiated) { OfflineCache.value([Album].self, key: "albums", account: account) }.value
            guard isCurrentAccount else { return }
            if let cached, albums.isEmpty { albums = cached.filter { !$0.isPending }.sorted { $0.updatedAt > $1.updatedAt } }
        }
        async let allTask = try? client.albums()
        async let containingTask: [Album]? = localIdentifiers.isEmpty && assetIDs.count == 1 ? (try? await client.albums(assetID: assetIDs[0])) : nil
        let all = await allTask, containing = await containingTask ?? []
        guard isCurrentAccount else { return }
        if let all { albums = all.sorted { $0.updatedAt > $1.updatedAt } }
        else if albums.isEmpty { errorMessage = String(localized: "App albums couldn't be loaded. Your selection is kept.") }
        containingIDs = Set(containing.map(\.id))
    }

    private func prepare<Result>(client: ImoraClient, operation: ([String]) async throws -> Result) async throws -> Result {
        guard let preparation, isCurrentAccount else { throw AlbumBackupPreparation.Failure.accountChanged }
        let backup = session.backup
        return try await preparation.perform(assetIDs: assetIDs, consent: consentGeneration,
            isCurrent: { isCurrentAccount && session.client?.context.id == client.context.id },
            backup: { id in
                guard let backup else { throw ImoraError.http(0, String(localized: "Backup is unavailable. Reconnect to your server and try again.")) }
                return try await backup.backUp(localIdentifier: id)
            }, verify: { local, remote in
                guard let backup, backup.hasVerifiedBackup(localIdentifier: local) else { return false }
                return await backup.remoteIdentifier(forLocal: local) == remote
            }, progress: { completed, _ in completedBackupCount = completed }, operation: operation)
    }

    private func perform(_ action: Action) async {
        guard !isWorking, isCurrentAccount, let client = session.client else { return }
        isWorking = true
        defer { isWorking = false }
        let operationID = UUID()
        var projected: Album?
        var projectedIDs: [String] = []
        var original: Album?
        do {
            switch action {
            case .add(let selected):
                let album = albums.first { $0.id == selected.id } ?? selected
                original = album
                let results = try await prepare(client: client) { ids in
                    projectedIDs = ids
                    let optimistic = album.withAssetCountDelta(ids.count)
                    projected = optimistic
                    replaceAlbum(id: album.id, with: optimistic)
                    emit(.project(optimistic), operationID: operationID, ids: ids)
                    return try await client.addAssets(albumID: album.id, ids: ids)
                }
                let outcome = BulkMutationOutcome(requestedIDs: Set(projectedIDs), results: results)
                let accepted = outcome.successfulIDs.union(outcome.duplicateIDs)
                let updated = album.withAssetCountDelta(outcome.successfulIDs.count)
                replaceAlbum(id: album.id, with: updated)
                emit(.commit(updated), operationID: operationID, ids: Array(accepted))
                emit(.rollback(album.id), operationID: operationID, ids: Array(outcome.failedIDs))
                if !outcome.failedIDs.isEmpty {
                    pendingAction = .add(updated)
                    errorMessage = String(localized: "Some items couldn't be added. Your selection and completed backups are kept. Try again.")
                    return
                }
                containingIDs.insert(album.id)
                onDone(outcome.successfulIDs.isEmpty ? String(localized: "Already in \(album.albumName)") : String(localized: "Added to \(album.albumName)"))
            case .create(let name):
                guard !name.isEmpty else { return }
                let saved = try await prepare(client: client) { ids in
                    projectedIDs = ids
                    let pending = Album.pending(name: name, assetCount: ids.count)
                    projected = pending
                    albums.insert(pending, at: 0)
                    emit(.project(pending), operationID: operationID, ids: ids)
                    return try await client.createAlbum(name: name, assetIds: ids)
                }
                if let projected { replaceAlbum(id: projected.id, with: saved); emit(.replace(projected.id, saved), operationID: operationID, ids: projectedIDs) }
                containingIDs.insert(saved.id)
                newAlbumName = ""
                onDone(String(localized: "Added to \(saved.albumName)"))
            }
            dismiss()
        } catch {
            if isCurrentAccount, let projected {
                if let original { replaceAlbum(id: original.id, with: original) }
                else { albums.removeAll { $0.id == projected.id } }
                emit(.rollback(projected.id), operationID: operationID, ids: projectedIDs)
            }
            if case .create = action, projected != nil {
                creationNeedsReview = true
                errorMessage = String(localized: "Album creation couldn't be confirmed. Check App albums before creating it again. Your name, selection and completed backups are kept.")
            } else { errorMessage = error.localizedDescription }
        }
    }

    private func replaceAlbum(id: String, with replacement: Album) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index] = replacement
    }

    private func emit(_ change: AlbumMembershipUpdate.Change, operationID: UUID, ids: [String]) {
        for id in ids { onMembershipUpdate(AlbumMembershipUpdate(operationID: operationID, assetID: id, change: change)) }
    }
}
