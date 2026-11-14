import Foundation

nonisolated protocol ExplicitRebackupRemoteAPI: BackupRemoteAPI {
    func restoreAssets(ids: [String]) async throws
}

extension ImoraClient: ExplicitRebackupRemoteAPI {}

/// Explicit consent covers restoring this owned pairing or replacing permanent absence.
/// A partial or foreign pairing never authorizes a restore or retirement.
nonisolated enum ExplicitRebackupRecovery {
    static func restoreIfPresent(entry: BackupEntry, ownerID: String,
                                 remote: any ExplicitRebackupRemoteAPI,
                                 current: @escaping @Sendable () async -> Bool) async throws -> Bool {
        try await BackupVerifier.checkCurrent(current)
        guard let primaryID = entry.primaryRemoteId else {
            guard entry.motionRemoteId == nil else { throw BackupVerificationError.component("pair", .pairPending) }
            return false
        }
        var expected: [(id: String, checksum: String, type: String?)] = [(primaryID, entry.primaryChecksum, entry.isLivePhoto ? "IMAGE" : nil)]
        if entry.isLivePhoto {
            guard let motionID = entry.motionRemoteId, let checksum = entry.motionChecksum else {
                throw BackupVerificationError.component(primaryID, .pairPending)
            }
            expected.append((motionID, checksum, "VIDEO"))
        }
        var found: [BackupRemoteAsset] = []
        for component in expected {
            do { found.append(try await remote.backupAssetDetail(id: component.id)) }
            catch ImoraError.http(404, _) { }
            try await BackupVerifier.checkCurrent(current)
        }
        if found.isEmpty { return false }
        guard found.count == expected.count else { throw BackupVerificationError.component(primaryID, .pairPending) }
        for (value, component) in zip(found, expected) {
            guard value.id == component.id, value.ownerId == ownerID, value.checksum == component.checksum,
                  component.type.map({ value.type == $0 }) ?? (value.type == "IMAGE" || value.type == "VIDEO"),
                  value.isTrashed != nil, value.isOffline == false else { throw BackupVerificationError.mismatch }
        }
        if entry.isLivePhoto, found[0].livePhotoVideoId != entry.motionRemoteId {
            throw BackupVerificationError.component(primaryID, .pairConflict)
        }
        let trashed = found.filter { $0.isTrashed == true }.map(\.id)
        if !trashed.isEmpty {
            try await BackupVerifier.checkCurrent(current)
            try await remote.restoreAssets(ids: trashed)
            try await BackupVerifier.checkCurrent(current)
        }
        for (previous, component) in zip(found, expected) {
            let value = try await remote.backupAssetDetail(id: component.id)
            try await BackupVerifier.checkCurrent(current)
            _ = try BackupVerifier.validate(value, id: component.id, checksum: component.checksum,
                                           type: previous.type, ownerID: ownerID)
            if component.id == primaryID, entry.isLivePhoto, value.livePhotoVideoId != entry.motionRemoteId {
                throw BackupVerificationError.component(primaryID, .pairConflict)
            }
        }
        return true
    }
}


nonisolated struct RebackupConfirmation: Identifiable, Equatable, Sendable {
    let localIdentifier: String
    let accountGeneration: UUID
    var id: String { accountGeneration.uuidString + ":" + localIdentifier }
}
