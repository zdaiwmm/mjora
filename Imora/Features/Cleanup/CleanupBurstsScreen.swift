import Foundation
import SwiftUI

/// series shot within seconds of each other: per photo keep or trash, the
/// sharpest suggested to keep, or the whole series stacked instead.
struct CleanupBurstsScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var groups: [CleanupBurstGroup] = []
    @State private var cursor: String?
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var count: CleanupQueueCount?
    /// a photo's mark once the user changed it, else the suggestion decides.
    @State private var overrides: [String: CleanupMark] = [:]
    /// the frame shown large, per series.
    @State private var focused: [String: String] = [:]
    @State private var isBusy = false
    @State private var notice: CleanupNotice?
    @State private var confirmer = CleanupConfirmer()
    @State private var viewer = ViewerPresentation()
    @State private var generation = 0
    @State private var toggles = 0
    @State private var actions = 0
    @Namespace private var zoomNamespace

    private static let pageSize = 20

    private var trashEnabled: Bool { session.features?.trash != false }

    private var suggestedBytes: Int64 {
        groups.reduce(0) { sum, group in
            sum + group.assets.filter { $0.id != group.suggestedKeepId }.reduce(0) { $0 + $1.fileSize }
        }
    }

    var body: some View {
        @Bindable var viewer = viewer
        List {
            if let count, count.count > 0 {
                Section {
                } footer: {
                    Text(String(localized: "Up to \(CleanupText.count(count.count, unit: .series)). Pick the best, trash the rest, and free up to \(CleanupText.bytes(count.bytes))."))
                }
            }
            ForEach(groups) { group in
                Section {
                    groupCard(group)
                        .onAppear {
                            if group.id == groups.last?.id { Task { await loadMore() } }
                        }
                }
            }
            if isLoading && !groups.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Bursts")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if groups.isEmpty {
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
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(
                            "Accept Suggestions, Free \(CleanupText.bytes(suggestedBytes))",
                            systemImage: "wand.and.stars"
                        ) {
                            Task { await resolve(groups, decide: suggested) }
                        }
                        Button("Keep Everything Shown", systemImage: "checkmark.circle") {
                            Task { await resolve(groups) { group in (group.assets.map(\.id), []) } }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                    .disabled(isBusy)
                }
            }
        }
        .cleanupConfirmations(confirmer)
        .cleanupNotice($notice)
        .sensoryFeedback(.selection, trigger: toggles)
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
                if case .removalCommitted(let id) = change { removeAssets([id]) }
                if case .removed(let id) = change { removeAssets([id]) }
            }
        }
        .refreshable { await reload() }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await reload()
        }
    }

    // MARK: series card

    private func mark(_ asset: CleanupAsset, in group: CleanupBurstGroup) -> CleanupMark {
        overrides[asset.id] ?? (asset.id == group.suggestedKeepId ? .keep : .trash)
    }

    private func decision(_ group: CleanupBurstGroup) -> (keep: [String], trash: [String]) {
        var keep: [String] = []
        var trash: [String] = []
        for asset in group.assets {
            if mark(asset, in: group) == .keep { keep.append(asset.id) } else { trash.append(asset.id) }
        }
        return (keep, trash)
    }

    private func suggested(_ group: CleanupBurstGroup) -> (keep: [String], trash: [String]) {
        (
            [group.suggestedKeepId],
            group.assets.map(\.id).filter { $0 != group.suggestedKeepId }
        )
    }

    private func frame(_ group: CleanupBurstGroup) -> CleanupAsset? {
        group.assets.first { $0.id == focused[group.id] }
            ?? group.assets.first { $0.id == group.suggestedKeepId }
            ?? group.assets.first
    }

    private func seconds(_ group: CleanupBurstGroup) -> String {
        let dates = group.assets.map(\.localDate)
        guard let first = dates.min(), let last = dates.max() else { return "0" }
        return last.timeIntervalSince(first).formatted(.number.precision(.fractionLength(0...1)))
    }

    private func groupCard(_ group: CleanupBurstGroup) -> some View {
        let decided = decision(group)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "\(CleanupText.count(group.assets.count, unit: .photo)) in \(seconds(group)) s"))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(group.isCameraBurst ? String(localized: "Camera burst") : String(localized: "Same moment, visually similar")), \(group.assets.first?.dateText ?? "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let frame = frame(group) {
                Button {
                    open(frame, in: group)
                } label: {
                    Color.clear
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay { CleanupThumbnail(asset: frame, size: "preview", targetPixelSize: 1200) }
                        .clipShape(.rect(cornerRadius: 16))
                        .matchedTransitionSource(id: frame.id, in: zoomNamespace)
                        .overlay(alignment: .topLeading) {
                            if frame.id == group.suggestedKeepId {
                                Text("Suggested")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .glassEffect(.regular, in: .capsule)
                                    .padding(10)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            markBadge(mark(frame, in: group))
                                .padding(10)
                        }
                        .contentShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(frame.originalFileName)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.assets) { asset in
                        strip(asset, in: group)
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Tap a photo to keep or trash it. You can keep more than one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    Task { await resolve([group], decide: decision) }
                } label: {
                    Text(applyTitle(decided))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(decided.trash.isEmpty ? .accentColor : .red)
                Button("Keep All") {
                    Task { await resolve([group]) { group in (group.assets.map(\.id), []) } }
                }
                .buttonStyle(.bordered)
                Button("Stack", systemImage: "square.stack.3d.down.right") {
                    Task { await stack(group) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stack Instead")
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 6)
    }

    private func applyTitle(_ decided: (keep: [String], trash: [String])) -> String {
        let verb = trashEnabled ? String(localized: "Move to Trash") : String(localized: "Delete")
        if decided.trash.isEmpty { return String(localized: "Keep All \(decided.keep.count)") }
        if decided.keep.isEmpty { return String(localized: "\(verb) All \(decided.trash.count)") }
        return String(localized: "Keep \(decided.keep.count), \(verb) \(decided.trash.count)")
    }

    private func strip(_ asset: CleanupAsset, in group: CleanupBurstGroup) -> some View {
        let current = mark(asset, in: group)
        let isFocused = frame(group)?.id == asset.id
        return Button {
            focused[group.id] = asset.id
            overrides[asset.id] = current == .keep ? .trash : .keep
            toggles += 1
        } label: {
            CleanupThumbnail(asset: asset)
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 10))
                .opacity(current == .keep ? 1 : 0.55)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(current == .keep ? Color.green : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: current == .keep ? "checkmark.circle.fill" : "trash.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, current == .keep ? Color.green : .red)
                        .padding(3)
                }
                .padding(2)
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("View", systemImage: "eye") { open(asset, in: group) }
        }
        .accessibilityLabel(asset.originalFileName)
        .accessibilityValue(current == .keep ? "Keep" : (trashEnabled ? "Trash" : "Delete"))
        .accessibilityHint("Switches between keep and trash.")
    }

    private func markBadge(_ mark: CleanupMark) -> some View {
        let keeps = mark == .keep
        return Label(keeps ? "Keep" : (trashEnabled ? "Trash" : "Delete"), systemImage: keeps ? "checkmark" : "trash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(keeps ? Color.green : .red, in: .capsule)
    }

    // MARK: loading

    private func reload() async {
        generation += 1
        let run = generation
        guard let client = session.client else { return }
        isLoading = true
        async let counted = try? client.cleanupCount(.bursts)
        do {
            let page = try await client.cleanupPage(.bursts, limit: Self.pageSize)
            guard run == generation else { return }
            groups = page.groups
            cursor = page.nextCursor
            overrides.removeAll()
            focused.removeAll()
        } catch is CancellationError {
        } catch {
            if run == generation { ErrorToastCenter.shared.show(String(localized: "Couldn't load the bursts"), error: error) }
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
            let page = try await client.cleanupPage(.bursts, cursor: cursor, limit: Self.pageSize)
            guard run == generation else { return }
            let known = Set(groups.map(\.id))
            groups += page.groups.filter { !known.contains($0.id) }
            self.cursor = page.nextCursor
        } catch {
            if run == generation { ErrorToastCenter.shared.show(String(localized: "Couldn't load more bursts"), error: error) }
        }
    }

    private func refreshCount() async {
        guard let client = session.client else { return }
        if let fresh = try? await client.cleanupCount(.bursts) { count = fresh }
    }

    // MARK: actions

    private func removeAssets(_ ids: [String]) {
        let gone = Set(ids)
        withAnimation(.smooth) {
            groups = groups
                .map { group in
                    var group = group
                    group.assets.removeAll { gone.contains($0.id) }
                    return group
                }
                .filter { $0.assets.count >= 2 }
        }
    }

    private func resolve(
        _ targets: [CleanupBurstGroup],
        decide: (CleanupBurstGroup) -> (keep: [String], trash: [String])
    ) async {
        guard let client = session.client, !targets.isEmpty, !isBusy else { return }
        var keep: [String] = []
        var trash: [String] = []
        for group in targets {
            let decided = decide(group)
            keep += decided.keep
            trash += decided.trash
        }
        let trashEnabled = trashEnabled
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await confirmer.confirmTrash(trash, trashEnabled: trashEnabled, client: client) else { return }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't check the photos before trashing. Nothing was changed."))
            return
        }
        let trashBatches = trash.cleanupBatches
        let keepBatches = keep.cleanupBatches
        var trashed: [String] = []
        var kept: [String] = []
        var skipped = 0
        do {
            for index in 0..<max(trashBatches.count, keepBatches.count) {
                let trashIDs = trashBatches.indices.contains(index) ? trashBatches[index] : []
                let keepIDs = keepBatches.indices.contains(index) ? keepBatches[index] : []
                let result = try await client.cleanupCommit(CleanupCommit(
                    queue: .bursts,
                    trashIds: trashIDs.isEmpty ? nil : trashIDs,
                    keepIds: keepIDs.isEmpty ? nil : keepIDs
                ))
                trashed += result.trashed
                kept += keepIDs
                skipped += result.skipped.count
            }
        } catch {
            ErrorToastCenter.shared.show(trash.isEmpty ? String(localized: "Couldn't keep the photos") : String(localized: "Couldn't delete the photos"), error: error)
            await reload()
            return
        }
        let done = Set(targets.map(\.id))
        withAnimation(.smooth) { groups.removeAll { done.contains($0.id) } }
        for group in targets {
            focused[group.id] = nil
            for asset in group.assets { overrides[asset.id] = nil }
        }
        actions += 1
        let removed = trashed
        let forgotten = kept
        var undo: (@MainActor () async -> Void)?
        if removed.isEmpty || trashEnabled {
            undo = {
                do {
                    for batch in removed.cleanupBatches { try await client.restoreAssets(ids: batch) }
                    for batch in forgotten.cleanupBatches { try await client.cleanupForget(queue: .bursts, assetIDs: batch) }
                    await reload()
                } catch {
                    ErrorToastCenter.shared.show(String(localized: "Couldn't undo"), error: error)
                }
            }
        }
        let message = removed.isEmpty
            ? String(localized: "Kept \(CleanupText.count(forgotten.count, unit: .photo))")
            : CleanupText.removed(removed.count, trashEnabled: trashEnabled)
        notice = CleanupText.skipped(skipped).map { CleanupNotice(message: $0) }
            ?? CleanupNotice(message: message, undo: undo)
        await refreshCount()
    }

    /// keeps every photo as one stack. the photo kept, or else the suggestion, leads it.
    private func stack(_ group: CleanupBurstGroup) async {
        guard let client = session.client, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let primary = decision(group).keep.first ?? group.suggestedKeepId
        let ids = [primary] + group.assets.map(\.id).filter { $0 != primary }
        do {
            try await client.createStack(assetIDs: ids)
            withAnimation(.smooth) { groups.removeAll { $0.id == group.id } }
            actions += 1
            notice = CleanupNotice(message: String(localized: "Stacked \(CleanupText.count(ids.count, unit: .photo))"))
            await refreshCount()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't stack the photos"), error: error)
        }
    }

    private func open(_ asset: CleanupAsset, in group: CleanupBurstGroup) {
        guard let index = group.assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let owner = session.user?.id ?? ""
        viewer.present(assets: group.assets.map { $0.asAsset(ownerID: owner) }, initialIndex: index)
    }
}
