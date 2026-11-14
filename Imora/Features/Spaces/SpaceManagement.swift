import Foundation
import SwiftUI

// creating, editing and staffing gallery shared spaces. every rule here is the
// server's, from 5.0 on: owners rename, delete and manage members, editors add
// and remove photos, anyone but the owner may leave.

/// names a new space, or renames one the user owns.
struct SpaceEditSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// nil creates a new space.
    let space: SharedSpace?
    let onSaved: (SharedSpace) -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var isSaving = false

    init(space: SharedSpace? = nil, onSaved: @escaping (SharedSpace) -> Void) {
        self.space = space
        self.onSaved = onSaved
        _name = State(initialValue: space?.name ?? "")
        _descriptionText = State(initialValue: space?.description ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Space name", text: $name)
                        .accessibilityIdentifier("space-edit-name")
                }
                Section("Description") {
                    TextField("Add a description", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(space == nil ? "New Space" : "Edit Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(space == nil ? "Create" : "Save") {
                        Task { await save() }
                    }
                    // the server caps names at 100 and descriptions at 500.
                    .disabled(trimmedName.isEmpty || trimmedName.count > 100 || descriptionText.count > 500 || isSaving)
                    .accessibilityIdentifier("space-edit-save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let client = session.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved: SharedSpace
            if let space {
                saved = try await client.updateSharedSpace(id: space.id, name: trimmedName, description: description)
            } else {
                saved = try await client.createSharedSpace(name: trimmedName, description: description)
            }
            dismiss()
            onSaved(saved)
        } catch {
            ErrorToastCenter.shared.show(space == nil ? String(localized: "Couldn't create the space.") : String(localized: "Couldn't save the space."),
                                         error: error)
        }
    }
}

/// the members of a space. owners change roles, remove people and add more.
struct SpaceMembersSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let space: SharedSpace
    let onChanged: () -> Void
    @State private var members: [SharedSpaceMember]
    @State private var showAdd = false
    @State private var mutatingIDs = Set<String>()

    init(space: SharedSpace, onChanged: @escaping () -> Void = {}) {
        self.space = space
        self.onChanged = onChanged
        _members = State(initialValue: space.members ?? [])
    }

    private var isOwner: Bool { space.role(of: session.user?.id) == .owner }
    /// gallery 5.10 says what an editor may do, earlier releases leave it to owners.
    private var canAddMembers: Bool { space.memberManagement?.canAddMembers ?? isOwner }
    private var canChangeRoles: Bool { space.memberManagement?.canChangeRoles ?? isOwner }

    private var assignableRoles: [SharedSpaceRole] {
        isOwner ? [.owner, .editor, .viewer] : [.editor, .viewer]
    }

    /// an editor manages viewers and editors, never an owner.
    private func canChangeRole(of member: SharedSpaceMember) -> Bool {
        canChangeRoles && member.userId != session.user?.id && (isOwner || member.role != .owner)
    }

    var body: some View {
        NavigationStack {
            List(members) { member in
                row(member)
                    .swipeActions {
                        if isOwner, member.userId != session.user?.id {
                            Button("Remove", role: .destructive) {
                                Task { await remove(member) }
                            }
                        }
                    }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if canAddMembers {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("Add Members")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                SpaceAddMembersSheet(
                    space: space,
                    excluded: Set(members.map(\.userId)),
                    allowsEditors: isOwner || canChangeRoles
                ) { added in
                    members.append(contentsOf: added)
                    onChanged()
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder private func row(_ member: SharedSpaceMember) -> some View {
        HStack(spacing: 12) {
            UserAvatar(user: member.user, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                Text(member.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canChangeRole(of: member) {
                Menu {
                    Picker("Role", selection: Binding(
                        get: { member.role },
                        set: { role in Task { await setRole(role, for: member) } }
                    )) {
                        ForEach(assignableRoles, id: \.self) { role in
                            Text(role.title).tag(role)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(member.role.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption)
                }
                .disabled(mutatingIDs.contains(member.userId))
            } else {
                Text(member.role.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        if let fetched = try? await session.client?.sharedSpaceMembers(id: space.id) {
            members = fetched
        }
    }

    private func setRole(_ role: SharedSpaceRole, for member: SharedSpaceMember) async {
        guard let client = session.client, role != member.role, !mutatingIDs.contains(member.userId) else { return }
        mutatingIDs.insert(member.userId)
        defer { mutatingIDs.remove(member.userId) }
        do {
            let updated = try await client.updateSharedSpaceMember(spaceID: space.id, userID: member.userId, role: role)
            if let index = members.firstIndex(where: { $0.userId == member.userId }) {
                members[index] = updated
            }
            onChanged()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't change the role."), error: error)
        }
    }

    private func remove(_ member: SharedSpaceMember) async {
        guard let client = session.client, !mutatingIDs.contains(member.userId) else { return }
        mutatingIDs.insert(member.userId)
        defer { mutatingIDs.remove(member.userId) }
        let snapshot = members
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't remove \(member.name)."),
            apply: { members.removeAll { $0.userId == member.userId } },
            rollback: { members = snapshot },
            request: { try await client.removeSharedSpaceMember(spaceID: space.id, userID: member.userId) },
            commit: { _ in onChanged() }
        )
    }
}

/// picks people, one by one or a whole user group at once, and the role they
/// join with.
private struct SpaceAddMembersSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let space: SharedSpace
    let excluded: Set<String>
    /// editors may only add viewers unless they may change roles too.
    let allowsEditors: Bool
    let onAdded: ([SharedSpaceMember]) -> Void

    @State private var users: [User] = []
    @State private var groups: [UserGroup] = []
    @State private var selection = Set<String>()
    @State private var role = SharedSpaceRole.viewer
    @State private var isLoading = true
    @State private var isAdding = false

    private var candidates: [User] {
        users.filter { !excluded.contains($0.id) && $0.id != session.user?.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsEditors {
                    Section {
                        Picker("Role", selection: $role) {
                            Text(SharedSpaceRole.viewer.title).tag(SharedSpaceRole.viewer)
                            Text(SharedSpaceRole.editor.title).tag(SharedSpaceRole.editor)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(role == .editor
                            ? "Editors can add and remove photos."
                            : "Viewers can browse the space.")
                    }
                }
                let addableGroups = groups.filter { group in
                    group.members.contains { !excluded.contains($0.userId) && $0.userId != session.user?.id }
                }
                if !addableGroups.isEmpty {
                    Section("Groups") {
                        ForEach(addableGroups) { group in
                            Button {
                                selection.formUnion(group.members.map(\.userId).filter { id in
                                    !excluded.contains(id) && id != session.user?.id
                                })
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color(avatarColor: group.color).gradient)
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            Image(systemName: "person.2.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.white)
                                        }
                                    Text(group.name)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    Text(group.members.count == 1 ? "1 member" : "\(group.members.count) members")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityHint("Selects everyone in the group")
                        }
                    }
                }
                Section("People") {
                    ForEach(candidates) { user in
                        Button {
                            if selection.contains(user.id) {
                                selection.remove(user.id)
                            } else {
                                selection.insert(user.id)
                            }
                        } label: {
                            UserSelectionRow(user: user, isSelected: selection.contains(user.id))
                        }
                    }
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading && users.isEmpty {
                    ProgressView()
                } else if !isLoading && candidates.isEmpty {
                    ContentUnavailableView("Everyone Is Here", systemImage: "person.2")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(selection.isEmpty || isAdding)
                }
            }
            .interactiveDismissDisabled(isAdding)
            .task { await load() }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        defer { isLoading = false }
        let wantsGroups = session.capabilities.supportsUserGroups
        async let usersTask = try? client.allUsers()
        async let groupsTask = wantsGroups ? try? client.userGroups() : nil
        users = await usersTask ?? []
        groups = await groupsTask ?? []
    }

    /// one request per person; whoever made it in stays added.
    private func add() async {
        guard let client = session.client, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        var added: [SharedSpaceMember] = []
        var failed = 0
        for userID in selection {
            do {
                added.append(try await client.addSharedSpaceMember(spaceID: space.id, userID: userID, role: role))
            } catch {
                failed += 1
            }
        }
        if !added.isEmpty { onAdded(added) }
        if failed > 0 {
            ErrorToastCenter.shared.show(failed == 1 ? String(localized: "Couldn't add 1 person.") : String(localized: "Couldn't add \(failed) people."))
            selection.subtract(added.map(\.userId))
        } else {
            dismiss()
        }
    }
}
