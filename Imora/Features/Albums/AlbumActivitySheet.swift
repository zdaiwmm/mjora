import Foundation
import SwiftUI

/// the album an activity sheet reads and writes.
nonisolated struct AlbumActivityScope: Hashable, Sendable {
    let albumID: String
    let ownerID: String?
    /// the owner's comments and likes switch. off keeps the history readable.
    let isEnabled: Bool

    init(album: Album) {
        albumID = album.id
        ownerID = album.owner?.id
        isEnabled = album.isActivityEnabled ?? true
    }
}

/// comments and likes of a shared album, or of one of its photos when opened
/// from the viewer. it opens on the latest message, like the web panel.
struct AlbumActivitySheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let scope: AlbumActivityScope
    /// set from the viewer, which shows the activity of one photo.
    var assetID: String? = nil
    /// told after every change, so counts elsewhere can follow.
    var onChange: () -> Void = {}

    @State private var activities: [AlbumActivity] = []
    @State private var isLoading = true
    @State private var draft = ""
    @State private var isSending = false
    @State private var isTogglingLike = false
    @State private var deletingIDs = Set<String>()
    /// the first load jumps to the bottom, later messages scroll there.
    @State private var hasScrolled = false

    private var myID: String? { session.user?.id }
    private var isOwner: Bool { scope.ownerID != nil && scope.ownerID == myID }

    /// likes on what the sheet is about: the photo, or the album itself.
    private var likes: [AlbumActivity] {
        activities.filter { $0.isLike && $0.assetId == assetID }
    }

    private var myLike: AlbumActivity? { likes.first { $0.user.id == myID } }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(activities) { activity in
                        AlbumActivityRow(activity: activity, showsAsset: assetID == nil)
                            .id(activity.id)
                            .listRowSeparator(.hidden)
                            .opacity(deletingIDs.contains(activity.id) ? 0.4 : 1)
                            .swipeActions(edge: .trailing) {
                                if canDelete(activity) {
                                    Button(role: .destructive) {
                                        Task { await delete(activity) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                if let comment = activity.comment, !comment.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = comment
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                                if canDelete(activity) {
                                    Button(role: .destructive) {
                                        Task { await delete(activity) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if activities.isEmpty {
                        if isLoading {
                            ProgressView()
                        } else {
                            ContentUnavailableView(
                                "No Comments Yet",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text(scope.isEnabled
                                    ? "Start the conversation."
                                    : "Comments and likes are turned off.")
                            )
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { composer }
                .onChange(of: activities.last?.id) { _, id in
                    guard let id else { return }
                    if hasScrolled {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) }
                    } else {
                        hasScrolled = true
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle(assetID == nil ? "Activity" : "Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("activity-done")
                }
            }
            .task { await load() }
            // no server sends activity over the socket. album events are the
            // nearest live signal, the rest waits for the next open.
            .onChange(of: session.realtime?.albumsGeneration ?? 0) {
                Task { await load() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var composer: some View {
        if scope.isEnabled {
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    Task { await toggleLike() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: myLike == nil ? "hand.thumbsup" : "hand.thumbsup.fill")
                            .contentTransition(.symbolEffect(.replace))
                        if !likes.isEmpty {
                            Text(likes.count, format: .number)
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                    .foregroundStyle(myLike == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .frame(minHeight: 34)
                }
                .buttonStyle(.plain)
                .disabled(isTogglingLike || isLoading)
                .accessibilityLabel(myLike == nil ? "Like" : "Unlike")
                .accessibilityValue(likes.isEmpty ? "" : "\(likes.count) likes")
                .accessibilityIdentifier("activity-like")

                TextField("Say something", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("activity-comment-field")

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(minHeight: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(trimmedDraft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(trimmedDraft.isEmpty || isSending)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("activity-send")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        } else if !activities.isEmpty {
            Text("Comments and likes are turned off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }

    /// your own comments and likes, and any of them for the album's owner.
    private func canDelete(_ activity: AlbumActivity) -> Bool {
        guard !deletingIDs.contains(activity.id) else { return false }
        return activity.user.id == myID || isOwner
    }

    // MARK: - loading

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            let fetched = try await client.activities(albumID: scope.albumID, assetID: assetID)
            guard deletingIDs.isEmpty, !isSending, !isTogglingLike else { return }
            if fetched != activities { activities = fetched }
        } catch is CancellationError {
        } catch {
            if activities.isEmpty {
                ErrorToastCenter.shared.show(String(localized: "Couldn't load the activity"), error: error)
            }
        }
    }

    // MARK: - mutations

    private func send() async {
        let text = trimmedDraft
        guard let client = session.client, !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let created = try await client.createActivity(albumID: scope.albumID, assetID: assetID, comment: text)
            draft = ""
            activities.append(created)
            onChange()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't send the comment"), error: error)
        }
    }

    private func toggleLike() async {
        guard let client = session.client, !isTogglingLike else { return }
        isTogglingLike = true
        defer { isTogglingLike = false }
        if let like = myLike {
            let previous = activities
            await OptimisticAction.perform(
                errorMessage: String(localized: "Couldn't remove the like"),
                apply: { activities.removeAll { $0.id == like.id } },
                rollback: { activities = previous },
                request: { try await client.deleteActivity(id: like.id) },
                commit: { _ in onChange() }
            )
        } else {
            do {
                let created = try await client.createActivity(albumID: scope.albumID, assetID: assetID)
                // a like that already existed comes back as is.
                if !activities.contains(where: { $0.id == created.id }) {
                    activities.append(created)
                }
                onChange()
            } catch {
                ErrorToastCenter.shared.show(String(localized: "Couldn't like this"), error: error)
            }
        }
    }

    private func delete(_ activity: AlbumActivity) async {
        guard let client = session.client, deletingIDs.insert(activity.id).inserted else { return }
        defer { deletingIDs.remove(activity.id) }
        let previous = activities
        await OptimisticAction.perform(
            errorMessage: activity.isLike ? String(localized: "Couldn't remove the like") : String(localized: "Couldn't delete the comment"),
            apply: { activities.removeAll { $0.id == activity.id } },
            rollback: { activities = previous },
            request: { try await client.deleteActivity(id: activity.id) },
            commit: { _ in onChange() }
        )
    }
}

private struct AlbumActivityRow: View {
    @Environment(SessionStore.self) private var session
    let activity: AlbumActivity
    /// the album wide list shows which photo a like or comment is about.
    let showsAsset: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatar(user: activity.user, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(activity.user.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let date = activity.date {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if activity.isLike {
                    Label(activity.assetId == nil ? "Liked the album" : "Liked a photo",
                          systemImage: "hand.thumbsup.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(activity.comment ?? "")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if showsAsset, let assetID = activity.assetId, let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: assetID), targetPixelSize: 120)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
