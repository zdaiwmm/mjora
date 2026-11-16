import Foundation
import SwiftUI

/// the swipe deck: one photo at a time, right to keep, left to trash and up
/// to favorite, with the same choices as buttons below and an undo.
struct CleanupDeck<Info: View>: View {
    let assets: [CleanupAsset]
    var allowsFavorite = true
    let trashEnabled: Bool
    let canUndo: Bool
    let onMark: (CleanupAsset, CleanupMark) -> Void
    let onUndo: () -> Void
    let onOpen: (CleanupAsset) -> Void
    @ViewBuilder let info: (CleanupAsset) -> Info

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGSize = .zero
    @State private var cardSize = CGSize(width: 360, height: 520)
    /// set while the top card flies off, so a second decision waits for it.
    @State private var throwing: CleanupMark?
    @State private var decisions = 0
    @State private var undos = 0

    /// the share of the card a drag must pass to decide.
    private static var horizontalThreshold: CGFloat { 0.28 }
    private static var upThreshold: CGFloat { 0.16 }
    /// a release this fast decides even before the threshold.
    private static var throwVelocity: CGFloat { 800 }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(assets.prefix(3).enumerated().reversed()), id: \.element.id) { index, asset in
                    card(asset, depth: index, size: cardSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
            controls
        }
        .sensoryFeedback(.impact(weight: .light), trigger: decisions)
        .sensoryFeedback(.selection, trigger: armed) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: undos)
    }

    private func card(_ asset: CleanupAsset, depth: Int, size: CGSize) -> some View {
        let isTop = depth == 0
        let drag = isTop ? offset : .zero
        return CleanupDeckCard(asset: asset, stamp: isTop ? stamp(size: size) : nil, info: info(asset))
            .frame(width: size.width, height: size.height)
            .scaleEffect(isTop ? 1 : 1 - CGFloat(depth) * 0.04, anchor: .bottom)
            .offset(y: isTop ? 0 : CGFloat(depth) * 10)
            .offset(drag)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width / 22)), anchor: .bottom)
            .allowsHitTesting(isTop)
            .onTapGesture { onOpen(asset) }
            .gesture(isTop ? dragGesture(asset, size: size) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the photo.")
            .accessibilityActions {
                Button("Keep") { decide(asset, .keep, size: size) }
                if allowsFavorite { Button("Favorite") { decide(asset, .favorite, size: size) } }
                Button(trashEnabled ? "Trash" : "Delete") { decide(asset, .trash, size: size) }
            }
            .zIndex(Double(3 - depth))
            // a decided card is already off screen, an undone one comes back in.
            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
    }

    /// the decision the drag would make if released now.
    private func pending(size: CGSize) -> CleanupMark? {
        guard size.width > 0, size.height > 0 else { return nil }
        if allowsFavorite, -offset.height > size.height * Self.upThreshold, abs(offset.width) < -offset.height {
            return .favorite
        }
        if offset.width > size.width * Self.horizontalThreshold { return .keep }
        if -offset.width > size.width * Self.horizontalThreshold { return .trash }
        return nil
    }

    private var armed: CleanupMark? { throwing ?? pending(size: cardSize) }

    private func stamp(size: CGSize) -> (CleanupMark, Double)? {
        if let throwing { return (throwing, 1) }
        guard size.width > 0 else { return nil }
        let horizontal = offset.width / (size.width * Self.horizontalThreshold)
        let up = -offset.height / (size.height * Self.upThreshold)
        if allowsFavorite, up > abs(horizontal), up > 0.15 { return (.favorite, min(1, up)) }
        if horizontal > 0.15 { return (.keep, min(1, horizontal)) }
        if horizontal < -0.15 { return (.trash, min(1, -horizontal)) }
        return nil
    }

    private func dragGesture(_ asset: CleanupAsset, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard throwing == nil else { return }
                offset = CGSize(
                    width: value.translation.width,
                    height: allowsFavorite ? min(value.translation.height, 40) : value.translation.height * 0.2
                )
            }
            .onEnded { value in
                guard throwing == nil else { return }
                let velocity = value.velocity
                var mark = pending(size: size)
                if mark == nil {
                    if velocity.width > Self.throwVelocity { mark = .keep }
                    else if velocity.width < -Self.throwVelocity { mark = .trash }
                    else if allowsFavorite, velocity.height < -Self.throwVelocity { mark = .favorite }
                }
                if let mark {
                    decide(asset, mark, size: size)
                } else {
                    withAnimation(PhotosMotion.layout) { offset = .zero }
                }
            }
    }

    private func decide(_ asset: CleanupAsset, _ mark: CleanupMark, size: CGSize) {
        guard throwing == nil else { return }
        throwing = mark
        let distance = max(size.width, size.height) * 1.4
        let target: CGSize = switch mark {
        case .keep: CGSize(width: distance, height: offset.height)
        case .trash: CGSize(width: -distance, height: offset.height)
        case .favorite: CGSize(width: offset.width, height: -distance)
        }
        let finish = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = .zero
                throwing = nil
            }
            decisions += 1
            withAnimation(PhotosMotion.layout) { onMark(asset, mark) }
        }
        if reduceMotion {
            finish()
        } else {
            withAnimation(PhotosMotion.removal) {
                offset = target
            } completion: {
                finish()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            controlButton(
                trashEnabled ? String(localized: "Trash") : String(localized: "Delete"),
                stableID: trashEnabled ? "trash" : "delete",
                systemImage: trashEnabled ? "trash" : "trash.slash",
                tint: .red,
                size: 60
            ) {
                if let top = assets.first { decide(top, .trash, size: cardSize) }
            }
            controlButton(String(localized: "Undo"), stableID: "undo", systemImage: "arrow.uturn.backward", tint: .secondary, size: 46) {
                undos += 1
                withAnimation(PhotosMotion.layout) { onUndo() }
            }
            .disabled(!canUndo || throwing != nil)
            .opacity(canUndo ? 1 : 0.4)
            if allowsFavorite {
                controlButton(String(localized: "Favorite"), stableID: "favorite", systemImage: "heart.fill", tint: .pink, size: 46) {
                    if let top = assets.first { decide(top, .favorite, size: cardSize) }
                }
            }
            controlButton(String(localized: "Keep"), stableID: "keep", systemImage: "checkmark", tint: .green, size: 60) {
                if let top = assets.first { decide(top, .keep, size: cardSize) }
            }
        }
        .disabled(assets.isEmpty)
    }

    private func controlButton(
        _ title: String,
        stableID: String,
        systemImage: String,
        tint: Color,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
        .accessibilityIdentifier("cleanup-deck-\(stableID)")
    }
}

