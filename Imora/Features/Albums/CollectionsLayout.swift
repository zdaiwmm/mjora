import Foundation

nonisolated enum CollectionSection: String, CaseIterable, Codable, Identifiable {
    case memories, pinned, albums, people, places, media, utilities, more, spaces

    var id: String { rawValue }
    var title: String {
        switch self {
        case .memories: String(localized: "Memories")
        case .pinned: String(localized: "Pinned Collections")
        case .albums: String(localized: "My Albums")
        case .people: String(localized: "People & Pets")
        case .places: String(localized: "Places")
        case .media: String(localized: "Media Types")
        case .utilities: String(localized: "Utilities")
        case .more: String(localized: "More Items")
        case .spaces: String(localized: "Shared Spaces")
        }
    }
}

nonisolated struct CollectionsAvailability {
    var people = true
    var trash = true
    var duplicates = true
    var cleanup = true

    func allows(_ id: String) -> Bool {
        switch id {
        case "people": people
        case "trash": trash
        case "duplicates": duplicates
        case "cleanup": cleanup
        default: true
        }
    }
}

extension SessionStore {
    var collectionsAvailability: CollectionsAvailability {
        CollectionsAvailability(people: preferences?.peopleEnabled != false,
            trash: features?.trash != false, duplicates: features?.duplicateDetection != false,
            cleanup: capabilities.supportsCleanup)
    }
}

nonisolated enum CollectionPreviewSize: String, CaseIterable, Codable, Identifiable {
    case large, small, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .large: String(localized: "Large")
        case .small: String(localized: "Small")
        case .none: String(localized: "None")
        }
    }
}

/// Presentation preferences only; server content and permissions remain authoritative.
nonisolated struct CollectionsLayout: Codable, Equatable {
    var sectionIDs = CollectionSection.allCases.map(\.rawValue)
    var collapsedIDs: [String] = []
    var pinnedIDs = ["favorites", "recent", "places"]
    var previewSize: CollectionPreviewSize = .large

    var sections: [CollectionSection] { sectionIDs.compactMap(CollectionSection.init(rawValue:)) }
    var collapsed: Set<CollectionSection> { Set(collapsedIDs.compactMap(CollectionSection.init(rawValue:))) }

    init() {}

    private enum CodingKeys: String, CodingKey { case sectionIDs, collapsedIDs, pinnedIDs, previewSize }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewSize = (try? c.decode(CollectionPreviewSize.self, forKey: .previewSize)) ?? .large
        sectionIDs = try c.decodeIfPresent([String].self, forKey: .sectionIDs) ?? sectionIDs
        collapsedIDs = try c.decodeIfPresent([String].self, forKey: .collapsedIDs) ?? []
        pinnedIDs = try c.decodeIfPresent([String].self, forKey: .pinnedIDs) ?? pinnedIDs
        var seen = Set<String>()
        sectionIDs = (sectionIDs + CollectionSection.allCases.map(\.rawValue)).filter {
            CollectionSection(rawValue: $0) != nil && seen.insert($0).inserted
        }
        collapsedIDs = Array(Set(collapsedIDs.filter { CollectionSection(rawValue: $0) != nil })).sorted()
        seen = []
        pinnedIDs = pinnedIDs.filter { Self.isValidPin($0) && seen.insert($0).inserted }
    }

    static func decode(_ data: Data?) -> Self {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    mutating func togglePin(_ id: String) {
        guard Self.isValidPin(id) else { return }
        if pinnedIDs.contains(id) { pinnedIDs.removeAll { $0 == id } }
        else { pinnedIDs.append(id) }
    }

    mutating func toggleCollapsed(_ section: CollectionSection) {
        if collapsedIDs.contains(section.rawValue) { collapsedIDs.removeAll { $0 == section.rawValue } }
        else { collapsedIDs.append(section.rawValue) }
    }

    mutating func moveSections(from offsets: IndexSet, to destination: Int) {
        let valid = offsets.filter { sectionIDs.indices.contains($0) }
        let moving = valid.map { sectionIDs[$0] }
        let remaining = sectionIDs.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertion = max(0, min(remaining.count, destination - valid.filter { $0 < destination }.count))
        sectionIDs = Array(remaining.prefix(insertion)) + moving + Array(remaining.dropFirst(insertion))
    }

    mutating func removeAlbum(_ id: String) { pinnedIDs.removeAll { $0 == "album:\(id)" } }

    private static func isValidPin(_ id: String) -> Bool {
        ["favorites", "recent", "places", "people", "archive", "locked", "trash", "duplicates", "largeFiles", "cleanup"].contains(id)
            || (id.hasPrefix("album:") && id.count > "album:".count)
    }
}

@MainActor
final class CollectionsLayoutStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(account: String?) -> CollectionsLayout {
        guard let account else { return CollectionsLayout() }
        return CollectionsLayout.decode(defaults.data(forKey: "imora.collections.v1.\(account)"))
    }

    func save(_ layout: CollectionsLayout, account: String?) {
        guard let account, let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: "imora.collections.v1.\(account)")
    }
}
