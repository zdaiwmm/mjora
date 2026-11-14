import Foundation

/// only unfinished whole-library requests are restored. a one-run cellular
/// approval is deliberately never persisted. atomic writes happen before work.
@MainActor
final class BackupIntentStore {
    static let shared = BackupIntentStore()
    private struct StoredIntents: Codable {
        var pendingAccounts: Set<String> = []
        var requiresExplicitResumeAccounts: Set<String> = []
    }

    private let url: URL
    private var intents = StoredIntents()
    private var loaded = false

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/backup-intents.json")) {
        self.url = url
    }

    private func load() -> Bool {
        if loaded { return true }
        do {
            let data = try Data(contentsOf: url)
            if let stored = try? JSONDecoder().decode(StoredIntents.self, from: data) {
                intents = stored
                intents.pendingAccounts.formUnion(stored.requiresExplicitResumeAccounts)
            } else {
                // Previous versions stored only unfinished accounts.
                intents.pendingAccounts = try JSONDecoder().decode(Set<String>.self, from: data)
            }
        } catch CocoaError.fileReadNoSuchFile {
            intents = StoredIntents()
        } catch { return false }
        loaded = true
        return true
    }

    func contains(_ account: String) -> Bool {
        load() && intents.pendingAccounts.contains(account)
    }

    func requiresExplicitResume(_ account: String) -> Bool {
        // An unreadable journal must not silently authorize uploads.
        !load() || intents.requiresExplicitResumeAccounts.contains(account)
    }

    func canResumeAutomatically(_ account: String, autoBackup: Bool) -> Bool {
        load() && !intents.requiresExplicitResumeAccounts.contains(account)
            && (autoBackup || intents.pendingAccounts.contains(account))
    }

    @discardableResult
    func set(_ pending: Bool, account: String) -> Bool {
        guard load() else { return false }
        var next = intents
        if pending {
            next.pendingAccounts.insert(account)
        } else {
            next.pendingAccounts.remove(account)
            next.requiresExplicitResumeAccounts.remove(account)
        }
        return save(next)
    }

    /// Continued-task expiration does not distinguish a system stop from the
    /// person's Cancel button. Keep the request, but require another action.
    @discardableResult
    func pause(account: String) -> Bool {
        guard load() else { return false }
        var next = intents
        next.pendingAccounts.insert(account)
        next.requiresExplicitResumeAccounts.insert(account)
        return save(next)
    }

    @discardableResult
    func resume(account: String) -> Bool {
        guard load() else { return false }
        var next = intents
        next.pendingAccounts.insert(account)
        next.requiresExplicitResumeAccounts.remove(account)
        return save(next)
    }

    /// Completion is weaker than an explicit Cancel. An expired worker that
    /// finishes an index write must never erase a later pause barrier.
    @discardableResult
    func complete(account: String) -> Bool {
        guard load(), !intents.requiresExplicitResumeAccounts.contains(account) else { return false }
        var next = intents
        next.pendingAccounts.remove(account)
        return save(next)
    }

    private func save(_ next: StoredIntents) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            intents = next
            return true
        } catch { return false }
    }
}
