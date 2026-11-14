import Foundation
import SwiftUI

/// thumbs up on the photo on screen, in a shared album with activity on.
struct AssetLikeButton: View {
    @Environment(SessionStore.self) private var session
    let scope: AlbumActivityScope
    let assetID: String
    /// bumped by the viewer after the activity sheet changed something.
    var refreshTrigger = 0

    @State private var like: AlbumActivity?
    /// the photo the like was read for, so a swipe never shows the last one's.
    @State private var loadedAssetID: String?
    @State private var isBusy = false

    private var isLiked: Bool { loadedAssetID == assetID && like != nil }

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
        .accessibilityIdentifier("viewer-like")
        .disabled(isBusy || loadedAssetID != assetID)
        .task(id: "\(assetID)#\(refreshTrigger)") { await load() }
    }

    private func load() async {
        guard let client = session.client, let userID = session.user?.id else { return }
        let requested = assetID
        guard let likes = try? await client.activities(
            albumID: scope.albumID,
            assetID: requested,
            type: .like,
            userID: userID
        ), !Task.isCancelled, requested == assetID else { return }
        like = likes.first { $0.assetId == requested }
        loadedAssetID = requested
    }

    private func toggle() async {
        guard let client = session.client, !isBusy, loadedAssetID == assetID else { return }
        isBusy = true
        defer { isBusy = false }
        if let current = like {
            await OptimisticAction.perform(
                errorMessage: String(localized: "Couldn't remove the like"),
                apply: { like = nil },
                rollback: { like = current },
                request: { try await client.deleteActivity(id: current.id) }
            )
        } else {
            let requested = assetID
            do {
                let created = try await client.createActivity(albumID: scope.albumID, assetID: requested)
                if requested == assetID { like = created }
            } catch {
                ErrorToastCenter.shared.show(String(localized: "Couldn't like this photo"), error: error)
            }
        }
    }
}
