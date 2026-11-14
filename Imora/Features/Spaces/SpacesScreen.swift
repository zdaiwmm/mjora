import Foundation
import SwiftUI

// experimental support for noodle's gallery shared spaces. only reachable
// when the session detected gallery, see `ServerCapabilities`.

/// every space the user belongs to, newest activity first as the server sorts.
struct SpacesScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var spaces: [SharedSpace] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showCreate = false
    @State private var showGroups = false
    @State private var createdSpace: SharedSpace?

    var body: some View {
        List(spaces) { space in
            NavigationLink(value: space) {
                SpaceRow(space: space)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Shared Spaces")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if spaces.isEmpty {
                if isLoading {
                    ProgressView()
                } else if loadFailed {
                    ContentUnavailableView {
                        Label("Couldn't Load Spaces", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Shared Spaces", systemImage: "person.3")
                    } description: {
                        Text("A space is a timeline several people add photos to.")
                    } actions: {
                        Button("New Space") { showCreate = true }
                    }
                }
            }
        }
        .toolbar {
            if session.capabilities.supportsUserGroups {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGroups = true
                    } label: {
                        Image(systemName: "person.2.circle")
                    }
                    .accessibilityLabel("User Groups")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Space")
            }
        }
        .sheet(isPresented: $showCreate) {
            SpaceEditSheet { space in
                spaces.insert(space, at: 0)
                createdSpace = space
            }
        }
        .navigationDestination(isPresented: $showGroups) {
            UserGroupsScreen()
        }
        .navigationDestination(item: $createdSpace) { space in
            SpaceScreen(space: space)
        }
        .refreshable { await load() }
        .task(id: session.client == nil) { await load() }
        // returning from a space picks up renames, deletes and leaves.
        .onAppear {
            if !spaces.isEmpty {
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        defer { isLoading = false }
        do {
            spaces = try await client.sharedSpaces()
            loadFailed = false
        } catch {
            loadFailed = spaces.isEmpty
        }
    }
}

private struct SpaceRow: View {
    @Environment(SessionStore.self) private var session
    let space: SharedSpace

    var body: some View {
        HStack(spacing: 14) {
            SpaceCover(space: space, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(space.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let new = space.newAssetCount, new > 0 {
                Text("\(new) new")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: .capsule)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if let assets = space.assetCount { parts.append(assets == 1 ? String(localized: "1 item") : String(localized: "\(assets) items")) }
        if let members = space.memberCount ?? space.members?.count {
            parts.append(members == 1 ? String(localized: "1 member") : String(localized: "\(members) members"))
        }
        if let role = space.role(of: session.user?.id) { parts.append(role.title) }
        return parts.joined(separator: " · ")
    }
}

struct SpaceCover: View {
    @Environment(SessionStore.self) private var session
    let space: SharedSpace
    let size: CGFloat

    var body: some View {
        Group {
            if let assetID = space.coverAssetID, let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: assetID), targetPixelSize: size * 3)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.22))
    }
}

/// one space's timeline, with its members and linked albums on top.
struct SpaceScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var space: SharedSpace
    @State private var albums: [SharedSpaceAlbum] = []
    @State private var showMembers = false
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var isMutating = false

    private var myRole: SharedSpaceRole? { space.role(of: session.user?.id) }
    private var myMember: SharedSpaceMember? {
        space.members?.first { $0.userId == session.user?.id }
    }

    init(space: SharedSpace) {
        _space = State(initialValue: space)
    }

    var body: some View {
        TimelineScreen(
            title: space.name,
            filter: TimelineFilter(visibility: nil, spaceId: space.id),
            emptyIcon: "person.3",
            emptyMessage: String(localized: "This space is empty"),
            showsLargeTitle: false,
            canRemoveFromSpace: myRole?.canAddAssets == true,
            trailingItems: {
                ToolbarItem(placement: .topBarTrailing) {
                    menu
                }
            }
        ) {
            SpaceHeader(space: space, albums: albums) { showMembers = true }
        }
        .navigationDestination(for: SharedSpaceAlbum.self) { album in
            TimelineScreen(
                title: album.albumName,
                filter: TimelineFilter(visibility: nil, albumId: album.id, order: album.order),
                emptyIcon: "rectangle.stack",
                emptyMessage: String(localized: "This album is empty"),
                showsLargeTitle: false
            )
        }
        .sheet(isPresented: $showMembers) {
            SpaceMembersSheet(space: space) {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showEdit) {
            SpaceEditSheet(space: space) { saved in
                space.name = saved.name
                space.description = saved.description
            }
        }
        .task { await refresh() }
    }

    private var menu: some View {
        Menu {
            Button {
                showMembers = true
            } label: {
                Label("Members", systemImage: "person.2")
            }
            if myRole == .owner {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit Space", systemImage: "pencil")
                }
            }
            if let myMember {
                Toggle(isOn: Binding(
                    get: { myMember.showInTimeline ?? true },
                    set: { shown in Task { await setShownInTimeline(shown) } }
                )) {
                    Label("Show on My Timeline", systemImage: "photo.on.rectangle")
                }
            }
            Divider()
            if myRole == .owner {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Space", systemImage: "trash")
                }
            } else if myRole != nil {
                Button(role: .destructive) {
                    confirmLeave = true
                } label: {
                    Label("Leave Space", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(isMutating)
        .accessibilityLabel("More")
        // anchored on the menu button: ios 26 morphs dialogs out of their source.
        .confirmationDialog("Delete \"\(space.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Space", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The space is removed for everyone. Photos stay in their owners' libraries.")
        }
        .confirmationDialog("Leave \"\(space.name)\"?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Space", role: .destructive) { Task { await leave() } }
        } message: {
            Text("You will no longer see this space. Photos you added stay in your library.")
        }
    }

    private func setShownInTimeline(_ shown: Bool) async {
        guard let client = session.client, let userID = session.user?.id,
              let index = space.members?.firstIndex(where: { $0.userId == userID }) else { return }
        let previous = space.members?[index].showInTimeline
        await OptimisticAction.perform(
            errorMessage: String(localized: "Couldn't change the timeline setting."),
            apply: { space.members?[index].showInTimeline = shown },
            rollback: { space.members?[index].showInTimeline = previous },
            request: { try await client.setSharedSpaceShownInTimeline(spaceID: space.id, shown) }
        )
    }

    private func delete() async {
        guard let client = session.client, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await client.deleteSharedSpace(id: space.id)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't delete the space."), error: error)
        }
    }

    private func leave() async {
        guard let client = session.client, let userID = session.user?.id, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await client.removeSharedSpaceMember(spaceID: space.id, userID: userID)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't leave the space."), error: error)
        }
    }

    private func refresh() async {
        guard let client = session.client else { return }
        if let fresh = try? await client.sharedSpace(id: space.id) {
            space = fresh
        }
        // linked albums came with gallery 5.2, which also added the count.
        if space.supportsAlbums, space.albumCount != 0,
           let fetched = try? await client.sharedSpaceAlbums(id: space.id) {
            albums = fetched
        }
    }
}

