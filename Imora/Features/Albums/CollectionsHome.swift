import SwiftUI

nonisolated enum CollectionsRoute: Hashable {
    case albums, recent, memories
    case media(PhotoMediaFilter)
}

struct CollectionsHome: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let albums: [Album]
    let isLoading: Bool
    let loadFailed: Bool
    @Binding var layout: CollectionsLayout
    let onRetry: () -> Void
    let onEditPins: () -> Void
    @State private var people: [Person] = []
    @State private var changingPeople = Set<String>()
    @ScaledMetric(relativeTo: .body) private var previewSide = 112.0

    private var availableSections: [CollectionSection] {
        layout.sections.filter {
            switch $0 {
            case .memories: session.preferences?.memoriesEnabled != false
            case .people: session.preferences?.peopleEnabled != false
            case .spaces: session.capabilities.supportsSharedSpaces
            default: true
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(availableSections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section)
                        if !layout.collapsed.contains(section) { content(section) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("collections-home")
        .task(id: session.client?.offlineAccountKey) { await loadPeople() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadPeople() } }
        }
    }

    private func sectionHeader(_ section: CollectionSection) -> some View {
        HStack(spacing: 8) {
            Group {
                switch section {
                case .albums: heading(section, value: CollectionsRoute.albums)
                case .memories: heading(section, value: CollectionsRoute.memories)
                case .people: heading(section, value: LibraryDestination.people)
                case .places: heading(section, value: LibraryDestination.places)
                default: Text(section.title).font(.title3.bold())
                }
            }
            Spacer(minLength: 8)
            if section == .pinned {
                Button("Edit", action: onEditPins)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier("collections-edit-pins")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { layout.toggleCollapsed(section) }
            } label: {
                Image(systemName: layout.collapsed.contains(section) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .accessibilityLabel(layout.collapsed.contains(section) ? "Expand \(section.title)" : "Collapse \(section.title)")
            .accessibilityIdentifier("collections-collapse-\(section.rawValue)")
        }
        .frame(minHeight: 30)
    }

    private func heading<Value: Hashable>(_ section: CollectionSection, value: Value) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 5) {
                Text(section.title).font(.title3.bold())
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("collections-\(section.rawValue)")
    }

    @ViewBuilder private func content(_ section: CollectionSection) -> some View {
        switch section {
        case .memories:
            if layout.previewSize == .none {
                NavigationLink(value: CollectionsRoute.memories) {
                    collectionRow(String(localized: "Memories"), symbol: "sparkles.rectangle.stack")
                }
            } else {
                MemoryLane(showsHeading: false, cardWidth: layout.previewSize == .large ? 221 : 160,
                           cardHeight: layout.previewSize == .large ? 202 : 140,
                           cornerRadius: 22, contentInset: 0, showsEmptyPlaceholder: true)
                    .padding(.trailing, -16)
            }
        case .pinned:
            previewStrip {
                ForEach(layout.pinnedIDs, id: \.self) { id in pinnedLink(id) }
                if layout.pinnedIDs.isEmpty {
                    Button(action: onEditPins) {
                        Label("Add Pinned Collections", systemImage: "plus")
                            .frame(minHeight: 80)
                    }
                }
            }
        case .albums:
            if !albums.isEmpty {
                previewStrip {
                    ForEach(albums.prefix(12)) { album in
                        NavigationLink(value: album) {
                            CollectionsPreview(id: "album:\(album.id)", title: album.albumName,
                                               symbol: album.shared ? "person.2.fill" : "rectangle.stack.fill",
                                               albumCoverID: album.albumThumbnailAssetId, previewSize: layout.previewSize)
                        }
                        .buttonStyle(.plain)
                        .disabled(album.isPending)
                        .contextMenu {
                            Button { layout.togglePin("album:\(album.id)") } label: {
                                Label(layout.pinnedIDs.contains("album:\(album.id)") ? "Unpin Collection" : "Pin Collection",
                                      systemImage: "pin")
                            }
                        }
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: previewSide)
            } else if loadFailed {
                Button(action: onRetry) { Label("Couldn't load albums. Retry", systemImage: "arrow.clockwise") }
                    .frame(minHeight: previewSide)
            } else {
                NavigationLink(value: CollectionsRoute.albums) {
                    Label("Create Your First Album", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: previewSide, alignment: .leading)
                        .padding(.horizontal, 16)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
                }
            }
        case .people:
            if people.isEmpty {
                destination(.people, title: String(localized: "See All People"), symbol: "person.2.fill")
            } else if layout.previewSize == .none {
                VStack(spacing: 0) {
                    ForEach(people.prefix(8)) { person in
                        NavigationLink(value: person) {
                            collectionRow(person.name.isEmpty ? String(localized: "Unnamed person") : person.name,
                                          symbol: person.isPet ? "pawprint" : "person")
                        }
                        .disabled(changingPeople.contains(person.id))
                        .contextMenu { personMenu(person) }
                    }
                }
            } else {
                horizontalStrip {
                    ForEach(people.prefix(8)) { person in
                        NavigationLink(value: person) {
                            VStack(spacing: 6) {
                                PersonAvatar(person: person, targetPixelSize: 228).frame(width: 68, height: 68)
                                Text(person.name.isEmpty ? String(localized: "Unnamed person") : person.name)
                                    .font(.caption).lineLimit(1).frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(changingPeople.contains(person.id))
                        .contextMenu { personMenu(person) }
                    }
                }
            }
        case .places:
            if layout.previewSize == .none {
                destination(.places, title: String(localized: "Explore Your Places"), symbol: "map.fill")
            } else {
            NavigationLink(value: LibraryDestination.places) {
                Label("Explore Your Places", systemImage: "map.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                    .padding(.horizontal, 18)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            }
            .accessibilityIdentifier("collections-places-map")
            }
        case .media:
            VStack(spacing: 0) {
                ForEach([PhotoMediaFilter.photos, .videos, .livePhotos]) { type in
                    NavigationLink(value: CollectionsRoute.media(type)) {
                        collectionRow(type.title, symbol: type.symbol)
                    }
                    .accessibilityIdentifier("collections-media-\(type.rawValue)")
                }
            }
        case .utilities:
            VStack(spacing: 0) {
                if session.capabilities.supportsCleanup {
                    destination(.cleanup, title: String(localized: "Clean Up"), symbol: "sparkles")
                }
                if session.features?.duplicateDetection != false {
                    destination(.duplicates, title: String(localized: "Duplicates"), symbol: "square.on.square")
                }
                destination(.largeFiles, title: String(localized: "Large Files"), symbol: "externaldrive")
            }
        case .more:
            VStack(spacing: 0) {
                destination(.archive, title: String(localized: "Archive"), symbol: "archivebox")
                destination(.locked, title: String(localized: "Locked Folder"), symbol: "lock")
                if session.features?.trash != false {
                    destination(.trash, title: String(localized: "Recently Deleted"), symbol: "trash")
                }
            }
        case .spaces:
            destination(.spaces, title: String(localized: "Shared Spaces"), symbol: "person.3")
        }
    }

    @ViewBuilder private func pinnedLink(_ id: String) -> some View {
        if id.hasPrefix("album:"), let album = albums.first(where: { "album:\($0.id)" == id }) {
            NavigationLink(value: album) {
                CollectionsPreview(id: id, title: album.albumName, symbol: "rectangle.stack.fill",
                                   albumCoverID: album.albumThumbnailAssetId, previewSize: layout.previewSize)
            }.buttonStyle(.plain).disabled(album.isPending)
        } else if id == "recent" {
            NavigationLink(value: CollectionsRoute.recent) {
                CollectionsPreview(id: id, title: String(localized: "Recently Added"), symbol: "clock", previewSize: layout.previewSize)
            }.buttonStyle(.plain)
        } else if let destination = shortcutDestination(id), isAvailable(destination) {
            NavigationLink(value: destination) {
                CollectionsPreview(id: id, title: shortcutTitle(id), symbol: shortcutSymbol(id), previewSize: layout.previewSize)
            }.buttonStyle(.plain)
        }
    }

    private func destination(_ value: LibraryDestination, title: String, symbol: String) -> some View {
        NavigationLink(value: value) { collectionRow(title, symbol: symbol) }
            .accessibilityIdentifier("collections-\(shortcutID(value))")
    }

    private func collectionRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.primary).frame(width: 27)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 49)
        .contentShape(.rect)
    }

    @ViewBuilder private func previewStrip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if layout.previewSize == .none { VStack(spacing: 0, content: content) }
        else { horizontalStrip(content: content) }
    }

    private func horizontalStrip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10, content: content).scrollTargetLayout()
        }
        .contentMargins(.trailing, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .padding(.trailing, -16)
    }

    private func isAvailable(_ destination: LibraryDestination) -> Bool {
        if destination == .spaces { return session.capabilities.supportsSharedSpaces }
        return session.collectionsAvailability.allows(shortcutID(destination))
    }

    @ViewBuilder private func personMenu(_ person: Person) -> some View {
        Button {
            Task { await changePerson(person, favorite: person.isFavorite != true, hidden: nil) }
        } label: { Label(person.isFavorite == true ? "Unfavorite" : "Favorite", systemImage: "heart") }
        Button { Task { await changePerson(person, favorite: nil, hidden: true) } } label: {
            Label("Hide Person", systemImage: "eye.slash")
        }
    }

    private func changePerson(_ person: Person, favorite: Bool?, hidden: Bool?) async {
        guard let client = session.client, changingPeople.insert(person.id).inserted else { return }
        defer { changingPeople.remove(person.id) }
        do {
            try await client.updatePerson(id: person.id, isHidden: hidden, isFavorite: favorite)
            await loadPeople()
        } catch { ErrorToastCenter.shared.show(String(localized: "Couldn't update this person."), error: error) }
    }

    private func loadPeople() async {
        guard session.preferences?.peopleEnabled != false, let client = session.client else { return }
        let account = client.offlineAccountKey
        if let account, people.isEmpty {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Person].self, key: "people", account: account)
            }.value
            guard session.client === client else { return }
            if let cached { people = cached.filter { $0.isHidden != true } }
        }
        guard let response = try? await client.people(), session.client === client else { return }
        people = response.people.filter { $0.isHidden != true }
    }
}

