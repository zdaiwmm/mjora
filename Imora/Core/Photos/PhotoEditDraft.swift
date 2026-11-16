import Foundation

/// Parameters only. No image, credential, PIN lease or cleanup evidence is stored.
nonisolated struct PhotoEditDraft: Codable, Equatable, Sendable {
    struct Binding: Codable, Equatable, Sendable {
        let scope: StableMediaScope
        let subject: String
        let sourceRevision: String
        let width: Int
        let height: Int
        let mode: String
    }

    struct Version: Codable, Equatable, Sendable {
        let edits: [AssetEdit]
        let adjust: ImageAdjust?
        var localModification: Date? = nil
    }

    struct Submission: Codable, Equatable, Sendable {
        let edits: [AssetEdit]?
        let adjust: ImageAdjust?
        let snapshot: EditSnapshot
    }

    let version: Int
    let id: UUID
    let binding: Binding
    var baseline: Version
    var snapshot: EditSnapshot
    /// Written before external I/O; survives both a lost reply and process death.
    var submission: Submission?

    init(binding: Binding, baseline: Version, snapshot: EditSnapshot) {
        version = 1; id = UUID(); self.binding = binding
        self.baseline = baseline; self.snapshot = snapshot
    }

    enum Recovery { case saved, editing(PhotoEditDraft), retry(PhotoEditDraft) }
    enum RecoveryError: LocalizedError {
        case changed, invalid
        var errorDescription: String? {
            switch self {
            case .changed: String(localized: "This photo or its edits changed. Your saved draft was kept, but can't be applied to this version.")
            case .invalid: String(localized: "The saved draft couldn't be read. It has been kept. You can try again or discard it.")
            }
        }
    }

    /// Read-only reconciliation. Only a complete authoritative match confirms a
    /// pending save; legacy mixtures of old/new components remain retryable.
    func recover(binding currentBinding: Binding, current: Version) throws -> Recovery {
        guard version == 1, binding == currentBinding, !binding.sourceRevision.isEmpty,
              binding.scope.accountID != nil else { throw RecoveryError.changed }
        guard let submission else {
            guard baseline == current else { throw RecoveryError.changed }
            return .editing(self)
        }
        let expectedEdits = submission.edits ?? baseline.edits
        let expectedAdjust = submission.adjust ?? baseline.adjust
        if current.edits == expectedEdits, current.adjust == expectedAdjust {
            if snapshot == submission.snapshot { return .saved }
            var next = self
            next.baseline = current; next.submission = nil
            return .editing(next)
        }
        guard current.localModification == baseline.localModification,
              current.edits == baseline.edits || current.edits == expectedEdits,
              current.adjust == baseline.adjust || current.adjust == expectedAdjust
        else { throw RecoveryError.changed }
        return .retry(self)
    }
}

/// Main-actor callers serialize the small atomic metadata writes. Drafts are
/// durable application support, excluded from backup and protected while locked.
struct PhotoEditDraftStore {
    static let shared = Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "PhotoEditDraftsV1", directoryHint: .isDirectory))
    let root: URL

    private func file(scope: StableMediaScope, subject: String) throws -> URL {
        guard scope.accountID != nil else { throw PhotoEditDraft.RecoveryError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode(scope) + Data(subject.utf8)
        return root.appending(path: MediaDisplayKeyV1.digest(key) + ".json")
    }

    func load(scope: StableMediaScope, subject: String) throws -> PhotoEditDraft? {
        let url = try file(scope: scope, subject: subject)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft: PhotoEditDraft
        do { draft = try JSONDecoder().decode(PhotoEditDraft.self, from: Data(contentsOf: url)) }
        catch { throw PhotoEditDraft.RecoveryError.invalid }
        guard draft.version == 1, draft.binding.scope == scope, draft.binding.subject == subject else {
            throw PhotoEditDraft.RecoveryError.invalid
        }
        return draft
    }

    func write(_ draft: PhotoEditDraft) throws {
        let url = try file(scope: draft.binding.scope, subject: draft.binding.subject)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(scope: StableMediaScope, subject: String) throws {
        let url = try file(scope: scope, subject: subject)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
