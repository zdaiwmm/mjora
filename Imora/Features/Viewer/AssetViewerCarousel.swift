import SwiftUI

/// the photos thumbnail strip under the media. the current item opens to its
/// own shape while its neighbours stay narrow slivers, and dragging the strip
/// scrubs the pager live.
struct AssetViewerCarousel: View {
    private static let height: CGFloat = 30
    private static let collapsedWidth: CGFloat = 18
    private static let spacing: CGFloat = 2
    /// the open item stands apart from the slivers either side.
    private static let expandedMargin: CGFloat = 10

    let assets: [Asset]
    @Binding var selection: String?
    let aspectRatio: (Asset) -> Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrolledID: String?
    /// only a finger on the strip writes the selection back. programmatic
    /// scrolls animate through every id between, which must not page.
    @State private var isScrubbing = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(assets) { asset in
                        item(asset)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(
                .horizontal,
                max(0, proxy.size.width / 2 - Self.height / 2 - Self.expandedMargin),
                for: .scrollContent
            )
        }
        .frame(height: Self.height)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrolledID, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .onScrollPhaseChange { _, phase in
            isScrubbing = phase == .tracking
                || phase == .interacting
                || phase == .decelerating
        }
        .onChange(of: scrolledID) { _, id in
            guard isScrubbing, let id, id != selection else { return }
            selection = id
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            guard !scrubbing, scrolledID != selection else { return }
            scroll(to: selection)
        }
        .onChange(of: selection, initial: true) { _, id in
            guard !isScrubbing, scrolledID != id else { return }
            scroll(to: id, animated: scrolledID != nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thumbnails")
        .accessibilityIdentifier("viewer-carousel")
    }

    private func item(_ asset: Asset) -> some View {
        let isExpanded = asset.id == selection && !isScrubbing
        return AssetTile(asset: asset, targetPixelSize: 120, isGridTile: false)
            .frame(
                width: isExpanded ? expandedWidth(for: asset) : Self.collapsedWidth,
                height: Self.height
            )
            .clipShape(.rect(cornerRadius: isExpanded ? 5 : 3, style: .continuous))
            .padding(.horizontal, isExpanded ? Self.expandedMargin : 0)
            .contentShape(.rect)
            .onTapGesture {
                guard asset.id != selection else { return }
                selection = asset.id
            }
            .animation(
                reduceMotion ? nil : .spring(duration: 0.3, bounce: 0),
                value: isExpanded
            )
            .accessibilityAddTraits(asset.id == selection ? .isSelected : [])
    }

    private func expandedWidth(for asset: Asset) -> CGFloat {
        let ratio = aspectRatio(asset)
        // portrait items open to a square, landscape ones a little wider.
        let clamped = ratio.isFinite ? min(1.6, max(1, ratio)) : 1
        return Self.height * CGFloat(clamped)
    }

    private func scroll(to id: String?, animated: Bool = true) {
        guard let id else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(duration: 0.3, bounce: 0)) { scrolledID = id }
        } else {
            scrolledID = id
        }
    }
}
