import Foundation

/// An operator override is captured once per manager/login lifetime. Changing
/// preferences cannot change authority halfway through an active upload.
nonisolated struct BackupSyncConfiguration: Sendable {
    static let incrementalEnabledKey = "imora.backup.incrementalSyncEnabled"
    let incrementalEnabled: Bool

    init(incrementalSyncEnabled: Bool? = nil, defaults: UserDefaults = .standard) {
        incrementalEnabled = incrementalSyncEnabled ?? (defaults.object(forKey: Self.incrementalEnabledKey) == nil
            ? true : defaults.bool(forKey: Self.incrementalEnabledKey))
    }

    func requireIncremental() throws {
        guard incrementalEnabled else { throw RemoteSyncError.compatibilityRequired }
    }
}
