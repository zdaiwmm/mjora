import Foundation
import SwiftUI

/// full grid of everyone the server recognizes, with hidden people management,
/// favorites, merging and birth dates a long press away.
struct PeopleScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    @State private var people: [Person] = []
    @State private var isLoading = true
    /// one full-list fetch at a time - appear and scene activation can fire
    /// together and each is a whole pagination walk.
    @State private var isReloading = false
    @State private var showHidden = false
    @State private var searchText = ""
    @State private var renamingPerson: Person?
    @State private var renameDraft = ""
    @State private var birthDatePerson: Person?
    @State private var mergeTarget: Person?
    /// serializes mutations per person so a re-opened context menu cannot
    /// stack conflicting requests.
    @State private var mutatingIDs = Set<String>()
    /// gallery's pet detection lists pets among the people. the switch only
    /// shows once the server returned one.
    @State private var showsPets = false
    /// people sharing filters: people one user gave another. nil is anyone.
    @State private var sharedByID: String?
    @State private var sharedWithID: String?
    /// the other members of the cluster group, who the filters can name.
    @State private var groupMembers: [User] = []
    @State private var showShareAll = false

    private var isFiltered: Bool { sharedByID != nil || sharedWithID != nil }

    private var hasPets: Bool { people.contains(where: \.isPet) }

    private var shownKind: [Person] {
        guard hasPets else { return people }
        return people.filter { $0.isPet == showsPets }
    }

    private var visiblePeople: [Person] {
        filtered(shownKind.filter { $0.isHidden != true })
    }

    private var hiddenPeople: [Person] {
        filtered(shownKind.filter { $0.isHidden == true })
    }

    private func filtered(_ list: [Person]) -> [Person] {
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]
    }

    var body: some View {
        // computed once per pass: the same locale-aware filter used to run up
        // to six times per keystroke through the body and its overlay.
        let visible = visiblePeople
        let hidden = hiddenPeople
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if hasPets {
                    Picker("Show", selection: $showsPets.animation(.smooth(duration: 0.25))) {
                        Text("People").tag(false)
                        Text("Pets").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("people-kind")
                }
                if !visible.isEmpty {
                    grid(visible)
                }

                if showHidden, !hidden.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Hidden", systemImage: "eye.slash")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        grid(hidden)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle(showsPets && hasPets ? "Pets" : "People")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: showsPets && hasPets ? "Search pets" : "Search people")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showHidden.animation(.smooth(duration: 0.25))) {
                        Label("Show Hidden People", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("people-show-hidden")
                    if session.capabilities.supportsPeopleSharing {
                        Section {
                            sharedFilterMenu(String(localized: "Shared By"), systemImage: "person.crop.circle.badge.arrow.forward", selection: $sharedByID)
                            sharedFilterMenu(String(localized: "Shared With"), systemImage: "person.crop.circle.badge.checkmark", selection: $sharedWithID)
                        }
                        Section {
                            Button {
                                showShareAll = true
                            } label: {
                                Label("Share All People", systemImage: "person.2.badge.plus")
                            }
                            .accessibilityIdentifier("people-share-all")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .overlay {
            if isLoading && people.isEmpty {
                ProgressView()
            } else if visible.isEmpty && (!showHidden || hidden.isEmpty) {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        showsPets && hasPets ? "No Pets" : "No People",
                        systemImage: "person.2.slash",
                        description: Text(isFiltered
                            ? "Nobody matches these filters."
                            : "People show up here once faces are recognized.")
                    )
                }
            }
        }
        .task { await load() }
        .task {
            guard session.capabilities.supportsPeopleSharing else { return }
            groupMembers = (try? await session.clusterGroupMembers()) ?? []
        }
        .onChange(of: sharedByID) { reloadFiltered() }
        .onChange(of: sharedWithID) { reloadFiltered() }
        .sheet(isPresented: $showShareAll) {
            SharePeopleSheet()
        }
        // returning from a person page picks up renames, merges and hides.
        .onAppear {
            if !people.isEmpty {
                Task { await load() }
            }
        }
        // coming back to the app does not re-appear this screen, so an edit
        // made elsewhere meanwhile - a new featured photo - needs its own pass.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !people.isEmpty {
                Task { await load() }
            }
        }
        .alert(
            renamingPerson?.name.isEmpty == false ? "Rename" : "Add a Name",
            isPresented: Binding(
                get: { renamingPerson != nil },
                set: { if !$0 { renamingPerson = nil } }
            )
        ) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let renamingPerson {
                    Task { await rename(renamingPerson, to: renameDraft) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $birthDatePerson) { person in
            PersonBirthDateSheet(person: person) { value in
                Task { await setBirthDate(person, to: value) }
            }
        }
        .sheet(item: $mergeTarget) { person in
            MergePeopleSheet(target: person) { _, mergedIDs in
                people.removeAll { mergedIDs.contains($0.id) }
            }
        }
    }

    private var subtitle: String {
        let count = shownKind.count { $0.isHidden != true }
        guard count > 0 else { return "" }
        if showsPets && hasPets { return count == 1 ? String(localized: "1 Pet") : String(localized: "\(count) Pets") }
        return count == 1 ? String(localized: "1 Person") : String(localized: "\(count) People")
    }

    private func grid(_ list: [Person]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(list) { person in
                NavigationLink(value: person) {
                    PersonGridCell(person: person)
                }
                .buttonStyle(PressableCardStyle())
                .disabled(mutatingIDs.contains(person.id))
                .accessibilityIdentifier("people-cell-\(person.id)")
                .contextMenu { contextMenu(for: person) }
            }
        }
    }

    private func sharedFilterMenu(_ title: String, systemImage: String, selection: Binding<String?>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                Text("Anyone").tag(String?.none)
                if let myID = session.user?.id {
                    Text("You").tag(Optional(myID))
                }
                ForEach(groupMembers) { user in
                    Text(user.name).tag(Optional(user.id))
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
            Text(filterName(selection.wrappedValue))
        }
    }

    private func filterName(_ userID: String?) -> String {
        guard let userID else { return String(localized: "Anyone") }
        if userID == session.user?.id { return String(localized: "You") }
        return groupMembers.first { $0.id == userID }?.name ?? String(localized: "Someone")
    }

    /// a filtered list starts over rather than reconciling the last one.
    private func reloadFiltered() {
        people = []
        isLoading = true
        Task { await load() }
    }

    @ViewBuilder private func contextMenu(for person: Person) -> some View {
        let isFavorite = person.isFavorite == true
        let isHidden = person.isHidden == true

        Button {
            Task { await setFavorite(person, to: !isFavorite) }
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
        }

        Button {
            renameDraft = person.name
            renamingPerson = person
        } label: {
            Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
        }

        Button {
            birthDatePerson = person
        } label: {
            Label(
                person.birthDate == nil ? "Set Date of Birth" : "Edit Date of Birth",
                systemImage: "birthday.cake"
            )
        }

        Button {
            mergeTarget = person
        } label: {
            Label("Merge People", systemImage: "arrow.triangle.merge")
        }

        Divider()

        Button {
            Task { await setHidden(person, to: !isHidden) }
        } label: {
            Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
        }
    }

    // MARK: - loading

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        let filter = (by: sharedByID, with: sharedWithID)
        // the offline copy is the whole list, so a filtered one never uses it.
        let account = isFiltered ? nil : client.offlineAccountKey
        // last session's list paints instantly, offline included; the fetch
        // below reconciles it.
        if people.isEmpty, let account {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Person].self, key: "people", account: account)
            }.value
            if let cached, people.isEmpty, mutatingIDs.isEmpty {
                people = cached
                isLoading = false
            }
        }
        // hidden people ride along so managing them needs no second fetch.
        // pages are 1-based and usually just one.
        var all: [Person] = []
        var page = 1
        while true {
            guard let response = try? await client.people(
                withHidden: true,
                page: page,
                sharedByID: filter.by,
                sharedWithID: filter.with
            ) else {
                isLoading = false
                return
            }
            all.append(contentsOf: response.people)
            guard response.hasNextPage == true else { break }
            page += 1
        }
        // the filters changed mid walk. this one is stale, the next starts
        // once this call has returned.
        guard filter.by == sharedByID, filter.with == sharedWithID else {
            Task { await load() }
            return
        }
        isLoading = false
        // a refetch that raced an optimistic mutation must not clobber the
        // projection, and an identical list is not worth a full grid diff.
        guard mutatingIDs.isEmpty, all != people else { return }
        people = all
        if let account {
            let snapshot = all
            Task.detached(priority: .utility) {
                OfflineCache.store(snapshot, key: "people", account: account)
            }
        }
    }

    // MARK: - mutations

    private func update(_ id: String, _ mutation: (inout Person) -> Void) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        mutation(&people[index])
    }

    private func setFavorite(_ person: Person, to value: Bool) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.isFavorite
        await OptimisticAction.perform(
            errorMessage: value ? String(localized: "Couldn't favorite this person") : String(localized: "Couldn't unfavorite this person"),
            apply: { update(person.id) { $0.isFavorite = value } },
            rollback: { update(person.id) { $0.isFavorite = previous } },
            request: { try await client.updatePerson(id: person.id, isFavorite: value) }
        )
    }

    private func setHidden(_ person: Person, to value: Bool) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.isHidden
        await OptimisticAction.perform(
            errorMessage: value ? String(localized: "Couldn't hide this person") : String(localized: "Couldn't unhide this person"),
            apply: { update(person.id) { $0.isHidden = value } },
            rollback: { update(person.id) { $0.isHidden = previous } },
            request: { try await client.updatePerson(id: person.id, isHidden: value) }
        )
    }

    private func rename(_ person: Person, to requestedName: String) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.name
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't rename this person"),
            apply: { update(person.id) { $0.name = requestedName } },
            rollback: { update(person.id) { $0.name = previous } },
            request: {
                try await client.updatePerson(id: person.id, name: requestedName, userID: session.personEditUserID)
            }
        )
    }

    private func setBirthDate(_ person: Person, to value: String?) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.birthDate
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't save the date of birth"),
            apply: { update(person.id) { $0.birthDate = value } },
            rollback: { update(person.id) { $0.birthDate = previous } },
            request: {
                try await client.updatePerson(id: person.id, birthDate: .some(value), userID: session.personEditUserID)
            }
        )
    }
}

