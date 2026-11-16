import Foundation
import SwiftUI

/// horizontal "on this day" and birthday carousel above the main timeline.
struct MemoryLane: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var showsHeading = true
    var cardWidth: CGFloat = 148
    var cardHeight: CGFloat = 196
    var cornerRadius: CGFloat = 16
    var contentInset: CGFloat = 16
    var showsEmptyPlaceholder = false
    var suppliedMemories: [Memory]? = nil
    var onEmpty: () -> Void = {}
    @State private var memories: [Memory] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var slideshow: MemorySlideshowRoute?
    @Namespace private var zoomNamespace

    var body: some View {
        content
            .task(id: session.client?.offlineAccountKey) {
                memories = []
                hasLoaded = false
                await load()
            }
            // Keep the presentation host alive while loading/empty states change.
            .fullScreenCover(item: $slideshow) { route in
                MemorySlideshowScreen(memory: route.memory)
                    .modifier(MemoryMovieTransition(sourceID: "movie-\(route.memory.id)",
                                                    namespace: zoomNamespace, reduced: reduceMotion))
            }
    }

    @ViewBuilder private var content: some View {
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
                            if let first = memory.playableAssets.first {
                                ZStack(alignment: .bottomTrailing) {
                                    NavigationLink {
                                        MemoryCollectionScreen(memory: memory)
                                            .modifier(MemoryMovieTransition(sourceID: memory.id,
                                                                            namespace: zoomNamespace, reduced: reduceMotion))
                                    } label: {
                                        memoryCard(memory, cover: first)
                                            .contentShape(.rect)
                                            .matchedTransitionSource(id: memory.id, in: zoomNamespace)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                    .contentShape(.rect)
                                    .accessibilityLabel(memory.displayTitle)
                                    .accessibilityIdentifier("memory-card-\(memory.id)")
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
                                    Button { slideshow = MemorySlideshowRoute(memory: memory) } label: {
                                        Image(systemName: "play.fill")
                                            .font(.body.weight(.semibold)).foregroundStyle(.white)
                                            .frame(width: 44, height: 44)
                                            .background(.black.opacity(0.3), in: .circle)
                                    }
                                    .buttonStyle(.plain).padding(8)
                                    .accessibilityLabel("Play Memory")
                                    .accessibilityIdentifier("memory-play-\(memory.id)")
                                }
                                .matchedTransitionSource(id: "movie-\(memory.id)", in: zoomNamespace)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, contentInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .accessibilityIdentifier("memory-lane")
            }
            .padding(.top, showsHeading ? 4 : 0)
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
        } else {
            Color.clear
                .frame(height: 0)
        }
    }

    @ViewBuilder private func memoryCard(_ memory: Memory, cover: Asset) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let client = session.client {
                RemoteImage(
                    url: client.thumbnailURL(assetID: cover.id, size: "preview", cacheKey: cover.thumbhash),
                    targetPixelSize: 640,
                    thumbhash: cover.thumbhash
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .allowsHitTesting(false)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(memory.displayTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Text(memory.subtitle ?? String(localized: "\(memory.playableAssets.count) items"))
                    .lineLimit(2)
                    .font(.caption2)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(10)
            .padding(.trailing, 42)
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

    /// saved memories outlive the server's 30 day cleanup. flipped locally
    /// first, and put back if the server refuses.
    private func toggleSaved(_ memory: Memory) async {
        guard let client = session.client,
              let index = memories.firstIndex(where: { $0.id == memory.id })
        else { return }
        let saved = memory.isSaved != true
        withAnimation(PhotosMotion.layout) { memories[index].isSaved = saved }
        do {
            try await client.setMemorySaved(id: memory.id, isSaved: saved)
        } catch {
            if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                withAnimation(PhotosMotion.layout) { memories[index].isSaved = !saved }
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
            apply: { withAnimation(PhotosMotion.layout) { memories.removeAll { $0.id == memory.id } } },
            rollback: { memories = snapshot },
            request: { try await client.deleteMemory(id: memory.id) }
        )
        if memories.isEmpty { onEmpty() }
    }

    private func load() async {
        if let suppliedMemories {
            guard !hasLoaded else { return }
            memories = suppliedMemories
            hasLoaded = true
            return
        }
        guard let client = session.client, memories.isEmpty else { return }
        defer { hasLoaded = true }
        if let fetched = try? await client.memories() {
            guard session.client === client else { return }
            loadFailed = false
            // birthdays lead, like the official clients.
            let shown = fetched.filter { !$0.playableAssets.isEmpty }
            memories = shown.filter(\.isBirthday) + shown.filter { !$0.isBirthday }
        } else if !Task.isCancelled { loadFailed = true }
    }
}