private struct CollectionsPreview: View {
    @Environment(SessionStore.self) private var session
    let id: String
    let title: String
    let symbol: String
    var albumCoverID: String? = nil
    var previewSize: CollectionPreviewSize = .large
    @State private var cover: Asset?
    @State private var portraitURL: URL?
    @ScaledMetric(relativeTo: .body) private var largeSide = 160.0
    @ScaledMetric(relativeTo: .body) private var smallSide = 112.0
    private var side: CGFloat { previewSize == .large ? largeSide : smallSide }

    private var assetID: String? { albumCoverID ?? cover?.id }
    var body: some View {
        Group {
            if previewSize == .none {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.title3).frame(width: 27)
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 49)
                .contentShape(.rect)
            } else { preview }
        }
        .accessibilityLabel(title)
        .task(id: "\(session.client?.offlineAccountKey ?? ""):\(id):\(previewSize.rawValue)") {
            await loadCover()
        }
    }

    private var preview: some View {
        Color(.secondarySystemBackground)
            .frame(width: side, height: side)
            .overlay {
                if let assetID, let client = session.client {
                    RemoteImage(url: client.thumbnailURL(assetID: assetID), targetPixelSize: 400,
                                thumbhash: cover?.thumbhash)
                } else if let portraitURL {
                    RemoteImage(url: portraitURL, targetPixelSize: 400)
                } else { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary) }
            }
            .overlay {
                if assetID != nil || portraitURL != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(assetID == nil && portraitURL == nil ? Color.primary : .white)
                    .padding(10)
            }
            .clipShape(.rect(cornerRadius: 18))
    }

    private func loadCover() async {
        cover = nil
        portraitURL = nil
        guard previewSize != .none, albumCoverID == nil, let client = session.client else { return }
        if id == "places" {
            guard let asset = try? await client.cities().first, !Task.isCancelled, session.client === client else { return }
            portraitURL = client.thumbnailURL(assetID: asset.id)
            return
        }
        if id == "people" {
            guard let person = try? await client.people().people.first, !Task.isCancelled, session.client === client else { return }
            portraitURL = client.personThumbnailURL(personID: person.id, cacheKey: person.updatedAt)
            return
        }
        let filter: TimelineFilter
        if id == "recent" { filter = TimelineFilter(orderBy: "createdAt") }
        else if id == "archive" { filter = TimelineFilter(visibility: .archive) }
        else if id != "favorites" { return }
        else if session.capabilities.supportsFavoritesAcrossSpaces {
            filter = TimelineFilter(visibility: nil, withPartners: true, withSharedSpaces: true, isFavorite: true)
        } else { filter = TimelineFilter(isFavorite: true) }
        guard let bucket = try? await client.timeBuckets(filter).first,
              let result = try? await client.timeBucket(bucket.timeBucket, filter: filter), !Task.isCancelled, session.client === client else { return }
        cover = result.assets.first
    }
}

