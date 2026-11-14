import Foundation
import SwiftUI

extension ClusterGroupRequest {
    /// what joining another group does, said before every join.
    static let joinMessage = String(localized: "People will be recognized across the photos of everyone in the group. Your names and birth dates are not shared. To apply this to photos you already have, facial recognition must be reset for the group, which deletes its people along with their names and birth dates.")
}

/// the cluster group: users whose faces are recognized together, so the same
/// human is one person for all of them. members, invites both ways, leaving
/// and recognizing everything again.
struct FaceSharingScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var myID: String?
    @State private var groupID: String?
    @State private var members: [User] = []
    @State private var sent: [ClusterGroupRequest] = []
    @State private var received: [ClusterGroupRequest] = []
    /// the members of each group that invited the user, by group id.
    @State private var invitingMembers: [String: [User]] = [:]
    @State private var users: [User] = []
    @State private var isLoading = true
    @State private var showInvite = false
    @State private var reviewing: ClusterGroupRequest?
    @State private var shareAllWith: User?
    @State private var showLeaveConfirm = false
    @State private var showRegenerateConfirm = false
    @State private var busyIDs = Set<String>()
    @State private var isLeaving = false
    @State private var isRegenerating = false

    private var others: [User] { members.filter { $0.id != myID } }

    private var candidates: [User] {
        let excluded = Set(members.map(\.id) + sent.map(\.userId) + [myID].compactMap(\.self))
        return users.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                ForEach(members) { user in
                    memberRow(user)
                }
            } header: {
                Text("Your Group")
            } footer: {
                Text("Faces are recognized across the photos of everyone in the group, so the same person gets one card for all of you. No photos are shared.")
            }

            if !received.isEmpty || !sent.isEmpty {
                Section("Pending Invites") {
                    ForEach(received) { request in
                        receivedRow(request)
                    }
                    ForEach(sent) { request in
                        sentRow(request)
                    }
                }
            }

            if !others.isEmpty {
                Section {
                    Button {
                        showRegenerateConfirm = true
                    } label: {
                        Label("Recognize Faces Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRegenerating)
                    .accessibilityIdentifier("face-sharing-regenerate")
                    .confirmationDialog(
                        "Recognize Faces Again?",
                        isPresented: $showRegenerateConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Start Over", role: .destructive) {
                            Task { await regenerate() }
                        }
                    } message: {
                        Text("Every face in the photos of everyone in the group is grouped into people again, from scratch. The people of all members are deleted first, so the names and birthdays set so far are lost.")
                    }

                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isLeaving)
                    .accessibilityIdentifier("face-sharing-leave")
                    .confirmationDialog(
                        "Leave the Group?",
                        isPresented: $showLeaveConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Leave Group", role: .destructive) {
                            Task { await leave() }
                        }
                    } message: {
                        Text("Faces will no longer be recognized across the photos of everyone in the group.")
                    }
                }
            }
        }
        .navigationTitle("Face Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && members.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInvite = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .disabled(groupID == nil)
                .accessibilityLabel("Invite")
                .accessibilityIdentifier("face-sharing-invite")
            }
        }
        .sheet(isPresented: $showInvite) {
            ClusterGroupInviteSheet(candidates: candidates) { ids in
                await invite(ids)
            }
        }
        .sheet(item: $reviewing) { request in
            ClusterGroupReviewSheet(
                request: request,
                members: invitingMembers[request.clusterGroupId]
            ) { accept in
                await answer(request, accept: accept)
            }
        }
        .sheet(item: $shareAllWith) { user in
            SharePeopleSheet(preselected: [user.id])
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func memberRow(_ user: User) -> some View {
        let isMe = user.id == myID
        return HStack(spacing: 12) {
            SharingUserLabel(user: user, detail: isMe ? String(localized: "You") : user.email)
            Spacer(minLength: 8)
            if !isMe, session.capabilities.supportsPeopleSharing {
                Button {
                    shareAllWith = user
                } label: {
                    Image(systemName: "person.2.badge.plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share All People with \(user.name)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func receivedRow(_ request: ClusterGroupRequest) -> some View {
        let names = (invitingMembers[request.clusterGroupId] ?? []).map(\.name)
        return Button {
            reviewing = request
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Invite to Another Group")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(names.isEmpty ? String(localized: "Joining it leaves your current group.") : names.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(busyIDs.contains(request.id))
        .accessibilityIdentifier("face-sharing-received")
    }

    private func sentRow(_ request: ClusterGroupRequest) -> some View {
        HStack(spacing: 12) {
            if let user = users.first(where: { $0.id == request.userId }) {
                SharingUserLabel(user: user, detail: String(localized: "Invited"))
            } else {
                Text("Invited user")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .destructive) {
                Task { await cancel(request) }
            }
            .buttonStyle(.borderless)
            .disabled(busyIDs.contains(request.id))
        }
    }

    // MARK: - loading

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            let me = try await client.currentUser()
            myID = me.id
            groupID = me.clusterGroupId
            async let fetchedReceived = client.clusterGroupRequests()
            async let fetchedUsers = client.allUsers()
            if let groupID = me.clusterGroupId {
                async let fetchedMembers = client.clusterGroupUsers(id: groupID)
                async let fetchedSent = client.clusterGroupSentRequests(id: groupID)
                members = try await fetchedMembers
                sent = (try? await fetchedSent) ?? []
            } else {
                members = [User(
                    id: me.id,
                    email: me.email,
                    name: me.name,
                    profileImagePath: me.profileImagePath,
                    avatarColor: me.avatarColor
                )]
                sent = []
            }
            received = (try? await fetchedReceived) ?? []
            users = (try? await fetchedUsers) ?? users
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't load face sharing"), error: error)
            return
        }
        for request in received where invitingMembers[request.clusterGroupId] == nil {
            if let groupMembers = try? await client.clusterGroupUsers(id: request.clusterGroupId) {
                invitingMembers[request.clusterGroupId] = groupMembers
            }
        }
    }

    // MARK: - actions

    private func invite(_ ids: [String]) async -> Bool {
        guard let client = session.client, let groupID else { return false }
        var failure: Error?
        for id in ids {
            do {
                try await client.inviteToClusterGroup(id: groupID, userID: id)
            } catch {
                failure = error
            }
        }
        if let failure {
            ErrorToastCenter.shared.show(String(localized: "Couldn't invite everyone"), error: failure)
        }
        sent = (try? await client.clusterGroupSentRequests(id: groupID)) ?? sent
        return failure == nil
    }

    private func cancel(_ request: ClusterGroupRequest) async {
        guard let client = session.client, busyIDs.insert(request.id).inserted else { return }
        defer { busyIDs.remove(request.id) }
        let previous = sent
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't cancel the invite"),
            apply: { sent.removeAll { $0.id == request.id } },
            rollback: { sent = previous },
            request: { try await client.declineClusterGroupRequest(id: request.id) }
        )
    }

    private func answer(_ request: ClusterGroupRequest, accept: Bool) async {
        guard let client = session.client, busyIDs.insert(request.id).inserted else { return }
        defer { busyIDs.remove(request.id) }
        do {
            if accept {
                try await client.acceptClusterGroupRequest(id: request.id)
            } else {
                try await client.declineClusterGroupRequest(id: request.id)
            }
            reviewing = nil
            received.removeAll { $0.id == request.id }
            if accept {
                await session.refreshUser()
                await load()
            }
        } catch {
            ErrorToastCenter.shared.show(accept ? String(localized: "Couldn't join the group") : String(localized: "Couldn't decline the invite"), error: error)
        }
    }

    private func leave() async {
        guard let client = session.client, let groupID, !isLeaving else { return }
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await client.leaveClusterGroup(id: groupID)
            await session.refreshUser()
            await load()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't leave the group"), error: error)
        }
    }

    private func regenerate() async {
        guard let client = session.client, let groupID, !isRegenerating else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try await client.regenerateClusterGroupPeople(id: groupID)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't start facial recognition again"), error: error)
        }
    }
}

