import Foundation

nonisolated struct FavoriteIntent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let account: String
    let remoteID: String
    let localID: String?
    let value: Bool
    let createdAt: Date
}

/// Last desired value, persisted before acknowledging pending cloud work.
/// A stale network acknowledgement cannot delete a more recent user intent.
@MainActor
final class FavoriteIntentStore {
    static let shared = FavoriteIntentStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appending(path: "imora/favorite-intents.json"))

    enum Failure: Error { case invalidIdentity, unreadableStore }
    private let url: URL
    private var intents: [FavoriteIntent]
    private let unreadable: Bool

    init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { intents = try JSONDecoder().decode([FavoriteIntent].self, from: Data(contentsOf: url)); unreadable = false }
            catch { intents = []; unreadable = true }
        } else { intents = []; unreadable = false }
    }

    func pending(account: String) -> [FavoriteIntent] {
        intents.filter { $0.account == account }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func record(account: String, remoteID: String, localID: String?, value: Bool) throws -> FavoriteIntent {
        guard !account.isEmpty, !remoteID.isEmpty else { throw Failure.invalidIdentity }
        guard !unreadable else { throw Failure.unreadableStore }
        let previous = intents
        let intent = FavoriteIntent(id: UUID(), account: account, remoteID: remoteID,
            localID: localID, value: value, createdAt: Date())
        intents.removeAll { $0.account == account && $0.remoteID == remoteID }
        intents.append(intent)
        do { try persist() } catch { intents = previous; throw error }
        return intent
    }

    func acknowledge(_ intent: FavoriteIntent) throws {
        guard intents.contains(where: { $0.id == intent.id }) else { return }
        let previous = intents
        intents.removeAll { $0.id == intent.id }
        do { try persist() } catch { intents = previous; throw error }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(intents).write(to: url, options: .atomic)
    }
}
