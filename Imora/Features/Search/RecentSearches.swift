import Foundation
import Observation

nonisolated struct RecentSearch: Codable, Hashable, Identifiable {
    let text: String
    let type: SearchFilter.TextType

    var id: String { "\(type.rawValue):\(text.lowercased())" }
}

/// submitted queries, newest first. kept per account on this device only,
/// like the web keeps them per tab.
@MainActor
@Observable
final class RecentSearches {
    static let limit = 8
    nonisolated private static let keyPrefix = "imora.recentSearches."

    private(set) var items: [RecentSearch] = []
    @ObservationIgnored private var key: String?

    /// swaps to the given account's list, e.g. after signing in elsewhere.
    func load(account: String?) {
        let key = account.map { "\(Self.keyPrefix)\($0)" }
        guard key != self.key else { return }
        self.key = key
        guard let key,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentSearch].self, from: data)
        else {
            items = []
            return
        }
        items = decoded
    }

    func record(_ text: String, type: SearchFilter.TextType) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = RecentSearch(text: trimmed, type: type)
        items.removeAll { $0.id == entry.id }
        items.insert(entry, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ entry: RecentSearch) {
        items.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// sign-out forgets every account's history on this device.
    nonisolated static func eraseAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func save() {
        guard let key else { return }
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
