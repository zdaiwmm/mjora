import Foundation

/// only a short, user-facing category is persisted. server responses and
/// request URLs can contain information that should not go into preferences.
nonisolated enum RepeatedBackupFailureKind: String, Codable, Sendable {
    case uploadLimit
    case serverSizeLimit
    case connection
    case authorization
    case other

    init(error: any Error) {
        switch error {
        case is UploadSizeLimit: self = .uploadLimit
        case ImoraError.http(413, _): self = .serverSizeLimit
        case ImoraError.http(401, _), ImoraError.http(403, _): self = .authorization
        case BackupVerificationError.component(_, .pairPermissionDenied): self = .authorization
        case is URLError: self = .connection
        case ImoraError.unreachable: self = .connection
        default: self = .other
        }
    }

    var explanation: String {
        switch self {
        case .uploadLimit: String(localized: "This file exceeds the limit in Backup Settings.")
        case .serverSizeLimit: String(localized: "The server or proxy rejected this file as too large (HTTP 413).")
        case .connection: String(localized: "The connection failed during backup.")
        case .authorization: String(localized: "The server rejected the backup. Check your account.")
        case .other: String(localized: "Imora could not complete this backup.")
        }
    }
}

nonisolated struct RepeatedBackupFailure: Codable, Equatable, Identifiable, Sendable {
    let account: String
    let localIdentifier: String
    let modificationDate: Date?
    let isVideo: Bool
    var capturedAt: Date?
    var count: Int
    var kind: RepeatedBackupFailureKind
    var lastFailedAt: Date

    var id: String { "\(account)\u{1F}\(localIdentifier)" }
}

/// counts consecutive failures for one asset revision and account. a successful
/// verified backup, an edit, or removal of the asset clears the old count.
nonisolated struct RepeatedBackupFailures: Codable, Sendable {
    static let bannerThreshold = 5
    private static let storageKey = "imora.repeatedBackupFailures"
    private static let maximumEntries = 250

    private(set) var entries: [RepeatedBackupFailure] = []

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    @discardableResult mutating func recordFailure(
        account: String,
        localIdentifier: String,
        modificationDate: Date?,
        isVideo: Bool,
        kind: RepeatedBackupFailureKind,
        capturedAt: Date? = nil,
        at date: Date = Date()
    ) -> Bool {
        if let index = entries.firstIndex(where: {
            $0.account == account && $0.localIdentifier == localIdentifier
        }) {
            if entries[index].modificationDate == modificationDate {
                entries[index].count = min(999, entries[index].count + 1)
                entries[index].kind = kind
                entries[index].lastFailedAt = date
                if entries[index].capturedAt == nil { entries[index].capturedAt = capturedAt }
                return true
            }
            entries.remove(at: index)
        }
        // keep already tracked items through a large outage: evicting them
        // for new first failures would prevent any asset reaching six. an
        // account switch may replace an older account's entry, though.
        if entries.count >= Self.maximumEntries,
           let otherAccount = entries.firstIndex(where: { $0.account != account }) {
            entries.remove(at: otherAccount)
        }
        guard entries.count < Self.maximumEntries else { return false }
        entries.append(RepeatedBackupFailure(
            account: account,
            localIdentifier: localIdentifier,
            modificationDate: modificationDate,
            isVideo: isVideo,
            capturedAt: capturedAt,
            count: 1,
            kind: kind,
            lastFailedAt: date
        ))
        return true
    }

    mutating func clear(account: String, localIdentifier: String) {
        entries.removeAll { $0.account == account && $0.localIdentifier == localIdentifier }
    }

    /// size exclusions now have their own state in the backup index and are
    /// intentionally absent from the repeated transient-failure banner.
    @discardableResult mutating func removeLegacySizeLimitFailures() -> Bool {
        let before = entries.count
        entries.removeAll { $0.kind == .uploadLimit }
        return entries.count != before
    }

    mutating func clearBackedUp(account: String, revisions: [String: Date?]) {
        guard !revisions.isEmpty else { return }
        entries.removeAll {
            $0.account == account
                && revisions[$0.localIdentifier] == .some($0.modificationDate)
        }
    }

    mutating func reconcile(account: String, currentRevisions: [String: Date?]) {
        entries.removeAll { entry in
            entry.account == account
                && currentRevisions[entry.localIdentifier] != .some(entry.modificationDate)
        }
    }

    func needingAttention(account: String) -> [RepeatedBackupFailure] {
        entries.filter { $0.account == account && $0.count > Self.bannerThreshold }
            .sorted {
                $0.count == $1.count ? $0.lastFailedAt > $1.lastFailedAt : $0.count > $1.count
            }
    }
}
