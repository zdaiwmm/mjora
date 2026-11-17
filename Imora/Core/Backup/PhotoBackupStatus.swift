import Foundation

/// One presentation state for grid glyphs and the open photo. Cached Asset flags
/// must not outrank the live index after a failure, edit, or remote removal.
enum PhotoBackupStatus: Equatable {
    case backedUp, notBackedUp, uploading(Double), failed, cloudDeleted, sizeExcluded

    static func resolve(asset: Asset, backup: BackupManager?) -> Self {
        guard let id = asset.localIdentifier else { return .backedUp }
        guard let backup else { return .notBackedUp }
        if backup.remoteRemovedLocalIDs.contains(id) { return .cloudDeleted }
        if let revision = backup.backedUpLocalRevisions[id],
           asset.localImageVersion == revision.map({ String($0.timeIntervalSinceReferenceDate.bitPattern) }),
           backup.hasVerifiedBackup(localIdentifier: id) { return .backedUp }
        if case .uploading(let progress) = backup.uploadStates[id] { return .uploading(progress) }
        if backup.uploadStates[id] == .failed || backup.backupFailures.contains(where: { $0.localIdentifier == id && $0.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } == asset.localImageVersion }) {
            return .failed
        }
        if backup.sizeExcludedLocalIdentifiers.contains(id) { return .sizeExcluded }
        return .notBackedUp
    }

    var symbol: String {
        switch self {
        case .backedUp: "checkmark.icloud"
        case .notBackedUp, .cloudDeleted: "icloud.slash"
        case .uploading: "icloud.and.arrow.up"
        case .failed: "exclamationmark.icloud"
        case .sizeExcluded: "minus.circle"
        }
    }
}
