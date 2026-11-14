import Foundation
import SwiftUI

// gallery user groups: named circles of people to add to a space in one go.
// each group belongs to whoever made it; groups an identity provider syncs
// in are read only, their members come from there.

struct UserGroupsScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var groups: [UserGroup] = []
    @State private var isLoading = true
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(groups) { group in
                NavigationLink {
                    UserGroupScreen(group: group) { updated in
                        if let updated, let index = groups.firstIndex(where: { $0.id == group.id }) {
                            groups[index] = updated
                        } else if updated == nil {
                            groups.removeAll { $0.id == group.id }
                        }
                    }
                } label: {
                    UserGroupRow(group: group)
                }
            }
        }
        .navigationTitle("User Groups")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if groups.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No User Groups", systemImage: "person.2.circle")
                    } description: {
                        Text("Group people you often share with, then add them to a space at once.")
                    } actions: {
                        Button("New Group") { showCreate = true }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Group")
            }
        }
        .alert("New Group", isPresented: $showCreate) {
            TextField("Group name", text: $newName)
            Button("Create") { Task { await create() } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        if let fetched = try? await session.client?.userGroups() {
            groups = fetched
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard let client = session.client, !name.isEmpty else { return }
        do {
            groups.append(try await client.createUserGroup(name: name, color: nil))
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't create the group."), error: error)
        }
    }
}

private struct UserGroupRow: View {
    let group: UserGroup

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(avatarColor: group.color).gradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text(group.members.count == 1 ? "1 member" : "\(group.members.count) members")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// one group: rename, color, members and deletion.
private struct UserGroupScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var group: UserGroup
    /// the edited group, or nil once it was deleted.
    let onChanged: (UserGroup?) -> Void

    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showAddMembers = false
    @State private var confirmDelete = false
    @State private var isSaving = false

    private static let colors = ["primary", "pink", "red", "yellow", "blue", "green", "purple", "orange", "gray", "amber"]

    private static func colorTitle(_ color: String) -> String {
        switch color {
        case "pink": String(localized: "Pink")
        case "red": String(localized: "Red")
        case "yellow": String(localized: "Yellow")
        case "blue": String(localized: "Blue")
        case "green": String(localized: "Green")
        case "purple": String(localized: "Purple")
        case "orange": String(localized: "Orange")
        case "gray": String(localized: "Gray")
        case "amber": String(localized: "Amber")
        default: String(localized: "Primary")
        }
    }

    init(group: UserGroup, onChanged: @escaping (UserGroup?) -> Void) {
        _group = State(initialValue: group)
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            if group.isManual {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.colors, id: \.self) { color in
                                Button {
                                    Task { await save(name: group.name, color: color) }
                                } label: {
                                    Circle()
                                        .fill(Color(avatarColor: color).gradient)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if (group.color ?? "primary") == color {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Self.colorTitle(color))
                                .accessibilityAddTraits((group.color ?? "primary") == color ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(isSaving)
                } header: {
                    Text("Color")
                }
            }
            Section {
                ForEach(group.members) { member in
                    HStack(spacing: 12) {
                        UserAvatar(user: member.user, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                            Text(member.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        if group.isManual {
                            Button("Remove", role: .destructive) {
                                Task { await setMembers(group.members.map(\.userId).filter { $0 != member.userId }) }
                            }
                        }
                    }
                }
                if group.isManual {
                    Button {
                        showAddMembers = true
                    } label: {
                        Label("Add People", systemImage: "person.badge.plus")
                    }
                    .disabled(isSaving)
                }
            } header: {
                Text("Members")
            } footer: {
                if !group.isManual {
                    Text("This group is synced from your sign-in provider and can't be edited here.")
                }
            }
            if group.isManual {
                Section {
                    Button("Delete Group", role: .destructive) { confirmDelete = true }
                        .disabled(isSaving)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if group.isManual {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rename") {
                        renameDraft = group.name
                        showRename = true
                    }
                    .disabled(isSaving)
                }
            }
        }
        .alert("Rename Group", isPresented: $showRename) {
            TextField("Group name", text: $renameDraft)
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await save(name: name, color: group.color) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \"\(group.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Spaces the group was added to keep their members.")
        }
        .sheet(isPresented: $showAddMembers) {
            UserPickerSheet(title: String(localized: "Add People"), excluded: Set(group.members.map(\.userId))) { users in
                Task { await setMembers(group.members.map(\.userId) + users.map(\.id)) }
            }
        }
    }

    private func save(name: String, color: String?) async {
        guard let client = session.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await client.updateUserGroup(id: group.id, name: name, color: color)
            group.name = updated.name
            group.color = updated.color
            onChanged(group)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't save the group."), error: error)
        }
    }

    private func setMembers(_ userIDs: [String]) async {
        guard let client = session.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            group.members = try await client.setUserGroupMembers(id: group.id, userIDs: userIDs)
            onChanged(group)
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't update the members."), error: error)
        }
    }

    private func delete() async {
        guard let client = session.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.deleteUserGroup(id: group.id)
            onChanged(nil)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't delete the group."), error: error)
        }
    }
}

/// every other user on the server, multi-select.
struct UserPickerSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    let excluded: Set<String>
    let onPicked: ([User]) -> Void

    @State private var users: [User] = []
    @State private var selection = Set<String>()
    @State private var isLoading = true

    private var candidates: [User] {
        users.filter { !excluded.contains($0.id) && $0.id != session.user?.id }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { user in
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading && users.isEmpty {
                    ProgressView()
                } else if !isLoading && candidates.isEmpty {
                    ContentUnavailableView("No One Else to Add", systemImage: "person.2")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let picked = candidates.filter { selection.contains($0.id) }
                        dismiss()
                        onPicked(picked)
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .task {
                defer { isLoading = false }
                if let fetched = try? await session.client?.allUsers() {
                    users = fetched
                }
            }
        }
    }
}

/// a user with a check mark, for multi-select pickers.
struct UserSelectionRow: View {
    let user: User
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            UserAvatar(user: user, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .foregroundStyle(.primary)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
