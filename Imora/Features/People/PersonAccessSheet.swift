import Foundation
import SwiftUI

/// upstream's edit access modal: who can see one person and with which role.
/// people are only shared inside the cluster group, and never their photos.
struct PersonAccessSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let person: Person
    /// told after a change, so the person page reloads its sharing line.
    var onChange: () -> Void = {}

    @State private var shares: [PersonUserShare] = []
    @State private var members: [User]?
    @State private var isLoading = true
    @State private var selection = Set<String>()
    @State private var newRole: PersonShareRole = .write
    @State private var isSharing = false
    @State private var mutatingUserIDs = Set<String>()
    @State private var userToRemove: PersonUserShare?

    private var myID: String? { session.user?.id }
    private var sharedByMe: [PersonUserShare] {
        shares.filter { $0.sharedById == myID }.sorted { $0.sharedWith.name < $1.sharedWith.name }
    }
    private var sharedWithMe: [PersonUserShare] {
        shares.filter { $0.sharedWithId == myID }.sorted { $0.sharedBy.name < $1.sharedBy.name }
    }
    private var candidates: [User] {
        let shared = Set(sharedByMe.map(\.sharedWithId))
        return (members ?? []).filter { !shared.contains($0.id) }
    }
    private var displayName: String { person.name.isEmpty ? String(localized: "this person") : person.name }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if sharedByMe.isEmpty {
                        Text("Nobody else has access yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sharedByMe) { share in
                        sharedRow(share)
                    }
                } header: {
                    Text("Shared by You")
                } footer: {
                    Text("Let members of your cluster group see or manage \(displayName) with you. Sharing a person does not share any photos.")
                }

                if !sharedWithMe.isEmpty {
                    Section("Shared with You") {
                        ForEach(sharedWithMe) { share in
                            SharingUserLabel(user: share.sharedBy, detail: String(localized: "You \(share.role.title.lowercased())"))
                                .accessibilityElement(children: .combine)
                        }
                    }
                }

                addSection
            }
            .navigationTitle("Edit Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Share" : "Share (\(selection.count))") {
                        Task { await share() }
                    }
                    .disabled(selection.isEmpty || isSharing)
                    .accessibilityIdentifier("person-access-share")
                }
            }
            .interactiveDismissDisabled(isSharing)
            .task { await load() }
        }
    }

    @ViewBuilder private var addSection: some View {
        Section {
            if let members {
                if members.isEmpty {
                    Text("People can only be shared with the members of your cluster group.")
                        .foregroundStyle(.secondary)
                } else if candidates.isEmpty {
                    Text("Everyone in your cluster group already has access.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { user in
                        SelectableUserRow(user: user, isSelected: selection.contains(user.id)) {
                            if selection.contains(user.id) {
                                selection.remove(user.id)
                            } else {
                                selection.insert(user.id)
                            }
                        }
                    }
                    Picker("Access", selection: $newRole) {
                        ForEach(PersonShareRole.allCases, id: \.self) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .accessibilityIdentifier("person-access-role")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Add People")
        } footer: {
            if !candidates.isEmpty {
                Text(newRole.hint)
            }
        }
    }

    private func sharedRow(_ share: PersonUserShare) -> some View {
        HStack(spacing: 12) {
            SharingUserLabel(user: share.sharedWith)
            Spacer(minLength: 8)
            Menu {
                Picker("Access", selection: Binding(
                    get: { share.role },
                    set: { role in Task { await change(share, to: role) } }
                )) {
                    ForEach(PersonShareRole.allCases, id: \.self) { role in
                        Text(role.title).tag(role)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    userToRemove = share
                } label: {
                    Label("Stop Sharing", systemImage: "person.badge.minus")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(share.role.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .font(.subheadline)
            }
            .disabled(mutatingUserIDs.contains(share.sharedWithId))
            .accessibilityLabel("Access of \(share.sharedWith.name)")
            .accessibilityValue(share.role.title)
        }
        .confirmationDialog(
            "Stop sharing with \(share.sharedWith.name)?",
            isPresented: .init(
                get: { userToRemove?.id == share.id },
                set: { if !$0 { userToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                Task { await remove(share) }
            }
        } message: {
            Text("They will no longer see \(displayName).")
        }
    }

    // MARK: - loading

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        async let fetchedShares = client.personUsers(personID: person.id)
        async let fetchedMembers = session.clusterGroupMembers()
        do {
            shares = try await fetchedShares
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't load who has access"), error: error)
        }
        isLoading = false
        members = (try? await fetchedMembers) ?? []
    }

    // MARK: - mutations

    private func share() async {
        guard let client = session.client, !isSharing, !selection.isEmpty else { return }
        isSharing = true
        defer { isSharing = false }
        let userIDs = Array(selection)
        do {
            try await client.sharePeople(personIDs: [person.id], with: userIDs, role: newRole)
            selection.removeAll()
            if let fresh = try? await client.personUsers(personID: person.id) { shares = fresh }
            onChange()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't share \(displayName)"), error: error)
        }
    }

    private func change(_ share: PersonUserShare, to role: PersonShareRole) async {
        guard let client = session.client, role != share.role,
              mutatingUserIDs.insert(share.sharedWithId).inserted else { return }
        defer { mutatingUserIDs.remove(share.sharedWithId) }
        let previous = shares
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't change the access of \(share.sharedWith.name)"),
            apply: { replace(share, role: role) },
            rollback: { shares = previous },
            request: { try await client.sharePeople(personIDs: [person.id], with: [share.sharedWithId], role: role) },
            commit: { _ in onChange() }
        )
    }

    private func remove(_ share: PersonUserShare) async {
        guard let client = session.client, mutatingUserIDs.insert(share.sharedWithId).inserted else { return }
        defer { mutatingUserIDs.remove(share.sharedWithId) }
        let previous = shares
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't stop sharing with \(share.sharedWith.name)"),
            apply: {
                userToRemove = nil
                shares.removeAll { $0.id == share.id }
            },
            rollback: { shares = previous },
            request: { try await client.unsharePerson(id: person.id, with: share.sharedWithId) },
            commit: { _ in onChange() }
        )
    }

    private func replace(_ share: PersonUserShare, role: PersonShareRole) {
        guard let index = shares.firstIndex(where: { $0.id == share.id }) else { return }
        shares[index] = PersonUserShare(
            personId: share.personId,
            sharedById: share.sharedById,
            sharedWithId: share.sharedWithId,
            role: role,
            sharedBy: share.sharedBy,
            sharedWith: share.sharedWith
        )
    }
}

/// upstream's bulk share modal for every person of the user: picked members
/// of the cluster group get them all in one role.
struct SharePeopleSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// members ticked when the sheet opens.
    var preselected: Set<String> = []
    var onShared: () -> Void = {}

    @State private var members: [User]?
    @State private var selection = Set<String>()
    @State private var role: PersonShareRole = .write
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            List {
                if let members {
                    if members.isEmpty {
                        Section {
                            Text("People can only be shared with the members of your cluster group.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            ForEach(members) { user in
                                SelectableUserRow(user: user, isSelected: selection.contains(user.id)) {
                                    if selection.contains(user.id) {
                                        selection.remove(user.id)
                                    } else {
                                        selection.insert(user.id)
                                    }
                                }
                            }
                        } header: {
                            Text("Share With")
                        } footer: {
                            Text("They can see or manage all of your people with you. Sharing people does not share any photos.")
                        }
                        Section {
                            Picker("Access", selection: $role) {
                                ForEach(PersonShareRole.allCases, id: \.self) { role in
                                    Text(role.title).tag(role)
                                }
                            }
                        } footer: {
                            Text(role.hint)
                        }
                    }
                }
            }
            .overlay {
                if members == nil { ProgressView() }
            }
            .navigationTitle("Share All People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { Task { await share() } }
                        .disabled(selection.isEmpty || isSharing)
                        .accessibilityIdentifier("share-people-confirm")
                }
            }
            .interactiveDismissDisabled(isSharing)
            .task {
                selection = preselected
                members = (try? await session.clusterGroupMembers()) ?? []
            }
        }
    }

    private func share() async {
        guard let client = session.client, !isSharing, !selection.isEmpty else { return }
        isSharing = true
        defer { isSharing = false }
        do {
            try await client.sharePeople(personIDs: nil, with: Array(selection), role: role)
            onShared()
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't share your people"), error: error)
        }
    }
}