/// users to invite into the group.
private struct ClusterGroupInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [User]
    /// answers whether every invite went out.
    let onInvite: ([String]) async -> Bool

    @State private var selection = Set<String>()
    @State private var isInviting = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { user in
                    SelectableUserRow(user: user, isSelected: selection.contains(user.id)) {
                        if selection.contains(user.id) {
                            selection.remove(user.id)
                        } else {
                            selection.insert(user.id)
                        }
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nobody to Invite",
                        systemImage: "person.2",
                        description: Text("Everyone on this server is already in your group or invited.")
                    )
                }
            }
            .navigationTitle("Invite to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Invite" : "Invite (\(selection.count))") {
                        Task {
                            isInviting = true
                            let done = await onInvite(Array(selection))
                            isInviting = false
                            if done { dismiss() }
                        }
                    }
                    .disabled(selection.isEmpty || isInviting)
                    .accessibilityIdentifier("face-sharing-invite-confirm")
                }
            }
            .interactiveDismissDisabled(isInviting)
        }
    }
}

/// the group behind a received invite, upstream's cluster group users modal.
private struct ClusterGroupReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: ClusterGroupRequest
    let members: [User]?
    let onAnswer: (Bool) async -> Void

    @State private var showJoinConfirm = false
    @State private var isAnswering = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let members {
                        ForEach(members) { user in
                            SharingUserLabel(user: user)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Joining this group leaves your current one.")
                }
            }
            .navigationTitle("Join This Group?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        answer(false)
                    } label: {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        showJoinConfirm = true
                    } label: {
                        Text("Join")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .confirmationDialog(
                        "Join Cluster Group?",
                        isPresented: $showJoinConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Join") { answer(true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(ClusterGroupRequest.joinMessage)
                    }
                }
                .controlSize(.large)
                .disabled(isAnswering)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .interactiveDismissDisabled(isAnswering)
        }
        .presentationDetents([.medium, .large])
    }

    private func answer(_ accept: Bool) {
        Task {
            isAnswering = true
            await onAnswer(accept)
            isAnswering = false
        }
    }
}
