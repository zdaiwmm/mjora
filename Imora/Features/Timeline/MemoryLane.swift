import Foundation
import SwiftUI

/// horizontal "on this day" and birthday carousel above the main timeline.
struct MemoryLane: View {
    @Environment(SessionStore.self) private var session
    var showsHeading = true
    var cardWidth: CGFloat = 148
    var cardHeight: CGFloat = 196
    var cornerRadius: CGFloat = 16
    var contentInset: CGFloat = 16
    var showsEmptyPlaceholder = false
    @State private var memories: [Memory] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var viewer = viewer

        if session.preferences?.memoriesEnabled == false {
            Color.clear.frame(height: 0)
        } else if !memories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if showsHeading { Text("Memories")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, contentInset) }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(memories) { memory in
                            if let first = memory.assets.first {
                                Button {
                                    openMemory(memory)
                                } label: {
                                    memoryCard(memory, cover: first)
                                        .matchedTransitionSource(id: first.id, in: zoomNamespace)
                                }
                                .buttonStyle(PressableCardStyle())
                                .contextMenu {
                                    Button {
                                        Task { await toggleSaved(memory) }
                                    } label: {
                                        memory.isSaved == true
                                            ? Label("Remove from Saved", systemImage: "bookmark.slash")
                                            : Label("Save Memory", systemImage: "bookmark")
                                    }
                                    Button(role: .destructive) {
                                        Task { await delete(memory) }
                                    } label: {
                                        Label("Remove Memory", systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: memory.isSaved == true ? "Remove from Saved" : "Save Memory") {
                                    Task { await toggleSaved(memory) }
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, contentInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.top, showsHeading ? 4 : 0)
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
        } else if showsEmptyPlaceholder {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if !hasLoaded { ProgressView() }
                else if loadFailed {
                    Button { Task { await load() } } label: { Label("Couldn't load memories. Retry", systemImage: "arrow.clockwise") }
                } else {
                    Text("No Memories Yet").font(.headline).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: cornerRadius))
            .task { await load() }
        } else {
            Color.clear
                .frame(height: 0)
                .task { await load() }
        }
    }

    @ViewBuilder private func memoryCard(_ memory: Memory, cover: AssetDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let client = session.client {
                RemoteImage(
                    url: client.thumbnailURL(assetID: cover.id, size: "preview", cacheKey: cover.thumbhash),
                    targetPixelSize: 640,
                    thumbhash: cover.thumbhash
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(memory))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Text(memory.subtitle ?? String(localized: "\(memory.assets.count) photos"))
                    .lineLimit(2)
                    .font(.caption2)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if memory.isBirthday {
                Image(systemName: "gift.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.pink.opacity(0.8), in: .circle)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if memory.isSaved == true {
                Image(systemName: "bookmark.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.35), in: .circle)
                    .padding(8)
                    .accessibilityLabel("Saved")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private func title(_ memory: Memory) -> String {
        if let title = memory.title, !title.isEmpty { return title }
        if let title = memory.ruleTitle { return title }
        if memory.isBirthday {
            let name = memory.data.personName ?? ""
            return name.isEmpty ? String(localized: "Birthday") : String(localized: "\(name)'s Birthday")
        }
        guard let year = memory.data.year else { return String(localized: "Memory") }
        let years = Calendar.current.component(.year, from: Date()) - year
        return years <= 1 ? String(localized: "1 year ago") : String(localized: "\(years) years ago")
    }

    private func openMemory(_ memory: Memory) {
        let assets = memory.assets.map { $0.asAsset() }
        guard !assets.isEmpty else { return }
        viewer.present(assets: assets, initialIndex: 0)
    }

    /// saved memories outlive the server's 30 day cleanup. flipped locally
    /// first, and put back if the server refuses.
    private func toggleSaved(_ memory: Memory) async {
        guard let client = session.client,
              let index = memories.firstIndex(where: { $0.id == memory.id })
        else { return }
        let saved = memory.isSaved != true
        withAnimation(.snappy) { memories[index].isSaved = saved }
        do {
            try await client.setMemorySaved(id: memory.id, isSaved: saved)
        } catch {
            if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                withAnimation(.snappy) { memories[index].isSaved = !saved }
            }
            ErrorToastCenter.shared.show(saved ? String(localized: "Couldn't save the memory.") : String(localized: "Couldn't remove the memory from saved."),
                                         error: error)
        }
    }

    private func delete(_ memory: Memory) async {
        guard let client = session.client else { return }
        let snapshot = memories
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't remove the memory."),
            apply: { withAnimation(.snappy) { memories.removeAll { $0.id == memory.id } } },
            rollback: { memories = snapshot },
            request: { try await client.deleteMemory(id: memory.id) }
        )
    }

    private func load() async {
        guard let client = session.client, memories.isEmpty else { return }
        defer { hasLoaded = true }
        if let fetched = try? await client.memories() {
            guard session.client === client else { return }
            loadFailed = false
            // birthdays lead, like the official clients.
            let shown = fetched.filter { !$0.assets.isEmpty }
            memories = shown.filter(\.isBirthday) + shown.filter { !$0.isBirthday }
        } else { loadFailed = true }
    }
}
