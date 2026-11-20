import SwiftUI
import UIKit
import Photos
import MapKit

nonisolated enum CollectionsRoute: Hashable {
    case albums, recent, memories, map
    case media(PhotoMediaFilter)
    case deviceMedia(PhotoMediaFilter)
}

struct CollectionsHome: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.usesCompactPhotosNavigation) private var usesCompactPhotosNavigation
    let covers: CollectionsCoverStore
    let albums: [Album]
    let isLoading: Bool
    let loadFailed: Bool
    @Binding var layout: CollectionsLayout
    let onRetry: () -> Void
    let onEditPins: () -> Void
    @State private var people: [Person] = []
    @State private var memories: [Memory] = []
    @State private var changingPeople = Set<String>()
    @AppStorage(PhotosLibrarySource.preferenceKey) private var source = "all"
    @State private var mediaFacts = DeviceMediaFactsStore.shared
    @State private var mediaFactsError: String?
    @ScaledMetric(relativeTo: .body) private var previewSide = 112.0

    private var availableSections: [CollectionSection] {
        layout.sections.filter {
            switch $0 {
            case .memories: session.preferences?.memoriesEnabled != false && !memories.isEmpty
            case .albums: !albums.isEmpty || loadFailed
            case .people: session.preferences?.peopleEnabled != false
            case .spaces: session.capabilities.supportsSharedSpaces
            default: true
            }
        }
    }

    var body: some View {
        // The scroll view extends to the screen edge, so reserve the bar's
        // height and its full clearance from that edge.
        let compactNavigationMargin = PhotosNavigationBar.height + PhotosNavigationBar.bottomScreenClearance
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(availableSections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section)
                        if !layout.collapsed.contains(section) { content(section) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.bottom, usesCompactPhotosNavigation ? compactNavigationMargin : 0, for: .scrollContent)
        .ignoresSafeArea(edges: .bottom)
        .background(Color(.systemBackground))
        .environment(covers)
        .accessibilityIdentifier("collections-home")
        .task(id: session.client?.offlineAccountKey) { await loadPeople() }
        .task(id: session.client?.offlineAccountKey) { await loadMemories() }
        .task(id: "\(source)|\(mediaFacts.generation)|\(PhotoAccess.shared.status.rawValue)|\(layout.pinnedIDs)") {
            guard source == "local" || layout.pinnedIDs.contains(where: { $0.hasPrefix("deviceMedia:") }) else { return }
            do { mediaFactsError = nil; _ = try await mediaFacts.refresh() }
            catch is CancellationError { }
            catch { mediaFactsError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if source == "local" || layout.pinnedIDs.contains(where: { $0.hasPrefix("deviceMedia:") }) { mediaFacts.invalidate() }
                Task { await loadPeople() }
                Task { await loadMemories() }
            }
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
                withAnimation(PhotosMotion.layout) { layout.toggleCollapsed(section) }
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
                           cornerRadius: 22, contentInset: 0, suppliedMemories: memories,
                           onEmpty: { memories = [] })
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
                ZStack {
                    MapPreviewGate {
                        CollectionsMapPreview().id(session.client?.context.id)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    NavigationLink(value: CollectionsRoute.map) {
                        Label("Open Map", systemImage: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: .capsule)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("collections-places-map")
                }
                .frame(height: layout.previewSize == .large ? 220 : 160)
                .clipShape(.rect(cornerRadius: 22))
            }
        case .media:
          if source == "local" {
            deviceMediaContent
          } else {
            VStack(spacing: 0) {
                ForEach([PhotoMediaFilter.photos, .videos, .livePhotos]) { type in
                    NavigationLink(value: CollectionsRoute.media(type)) {
                        collectionRow(type.title, symbol: type.symbol)
                    }
                    .accessibilityIdentifier("collections-media-\(type.rawValue)")
                }
                Text("More media types are available On Device.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
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
        } else if id.hasPrefix("deviceMedia:"),
                  let media = PhotoMediaFilter(rawValue: String(id.dropFirst("deviceMedia:".count))),
                  let inventory = mediaFacts.inventory,
                  let category = media.deviceCategory, inventory.facts.counts(in: category).knownYes > 0 {
            deviceMediaLink(media, inventory: inventory, pinned: true)
        } else if let destination = shortcutDestination(id), isAvailable(destination) {
            NavigationLink(value: destination) {
                CollectionsPreview(id: id, title: shortcutTitle(id), symbol: shortcutSymbol(id), previewSize: layout.previewSize)
            }.buttonStyle(.plain)
        }
    }

    private var deviceMediaTypes: [PhotoMediaFilter] { PhotoMediaFilter.mediaTypes + [.screenshots, .edited] }

    @ViewBuilder private var deviceMediaContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PhotoAccess.shared.status == .limited ? String(localized: "On Device · Selected Photos Only") : String(localized: "On Device"))
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("collections-media-source")
            if let inventory = mediaFacts.inventory {
                if inventory.facts.coverage == .unavailable {
                    if PhotoAccess.shared.canAsk {
                        Button("Allow Photo Access") {
                            Task { _ = await PhotoLibraryService.requestFullAccess(); mediaFacts.invalidate() }
                        }.frame(minHeight: 44)
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Manage Photo Access", destination: url).frame(minHeight: 44)
                    }
                } else {
                    let known = deviceMediaTypes.filter { type in
                        type.deviceCategory.map { inventory.facts.counts(in: $0).knownYes > 0 } == true
                    }
                    previewStrip {
                        ForEach(known) { type in deviceMediaLink(type, inventory: inventory) }
                    }
                    if known.isEmpty { Text("No accessible photos on this device.").foregroundStyle(.secondary) }
                    if deviceMediaTypes.contains(where: { type in type.deviceCategory.map { inventory.facts.counts(in: $0).unknown > 0 } == true }) {
                        Text("Some media types have not been classified.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if inventory.facts.counts(in: .highFrameRate).knownYes > 0 {
                        Text("High frame rate does not confirm slow motion.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if let mediaFactsError {
                Text(mediaFactsError).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { mediaFacts.invalidate() }.frame(minHeight: 44)
            } else { ProgressView("Reading media types") }
        }
    }

    private func deviceMediaLink(_ media: PhotoMediaFilter, inventory: DeviceMediaInventory, pinned: Bool = false) -> some View {
        let category = media.deviceCategory!
        let ids = inventory.facts.identifiers(in: category)
        let cover = inventory.assets.first { ids.contains($0.localIdentifier) }?.asAsset(backedUp: false)
        let pin = "deviceMedia:\(media.rawValue)"
        return NavigationLink(value: CollectionsRoute.deviceMedia(media)) {
            CollectionsPreview(id: pin, title: media.title, symbol: media.symbol,
                previewSize: layout.previewSize, deviceCover: cover,
                subtitle: String(localized: "\(inventory.facts.counts(in: category).knownYes) items"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("collections-\(pinned ? "pinned-device-media" : "device-media")-\(media.rawValue)")
        .contextMenu {
            Button { layout.togglePin(pin) } label: {
                Label(layout.pinnedIDs.contains(pin) ? "Unpin Collection" : "Pin Collection", systemImage: "pin")
            }
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

    private func loadMemories() async {
        guard session.preferences?.memoriesEnabled != false, let client = session.client else { return }
        guard let fetched = try? await client.memories(), !Task.isCancelled, session.client === client else { return }
        let shown = fetched.filter { !$0.assets.isEmpty }
        memories = shown.filter(\.isBirthday) + shown.filter { !$0.isBirthday }
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
    @Environment(CollectionsCoverStore.self) private var covers
    @Environment(\.displayScale) private var displayScale
    let id: String
    let title: String
    let symbol: String
    var albumCoverID: String? = nil
    var previewSize: CollectionPreviewSize = .large
    var deviceCover: Asset? = nil
    var subtitle: String? = nil
    @ScaledMetric(relativeTo: .body) private var largeSide = 160.0
    @ScaledMetric(relativeTo: .body) private var smallSide = 112.0
    private var side: CGFloat { previewSize == .large ? largeSide : smallSide }

    private var cover: CollectionsCoverStore.Cover? {
        session.client.flatMap { covers.cached(id, client: $0,
            favoritesAcrossSpaces: session.capabilities.supportsFavoritesAcrossSpaces) }
    }
    var body: some View {
        Group {
            if previewSize == .none {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.title3).frame(width: 27)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 49)
                .contentShape(.rect)
            } else { preview }
        }
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .task(id: "\(session.client?.context.id.uuidString ?? ""):\(id):\(previewSize.rawValue):\(session.capabilities.supportsFavoritesAcrossSpaces)") {
            await loadCover()
        }
    }

    private var preview: some View {
        Color(.secondarySystemBackground)
            .frame(width: side, height: side)
            .overlay {
                if let deviceCover {
                    AssetTile(asset: deviceCover, targetPixelSize: side * displayScale, isGridTile: false)
                } else if let albumCoverID, let client = session.client {
                    RemoteImage(url: client.thumbnailURL(assetID: albumCoverID), targetPixelSize: 400)
                } else if let cover {
                    RemoteImage(url: cover.url, targetPixelSize: 400, thumbhash: cover.thumbhash)
                } else { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary) }
            }
            .overlay {
                if deviceCover != nil || albumCoverID != nil || cover != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.caption2) }
                }
                    .foregroundStyle(deviceCover == nil && albumCoverID == nil && cover == nil ? Color.primary : .white)
                    .padding(10)
            }
            .clipShape(.rect(cornerRadius: 18))
    }

    private func loadCover() async {
        guard previewSize != .none, albumCoverID == nil, deviceCover == nil, let client = session.client else { return }
        await covers.load(id, client: client, favoritesAcrossSpaces: session.capabilities.supportsFavoritesAcrossSpaces)
    }
}

private struct CollectionsMapPreview: View {
    @Environment(SessionStore.self) private var session
    @State private var camera: MapCameraPosition = .automatic
    @State private var clusters: [MapCluster] = []
    @State private var size: CGSize = .zero

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    MapAssetMarker(cluster: cluster, isOpening: false,
                                   thumbnailURL: session.client?.thumbnailURL(assetID: cluster.representative.id),
                                   action: {})
                }
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: size) {
            let viewportSize = size
            guard viewportSize.width > 0, viewportSize.height > 0,
                  let client = session.client,
                  let markers = try? await MapMarkerCache.shared.markers(client: client, options: MapMarkerOptions()),
                  !Task.isCancelled, session.client === client else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                MapClustering.preview(markers: markers, size: viewportSize)
            }.value
            guard !Task.isCancelled, session.client === client else { return }
            clusters = prepared?.clusters ?? []
            camera = prepared.map { .rect($0.bounds.mapRect) } ?? .automatic
        }
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