private struct CleanupDeckCard<Info: View>: View {
    let asset: CleanupAsset
    let stamp: (CleanupMark, Double)?
    let info: Info

    var body: some View {
        CleanupThumbnail(asset: asset, size: "preview", targetPixelSize: 1440)
            .overlay(alignment: .bottomLeading) {
                info
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .topTrailing) {
                if asset.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(14)
                }
            }
            .overlay {
                if let stamp {
                    StampView(mark: stamp.0)
                        .opacity(stamp.1)
                }
            }
            .clipShape(.rect(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .contentShape(.rect(cornerRadius: 26, style: .continuous))
    }
}

private struct StampView: View {
    let mark: CleanupMark

    private var title: String {
        switch mark {
        case .keep: String(localized: "Keep")
        case .trash: String(localized: "Trash")
        case .favorite: String(localized: "Favorite")
        }
    }

    private var symbol: String {
        switch mark {
        case .keep: "checkmark.circle.fill"
        case .trash: "trash.circle.fill"
        case .favorite: "heart.circle.fill"
        }
    }

    private var tint: Color {
        switch mark {
        case .keep: .green
        case .trash: .red
        case .favorite: .pink
        }
    }

    var body: some View {
        ZStack {
            tint.opacity(0.18)
            Label(title, systemImage: symbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(tint, in: .capsule)
        }
        .allowsHitTesting(false)
    }
}
