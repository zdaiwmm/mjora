import Foundation
import SwiftUI

/// reviews the groups the duplicate detection job found: keep the photos you
/// want, trash the rest, or mark a group as not duplicates.
struct DuplicatesScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var groups: [DuplicateGroup] = []
    /// per group, the photos to keep. starts on the server's suggestion.
    @State private var keep: [String: Set<String>] = [:]
    @State private var isLoading = true
    @State private var workingIDs = Set<String>()
    @State private var confirmResolveAll = false

    private var trashEnabled: Bool { session.features?.trash != false }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    groupRow(group)
                } footer: {
                    let kept = keep[group.id]?.count ?? 0
                    Text(String(localized: "Keeping \(kept) of \(group.assets.count). ")
                         + (trashEnabled ? String(localized: "The others move to the trash.") : String(localized: "The others are deleted for good.")))
                }
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if groups.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Duplicates",
                        systemImage: "checkmark.circle",
                        description: Text("Near identical photos show up here once the server finds them.")
                    )
                }
            }
        }
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Resolve All") { confirmResolveAll = true }
                        .disabled(!workingIDs.isEmpty)
                }
            }
        }
        .confirmationDialog("Keep the suggested photos of every group?", isPresented: $confirmResolveAll,
                            titleVisibility: .visible) {
            Button(trashEnabled ? "Keep Suggested and Trash Others" : "Keep Suggested and Delete Others",
                   role: .destructive) {
                Task { await resolve(groups, keepingSuggested: true) }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.assets) { asset in
                        DuplicateCandidate(
                            asset: asset,
                            isKept: keep[group.id]?.contains(asset.id) == true
                        ) {
                            toggle(asset.id, in: group.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Not Duplicates") { Task { await dismiss(group) } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Keep Selected") { Task { await resolve([group], keepingSuggested: false) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(keep[group.id]?.isEmpty != false)
            }
            .disabled(workingIDs.contains(group.id))
        }
    }

    private func toggle(_ assetID: String, in groupID: String) {
        var set = keep[groupID] ?? []
        if set.contains(assetID) { set.remove(assetID) } else { set.insert(assetID) }
        keep[groupID] = set
    }

    private func load() async {
        defer { isLoading = false }
        guard let fetched = try? await session.client?.duplicates() else { return }
        groups = fetched
        for group in fetched where keep[group.id] == nil {
            keep[group.id] = Set(group.suggestedKeepAssetIds)
        }
    }

    private func resolve(_ targets: [DuplicateGroup], keepingSuggested: Bool) async {
        guard let client = session.client else { return }
        let resolutions = targets.compactMap { group -> DuplicateResolution? in
            let kept = keepingSuggested ? Set(group.suggestedKeepAssetIds) : (keep[group.id] ?? [])
            guard !kept.isEmpty else { return nil }
            return DuplicateResolution(
                duplicateId: group.id,
                keepAssetIds: Array(kept),
                trashAssetIds: group.assets.map(\.id).filter { !kept.contains($0) }
            )
        }
        guard !resolutions.isEmpty else { return }
        let ids = Set(resolutions.map(\.duplicateId))
        workingIDs.formUnion(ids)
        defer { workingIDs.subtract(ids) }
        do {
            let results = try await client.resolveDuplicates(resolutions)
            let failed = Set(results.filter { !$0.success }.map(\.id))
            withAnimation(PhotosMotion.layout) { groups.removeAll { ids.contains($0.id) && !failed.contains($0.id) } }
            if !failed.isEmpty {
                ErrorToastCenter.shared.show(failed.count == 1 ? String(localized: "Couldn't resolve 1 group.") : String(localized: "Couldn't resolve \(failed.count) groups."))
            }
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't resolve the duplicates."), error: error)
        }
    }

    private func dismiss(_ group: DuplicateGroup) async {
        guard let client = session.client else { return }
        let snapshot = groups
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't dismiss the group."),
            apply: { withAnimation(PhotosMotion.layout) { groups.removeAll { $0.id == group.id } } },
            rollback: { groups = snapshot },
            request: { try await client.dismissDuplicates(id: group.id) }
        )
    }
}

private struct DuplicateCandidate: View {
    @Environment(SessionStore.self) private var session
    let asset: AssetDetail
    let isKept: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let client = session.client {
                        RemoteImage(url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 360,
                                    thumbhash: asset.thumbhash)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isKept ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isKept ? Color.accentColor : .red)
                        .padding(5)
                }
                if let size = asset.exifInfo?.fileSizeInByte {
                    Text(size.formatted(.byteCount(style: .file)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let width = asset.exifInfo?.exifImageWidth, let height = asset.exifInfo?.exifImageHeight {
                    Text("\(Int(width)) × \(Int(height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(asset.originalFileName), \(isKept ? String(localized: "kept") : String(localized: "to be removed"))")
        .accessibilityAddTraits(isKept ? .isSelected : [])
    }
}

/// the largest originals in the library, biggest first.
struct LargeFilesScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var assets: [AssetDetail] = []
    @State private var isLoading = true
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var viewer = viewer
        List {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                Button {
                    viewer.present(assets: assets.map { $0.asAsset() }, initialIndex: index)
                } label: {
                    HStack(spacing: 12) {
                        if let client = session.client {
                            RemoteImage(url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 180,
                                        thumbhash: asset.thumbhash)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 8))
                                .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.originalFileName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let size = asset.exifInfo?.fileSizeInByte {
                                Text(size.formatted(.byteCount(style: .file)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Large Files")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if assets.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Files", systemImage: "doc")
                }
            }
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                indexByAssetID: route.indexByAssetID,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onRequestDismissal: { viewer.complete(route.id) },
                onDismissed: { viewer.complete(route.id) }
            ) { _ in }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        if let fetched = try? await session.client?.largeAssets() {
            assets = fetched
        }
    }
}