func shortcutDestination(_ id: String) -> LibraryDestination? {
    switch id {
    case "favorites": .favorites
    case "places": .places
    case "people": .people
    case "archive": .archive
    case "locked": .locked
    case "trash": .trash
    case "duplicates": .duplicates
    case "largeFiles": .largeFiles
    case "cleanup": .cleanup
    default: nil
    }
}

func shortcutID(_ destination: LibraryDestination) -> String {
    switch destination {
    case .favorites: "favorites"
    case .places: "places"
    case .people: "people"
    case .archive: "archive"
    case .locked: "locked"
    case .trash: "trash"
    case .duplicates: "duplicates"
    case .largeFiles: "largeFiles"
    case .cleanup: "cleanup"
    case .spaces: "spaces"
    }
}

func shortcutTitle(_ id: String) -> String {
    switch id {
    case "favorites": String(localized: "Favorites")
    case "recent": String(localized: "Recently Added")
    case "places": String(localized: "Places")
    case "people": String(localized: "People & Pets")
    case "archive": String(localized: "Archive")
    case "locked": String(localized: "Locked Folder")
    case "trash": String(localized: "Recently Deleted")
    case "duplicates": String(localized: "Duplicates")
    case "largeFiles": String(localized: "Large Files")
    case "cleanup": String(localized: "Clean Up")
    default: id
    }
}

func shortcutSymbol(_ id: String) -> String {
    switch id {
    case "favorites": "heart.fill"
    case "recent": "clock"
    case "places": "map.fill"
    case "people": "person.2.fill"
    case "archive": "archivebox"
    case "locked": "lock"
    case "trash": "trash"
    case "duplicates": "square.on.square"
    case "largeFiles": "externaldrive"
    case "cleanup": "sparkles"
    default: "rectangle.stack"
    }
}
