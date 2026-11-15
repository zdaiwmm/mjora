import Foundation

/// One picker session's verified local→cloud resolutions. Construction and
/// album browsing perform no backup. Explicit account-bound consent is needed
/// before the first local operation; successful resolutions survive retries.
@MainActor
final class AlbumBackupPreparation {
    nonisolated enum Failure: LocalizedError, Equatable {
        case confirmationRequired, accountChanged, unverifiedBackup, emptySelection
        var errorDescription: String? {
            switch self {
            case .confirmationRequired: String(localized: "Confirm Back Up and Add to Album before backing up device items.")
            case .accountChanged: String(localized: "Your account changed. Reopen Add to Album to continue.")
            case .unverifiedBackup: String(localized: "A selected item's backup could not be verified. Your selection and completed backups are kept. Try again.")
            case .emptySelection: String(localized: "Select at least one item to add to an App album.")
            }
        }
    }

    let localIdentifiers: [String]
    let accountGeneration: UUID
    private(set) var resolvedRemoteIDs: [String: String] = [:]

    init(localIdentifiers: [String], accountGeneration: UUID) {
        var seen: Set<String> = []
        self.localIdentifiers = localIdentifiers.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.accountGeneration = accountGeneration
    }

    func perform<Result>(assetIDs: [String], consent: UUID?, isCurrent: () -> Bool,
        backup: (String) async throws -> String, verify: (String, String) async throws -> Bool,
        progress: (Int, Int) -> Void = { _, _ in }, operation: ([String]) async throws -> Result) async throws -> Result {
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw Failure.accountChanged }
        }
        try check()
        guard localIdentifiers.isEmpty || consent == accountGeneration else { throw Failure.confirmationRequired }
        progress(resolvedRemoteIDs.count, localIdentifiers.count)
        for id in localIdentifiers {
            try check()
            if let existing = resolvedRemoteIDs[id] {
                let valid = try await verify(id, existing)
                try check()
                if valid { continue }
                resolvedRemoteIDs.removeValue(forKey: id)
                progress(resolvedRemoteIDs.count, localIdentifiers.count)
            }
            let remote = try await backup(id)
            try check()
            guard !remote.isEmpty else { throw Failure.unverifiedBackup }
            let valid = try await verify(id, remote)
            try check()
            guard valid else { throw Failure.unverifiedBackup }
            resolvedRemoteIDs[id] = remote
            progress(resolvedRemoteIDs.count, localIdentifiers.count)
        }
        // Earlier items may have changed while a later item uploaded. Verify
        // the entire selected set again at the album-mutation boundary.
        for id in localIdentifiers {
            guard let remote = resolvedRemoteIDs[id] else { throw Failure.unverifiedBackup }
            let valid = try await verify(id, remote)
            try check()
            guard valid else {
                resolvedRemoteIDs.removeValue(forKey: id)
                progress(resolvedRemoteIDs.count, localIdentifiers.count)
                throw Failure.unverifiedBackup
            }
        }
        try check()
        var seen: Set<String> = []
        let ids = (assetIDs + localIdentifiers.compactMap { resolvedRemoteIDs[$0] })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else { throw Failure.emptySelection }
        let result = try await operation(ids)
        try check()
        return result
    }
}