private struct PersonGridCell: View {
    let person: Person

    private var isHidden: Bool { person.isHidden == true }

    var body: some View {
        VStack(spacing: 7) {
            PersonAvatar(person: person, targetPixelSize: 320)
                .opacity(isHidden ? 0.45 : 1)
                .overlay {
                    if isHidden {
                        Image(systemName: "eye.slash.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if person.isPet {
                        Image(systemName: "pawprint.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: .circle)
                            .accessibilityHidden(true)
                    }
                }

            Text(person.name.isEmpty ? unnamedTitle : person.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// an unnamed pet reads as its species, "Dog", the way gallery lists it.
    private var unnamedTitle: String {
        guard person.isPet else { return String(localized: "Unnamed") }
        switch person.species?.lowercased() {
        case "cat": return String(localized: "Cat")
        case "dog": return String(localized: "Dog")
        default: return String(localized: "Pet")
        }
    }

    private var unnamedPetTitle: String {
        switch person.species?.lowercased() {
        case "cat": String(localized: "Unnamed cat")
        case "dog": String(localized: "Unnamed dog")
        default: String(localized: "Unnamed pet")
        }
    }

    private var accessibilitySummary: String {
        var parts = [person.name.isEmpty ? (person.isPet ? unnamedPetTitle : String(localized: "Unnamed person")) : person.name]
        if person.isFavorite == true { parts.append(String(localized: "favorite")) }
        if isHidden { parts.append(String(localized: "hidden")) }
        return parts.joined(separator: ", ")
    }
}
