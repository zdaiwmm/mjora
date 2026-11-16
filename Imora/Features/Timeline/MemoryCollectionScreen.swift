import SwiftUI

struct MemoryCollectionScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let memory: Memory
    @State private var viewer = ViewerPresentation()
    @State private var slideshow: MemorySlideshowRoute?
    @Namespace private var photoNamespace
    @Namespace private var movieNamespace

    private var assets: [Asset] { memory.playableAssets }

    var body: some View {
        @Bindable var viewer = viewer
        ScrollView {
            VStack(spacing: 18) {
                if let cover = assets.first {
                    ZStack(alignment: .bottomLeading) {
                        MemoryAssetImage(asset: cover, pixels: 1_200)
                            .frame(height: 300).clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(memory.displayTitle).font(.largeTitle.bold()).lineLimit(3)
                            if let subtitle = memory.subtitle { Text(subtitle).font(.subheadline) }
                            Button { slideshow = MemorySlideshowRoute(memory: memory) } label: {
                                Label("Play Memory", systemImage: "play.fill")
                                    .font(.headline).padding(.vertical, 9).padding(.horizontal, 16)
                            }
                            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                            .accessibilityIdentifier("memory-collection-play")
                        }
                        .foregroundStyle(.white).padding(22)
                    }
                    .clipShape(.rect(cornerRadius: 24))
                    .matchedTransitionSource(id: memory.id, in: movieNamespace)
                    .padding(.horizontal, 16)
                }
                HStack {
                    Text("\(assets.count) items").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 20)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        Button { viewer.present(assets: assets, initialIndex: index) } label: {
                            MemoryAssetImage(asset: asset)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .bottomTrailing) {
                                    if asset.isVideo {
                                        Image(systemName: "video.fill").font(.caption)
                                            .foregroundStyle(.white).padding(6)
                                    }
                                }
                                .clipped()
                                .matchedTransitionSource(id: asset.id, in: photoNamespace)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.isVideo ? String(localized: "Video") : String(localized: "Photo"))
                        .accessibilityIdentifier("memory-photo-\(index)")
                    }
                }
            }
            .padding(.top, 8).padding(.bottom, 90)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("memory-collection")
        .fullScreenCover(item: $slideshow) { route in
            MemorySlideshowScreen(memory: route.memory)
                .modifier(MemoryMovieTransition(sourceID: memory.id, namespace: movieNamespace, reduced: reduceMotion))
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(assets: route.assets, indexByAssetID: route.indexByAssetID,
                              initialIndex: route.initialIndex, presentationID: route.id,
                              zoomNamespace: photoNamespace,
                              onRequestDismissal: { viewer.complete(route.id) },
                              onDismissed: { viewer.complete(route.id) }) { _ in }
        }
    }
}

struct MemoryAssetImage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    var pixels: CGFloat = 400

    var body: some View {
        GeometryReader { geometry in
            if let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash),
                            targetPixelSize: pixels, thumbhash: asset.thumbhash)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    // A failed cover's inline retry must not swallow the card
                    // or grid button. Opening the item provides its retry UI.
                    .allowsHitTesting(false)
            }
        }
        .background(Color(.secondarySystemBackground))
        .accessibilityHidden(true)
    }
}

struct MemoryMovieTransition: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    let reduced: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduced { content }
        else { content.navigationTransition(.zoom(sourceID: sourceID, in: namespace)) }
    }
}