private struct SpaceHeader: View {
    @Environment(SessionStore.self) private var session
    let space: SharedSpace
    let albums: [SharedSpaceAlbum]
    let onMembersTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = space.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let members = space.members, !members.isEmpty {
                Button(action: onMembersTap) {
                    HStack(spacing: -8) {
                        ForEach(members.prefix(6)) { member in
                            UserAvatar(user: member.user, size: 30)
                                .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                        }
                        Text(members.count == 1 ? "1 member" : "\(members.count) members")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(members.count == 1 ? "1 member" : "\(members.count) members")
            }
            if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                SpaceAlbumCard(album: album)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct SpaceAlbumCard: View {
    @Environment(SessionStore.self) private var session
    let album: SharedSpaceAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let assetID = album.albumThumbnailAssetId, let client = session.client {
                    RemoteImage(url: client.thumbnailURL(assetID: assetID), targetPixelSize: 360)
                } else {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemFill))
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(.rect(cornerRadius: 14))
            Text(album.albumName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let count = album.assetCount {
                Text(count == 1 ? "1 item" : "\(count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, alignment: .leading)
    }
}

/// adds a selection to one of the spaces the user may add to.
struct SpacePickerSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    let onApplied: () -> Void

    @State private var spaces: [SharedSpace] = []
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List(spaces) { space in
                Button {
                    Task { await add(to: space) }
                } label: {
                    HStack(spacing: 12) {
                        SpaceCover(space: space, size: 44)
                        VStack(alignment: .leading) {
                            Text(space.name)
                                .foregroundStyle(.primary)
                            if let count = space.assetCount {
                                Text(count == 1 ? "1 item" : "\(count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(isWorking)
            }
            .navigationTitle("Add to Space")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if spaces.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            "No Spaces to Add To",
                            systemImage: "person.3",
                            description: Text("You need to be an owner or editor of a space.")
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                defer { isLoading = false }
                let userID = session.user?.id
                if let fetched = try? await session.client?.sharedSpaces() {
                    spaces = fetched.filter { $0.role(of: userID)?.canAddAssets == true }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func add(to space: SharedSpace) async {
        guard let client = session.client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.addAssets(spaceID: space.id, ids: assetIDs)
            dismiss()
            onApplied()
        } catch {
            ErrorToastCenter.shared.show(String(localized: "Couldn't add the selected items to the space."), error: error)
        }
    }
}
