import Foundation
import SwiftUI

/// space hogs, blurry and screenshots: pick photos, then keep them out of
/// the queue or trash them. each action is applied at once with an undo, and
/// pages follow the server's cursors as the grid scrolls.
struct CleanupQueueScreen: View {
    @Environment(SessionStore.self) private var session
    let queue: CleanupQueue

    @State private var items: [CleanupAsset] = []
    @State private var cursor: String?
    @State private var isLoading = true
    @State private var count: CleanupQueueCount?
    @State private var filters = CleanupFilters()
    @State private var selection = Set<String>()
    @State private var isBusy = false
    @State private var notice: CleanupNotice?
    @State private var confirmer = CleanupConfirmer()
    @State private var viewer = ViewerPresentation()
    /// bumped by every reset, so a page that lands after one is dropped.
    @State private var generation = 0
    @State private var actions = 0
    @State private var hasLoaded = false
    @Namespace private var zoomNamespace

    private static let pageSize = 90

    private var trashEnabled: Bool { session.features?.trash != false }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: queue == .screenshots ? 104 : 112), spacing: 3)]
    }

    var body: some View {
        @Bindable var viewer = viewer
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                }
                if let count, count.isAnalysing, let percent = count.analysedPercent {
                    Label("Still analyzing, \(Int(percent))% of the library done", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(items) { asset in
                        tile(asset)
                            .onAppear {
                                if asset.id == items.last?.id { Task { await loadMore() } }
                            }
                    }
                }
                if isLoading && !items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(queue.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if items.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "All Clear",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing left to review here.")
                    )
                }
            }
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { selectionBar }
        }
        .cleanupConfirmations(confirmer)
        .cleanupNotice($notice)
        .sensoryFeedback(.selection, trigger: selection.count)
        .sensoryFeedback(.success, trigger: actions)
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                indexByAssetID: route.indexByAssetID,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onRequestDismissal: { viewer.complete(route.id) },
                onDismissed: { viewer.complete(route.id) }
            ) { change in
                if case .removalCommitted(let id) = change { remove([id]) }
                if case .removed(let id) = change { remove([id]) }
            }
        }
        .refreshable { await reload() }
        // the viewer's cover coming down appears the grid again.
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await reload()
        }
        .onChange(of: filters) { Task { await reload() } }
    }

    private var subtitle: String? {
        guard let count, count.count > 0 else { return nil }
        switch queue {
        case .spaceHogs:
            return count.count == 1
                ? String(localized: "Your largest file takes up \(CleanupText.bytes(count.bytes)).")
                : String(localized: "Your \(count.count.formatted()) largest files take up \(CleanupText.bytes(count.bytes)).")
        case .screenshots:
            return count.count == 1
                ? String(localized: "1 screenshot or screen recording, \(CleanupText.bytes(count.bytes)).")
                : String(localized: "\(count.count.formatted()) screenshots and screen recordings, \(CleanupText.bytes(count.bytes)).")
        default:
            return count.count == 1
                ? String(localized: "1 photo looks out of focus, too dark or blown out.")
                : String(localized: "\(count.count.formatted()) photos look out of focus, too dark or blown out.")
        }
    }

    private func tile(_ asset: CleanupAsset) -> some View {
        let isSelected = selection.contains(asset.id)
        return Button {
            if isSelected { selection.remove(asset.id) } else { selection.insert(asset.id) }
        } label: {
            Color.clear
                .aspectRatio(queue == .screenshots ? 0.6 : 1, contentMode: .fit)
                .overlay { CleanupThumbnail(asset: asset) }
                .clipped()
                .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                .overlay(alignment: .bottomLeading) { badge(asset) }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(5)
                    }
                }
                .overlay {
                    if isSelected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .contextMenu {
            Button("View", systemImage: "eye") { open(asset) }
            Button("Keep", systemImage: "checkmark.circle") { Task { await keep([asset.id]) } }
            Button(trashEnabled ? "Move to Trash" : "Delete Permanently",
                   systemImage: trashEnabled ? "trash" : "trash.slash",
                   role: .destructive) {
                Task { await trash([asset.id]) }
            }
        }
        .accessibilityLabel(asset.originalFileName)
        .accessibilityValue(asset.dateText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func badge(_ asset: CleanupAsset) -> some View {
        let text: String? = switch queue {
        case .spaceHogs: CleanupText.bytes(asset.fileSize)
        case .blurry: asset.reason.flatMap { $0 == .all ? nil : $0.title }
        default: nil
        }
        if let text {
            Text(text)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.5), in: .capsule)
                .padding(5)
        } else if asset.isVideo {
            Image(systemName: "video.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(6)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await keep(Array(selection)) }
            } label: {
                Label("Keep", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cleanup-keep-selected")
            Button(role: .destructive) {
                Task { await trash(Array(selection)) }
            } label: {
                Label(trashEnabled ? "Trash \(selection.count)" : "Delete \(selection.count)",
                      systemImage: trashEnabled ? "trash" : "trash.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("cleanup-trash-selected")
        }
        .controlSize(.large)
        .disabled(isBusy)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                if selection.count == items.count {
                    Button("Deselect All") { selection.removeAll() }
                } else {
                    Button("Select All") { selection = Set(items.map(\.id)) }
                }
            }
        }
        if queue == .blurry || queue == .spaceHogs {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
    }

    @ViewBuilder private var filterMenu: some View {
        Menu {
            if queue == .blurry {
                Picker("Reason", selection: $filters.reason) {
                    ForEach(CleanupBlurReason.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Strictness", selection: $filters.strictness) {
                    ForEach(CleanupStrictness.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Include Photos with Faces", isOn: Binding(
                    get: { !filters.hideFaces },
                    set: { filters.hideFaces = !$0 }
                ))
            } else {
                Picker("Type", selection: $filters.media) {
                    ForEach(CleanupMediaFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Minimum Size", selection: $filters.minSize) {
                    ForEach(CleanupFilters.minSizes, id: \.self) { Text("\(CleanupText.bytes($0)) or More").tag($0) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: filters == CleanupFilters() ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filters")
    }

    // MARK: loading

    private func reload() async {
        generation += 1
        let run = generation
        guard let client = session.client else { return }
        isLoading = true
        selection.removeAll()
        async let counted = try? client.cleanupCount(queue, filters: filters)
        do {
            let page = try await client.cleanupPage(queue, filters: filters, limit: Self.pageSize)
            guard run == generation else { return }
            items = page.items
            cursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            if run == generation { ErrorToastCenter.shared.show(String(localized: "Couldn't load \(queue.title.lowercased())"), error: error) }
        }
        let fresh = await counted
        guard run == generation else { return }
        count = fresh ?? count
        isLoading = false
    }

    private func loadMore() async {
        guard let client = session.client, let cursor, !isLoading else { return }
        let run = generation
        isLoading = true
        defer { if run == generation { isLoading = false } }
        do {
            let page = try await client.cleanupPage(queue, filters: filters, cursor: cursor, limit: Self.pageSize)
            guard run == generation else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            self.cursor = page.nextCursor
        } catch {
            if run == generation { ErrorToastCenter.shared.show(String(localized: "Couldn't load more photos"), error: error) }
        }
    }

    private func refreshCount() async {
        guard let client = session.client else { return }
        if let fresh = try? await client.cleanupCount(queue, filters: filters) { count = fresh }
    }

    // MARK: actions

    private func remove(_ ids: [String]) {
        let gone = Set(ids)
        withAnimation(.smooth) { items.removeAll { gone.contains($0.id) } }
        selection.subtract(gone)
    }

    private func keep(_ ids: [String]) async {
        guard let client = session.client, !ids.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for batch in ids.cleanupBatches {
                _ = try await client.cleanupCommit(CleanupCommit(queue: queue, keepIds: batch))
            }
            remove(ids)
            actions += 1
            notice = CleanupNotice(message: String(localized: "Kept \(CleanupText.count(ids.count, unit: .photo))")) {
                do {
                    for batch in ids.cleanupBatches { try await client.cleanupForget(queue: queue, assetIDs: batch) }
                    await reload()
                } catch {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't undo"), error: error)
                }
            }
            await refreshCount()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't keep the photos"), error: error)
        }
    }

    private func trash(_ ids: [String]) async {
        guard let client = session.client, !ids.isEmpty, !isBusy else { return }
        let trashEnabled = trashEnabled
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await confirmer.confirmTrash(ids, trashEnabled: trashEnabled, client: client) else { return }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't check the photos before trashing. Nothing was changed."))
            return
        }
        var trashed: [String] = []
        var skipped: [String] = []
        do {
            for batch in ids.cleanupBatches {
                let result = try await client.cleanupCommit(CleanupCommit(queue: queue, trashIds: batch))
                trashed += result.trashed
                skipped += result.skipped.map(\.id)
            }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't delete the photos"), error: error)
        }
        remove(trashed + skipped)
        guard !trashed.isEmpty || !skipped.isEmpty else { return }
        actions += 1
        let removed = trashed
        var undo: (@MainActor () async -> Void)?
        if trashEnabled {
            undo = {
                do {
                    for batch in removed.cleanupBatches { try await client.restoreAssets(ids: batch) }
                    await reload()
                } catch {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't restore the photos"), error: error)
                }
            }
        }
        notice = CleanupText.skipped(skipped.count).map { CleanupNotice(message: $0) }
            ?? CleanupNotice(message: CleanupText.removed(removed.count, trashEnabled: trashEnabled), undo: undo)
        await refreshCount()
    }

    private func open(_ asset: CleanupAsset) {
        guard let index = items.firstIndex(where: { $0.id == asset.id }) else { return }
        let owner = session.user?.id ?? ""
        viewer.present(assets: items.map { $0.asAsset(ownerID: owner) }, initialIndex: index)
    }
}
