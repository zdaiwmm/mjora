import Foundation
import SwiftUI

/// the server inbox: album invites, album activity and server alerts, with the
/// same read semantics as the web panel.
struct NotificationsScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var pendingInvite: ServerNotification?
    @State private var respondingIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if let inbox = session.notifications {
                    list(inbox)
                } else {
                    empty
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let inbox = session.notifications {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                inbox.markAllRead()
                            } label: {
                                Label("Mark All as Read", systemImage: "checkmark.circle")
                            }
                            .disabled(inbox.unreadCount == 0)

                            Button(role: .destructive) {
                                inbox.deleteAll()
                            } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                            .disabled(inbox.items.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityIdentifier("notifications-menu")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("notifications-close")
                }
            }
        }
    }

    private func list(_ inbox: NotificationInbox) -> some View {
        List {
            ForEach(inbox.items) { notification in
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        open(notification, in: inbox)
                    } label: {
                        NotificationRow(notification: notification)
                    }
                    .buttonStyle(.plain)
                    if notification.kind == .clusterGroupRequest, notification.clusterGroupID != nil,
                       session.capabilities.supportsClusterGroups {
                        inviteActions(notification, in: inbox)
                    }
                }
                .swipeActions(edge: .leading) {
                    if notification.isUnread {
                        Button {
                            inbox.markRead(notification.id)
                        } label: {
                            Label("Read", systemImage: "envelope.open")
                        }
                        .tint(.indigo)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        inbox.delete(notification.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if inbox.items.isEmpty {
                if inbox.hasLoaded, !inbox.isLoading {
                    empty
                } else if !inbox.hasLoaded {
                    ProgressView()
                }
            }
        }
        .refreshable { await inbox.load() }
        .confirmationDialog(
            "Join Cluster Group?",
            isPresented: Binding(get: { pendingInvite != nil }, set: { if !$0 { pendingInvite = nil } }),
            titleVisibility: .visible,
            presenting: pendingInvite
        ) { invite in
            Button("Join") {
                Task { await respond(to: invite, accept: true, in: inbox) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ClusterGroupRequest.joinMessage)
        }
        .task {
            await inbox.load()
            await LocalNotifications.shared.requestAuthorizationIfNeeded()
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "No Notifications",
            systemImage: "bell",
            description: Text("Album invites and server alerts show up here.")
        )
    }

    private func inviteActions(_ notification: ServerNotification, in inbox: NotificationInbox) -> some View {
        HStack(spacing: 10) {
            Button("Join") { pendingInvite = notification }
                .buttonStyle(.glassProminent)
            Button("Decline") {
                Task { await respond(to: notification, accept: false, in: inbox) }
            }
            .buttonStyle(.glass)
        }
        .controlSize(.small)
        .padding(.leading, 48)
        .disabled(respondingIDs.contains(notification.id))
        .accessibilityIdentifier("cluster-invite-actions")
    }

    /// the notification carries only the group, so the matching request is
    /// looked up first. a vanished request means someone already answered it.
    private func respond(to notification: ServerNotification, accept: Bool, in inbox: NotificationInbox) async {
        guard let client = session.client, let groupID = notification.clusterGroupID,
              respondingIDs.insert(notification.id).inserted
        else { return }
        defer { respondingIDs.remove(notification.id) }
        do {
            guard let request = try await client.clusterGroupRequests().first(where: { $0.clusterGroupId == groupID }) else {
                ErrorToastCenter.shared.show(String(localized: "This invite is no longer available."))
                inbox.delete(notification.id)
                return
            }
            if accept {
                try await client.acceptClusterGroupRequest(id: request.id)
                // people sharing reads the new group from the user.
                await session.refreshUser()
            } else {
                try await client.declineClusterGroupRequest(id: request.id)
            }
            inbox.delete(notification.id)
        } catch {
            ErrorToastCenter.shared.show(accept ? String(localized: "Couldn't join the cluster group.") : String(localized: "Couldn't decline the invite."),
                                         error: error)
        }
    }

    /// tapping clears the entry and, for album notifications, hands the id to
    /// the router so the albums tab opens it.
    private func open(_ notification: ServerNotification, in inbox: NotificationInbox) {
        inbox.markRead(notification.id)
        guard let albumID = notification.albumID else { return }
        dismiss()
        NotificationRouter.shared.openAlbum(albumID)
    }
}

struct NotificationRow: View {
    let notification: ServerNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(notification.level.tint.gradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: notification.kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(notification.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if notification.isUnread {
                Circle()
                    .fill(.indigo)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

extension NotificationLevel {
    var tint: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .info: .accentColor
        }
    }
}

extension NotificationKind {
    var symbol: String {
        switch self {
        case .albumInvite: "rectangle.stack.badge.person.crop"
        case .albumUpdate: "photo.badge.plus"
        case .backupFailed: "icloud.slash"
        case .jobFailed: "arrow.triangle.2.circlepath"
        case .systemMessage: "megaphone"
        case .clusterGroupRequest: "person.2.badge.gearshape"
        case .custom: "info.circle"
        }
    }
}
