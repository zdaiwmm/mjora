import Foundation

nonisolated enum BackupRemoteChange: Sendable { case deleted, trashed, restored, hidden }

nonisolated enum BackupVerificationState: String, Codable, Sendable {
    case pending, verifying, verified, missing, trashed, offline, pairPending, pairConflict, pairPermissionDenied, failed
}

/// Details describe the server's database. They do not prove that the original
/// file is readable or intact; local cleanup has a separate byte readback gate.
nonisolated struct BackupRemoteAsset: Decodable, Sendable, Equatable {
    var id: String
    var ownerId: String
    var type: String
    var checksum: String?
    var isTrashed: Bool?
    var isOffline: Bool?
    var livePhotoVideoId: String?
}

nonisolated protocol BackupRemoteAPI: Sendable {
    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset
    func repairLivePhoto(stillID: String, videoID: String) async throws
}

nonisolated struct BackupComponentProof: Codable, Equatable, Sendable {
    let remoteID: String
    let checksum: String
    let ownerID: String
    let type: String
}

nonisolated struct BackupProof: Codable, Equatable, Sendable {
    let account: String
    let generation: UUID
    let localRevision: DeviceAsset
    let primary: BackupComponentProof
    let motion: BackupComponentProof?
    let livePhotoVideoID: String?
    let verifiedAt: Date

    func matches(_ entry: BackupEntry) -> Bool {
        guard localRevision.modificationDate == entry.modificationDate,
              localRevision.isLivePhoto == entry.isLivePhoto,
              !primary.remoteID.isEmpty, !primary.checksum.isEmpty, !primary.ownerID.isEmpty,
              primary.type == (localRevision.isVideo && !localRevision.isLivePhoto ? "VIDEO" : "IMAGE"),
              primary.remoteID == entry.primaryRemoteId, primary.checksum == entry.primaryChecksum else { return false }
        guard entry.isLivePhoto else { return true }
        guard let motion, let expectedID = entry.motionRemoteId, let expectedChecksum = entry.motionChecksum,
              !expectedID.isEmpty, !expectedChecksum.isEmpty else { return false }
        return motion.remoteID == expectedID && motion.checksum == expectedChecksum
            && motion.ownerID == primary.ownerID && motion.type == "VIDEO" && livePhotoVideoID == expectedID
    }
}

nonisolated enum BackupVerificationError: Error, LocalizedError {
    case invalidResponse
    case stale
    case component(String, BackupVerificationState)
    case mismatch

    var state: BackupVerificationState {
        switch self {
        case .component(_, let state): state
        default: .failed
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "The server returned an incomplete or ambiguous backup check.")
        case .stale: String(localized: "The account or local photo changed during verification. Try again.")
        case .mismatch: String(localized: "The server copy does not match this photo's owner, type, or checksum.")
        case .component(_, let state):
            switch state {
            case .missing: String(localized: "A required server copy is missing.")
            case .trashed: String(localized: "The server copy is in the trash. Resolve it on the server before continuing.")
            case .offline: String(localized: "The server original is offline or its availability is unknown.")
            case .pairPending: String(localized: "The Live Photo components are waiting to be paired.")
            case .pairConflict: String(localized: "The Live Photo is linked to a different video. The existing link was kept.")
            case .pairPermissionDenied: String(localized: "The account cannot repair this Live Photo link. Check asset update permissions.")
            default: String(localized: "The server copy could not be verified.")
            }
        }
    }
}

nonisolated enum BackupVerifier {
    static func validatedResults(items: [BulkUploadCheckItem], results: [BulkUploadCheckResult]) throws -> [String: BulkUploadCheckResult] {
        let expected = Set(items.map(\.id))
        guard expected.count == items.count, results.count == items.count else { throw BackupVerificationError.invalidResponse }
        var rows: [String: BulkUploadCheckResult] = [:]
        for row in results {
            guard expected.contains(row.id), rows[row.id] == nil,
                  (row.action == "accept" && row.assetId == nil)
                    || (row.isConfirmedDuplicate && row.assetId?.isEmpty == false) || row.isUnsupported
            else { throw BackupVerificationError.invalidResponse }
            rows[row.id] = row
        }
        guard rows.count == expected.count else { throw BackupVerificationError.invalidResponse }
        return rows
    }

    static func checkCurrent(_ current: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await current() else { throw BackupVerificationError.stale }
        try Task.checkCancellation()
    }

    static func validate(_ remote: BackupRemoteAsset, id: String, checksum: String, type: String, ownerID: String) throws -> BackupComponentProof {
        guard remote.id == id, remote.ownerId == ownerID, remote.type == type, remote.checksum == checksum else { throw BackupVerificationError.mismatch }
        guard remote.isTrashed == false else { throw BackupVerificationError.component(id, .trashed) }
        guard remote.isOffline == false else { throw BackupVerificationError.component(id, .offline) }
        return BackupComponentProof(remoteID: id, checksum: checksum, ownerID: ownerID, type: type)
    }

    static func verify(asset: DeviceAsset, entry: BackupEntry, ownerID: String, account: String, generation: UUID,
                       remote: any BackupRemoteAPI, repairEmptyPair: Bool = false,
                       wait: @escaping @Sendable (Int) async throws -> Void = { attempt in
                           try await Task.sleep(for: .milliseconds((attempt + 1) * 250))
                       }, current: @escaping @Sendable () async -> Bool) async throws -> BackupProof {
        try await checkCurrent(current)
        guard entry.matches(modificationDate: asset.modificationDate), entry.isLivePhoto == asset.isLivePhoto,
              let primaryID = entry.primaryRemoteId else { throw BackupVerificationError.stale }
        var primaryRemote: BackupRemoteAsset
        do { primaryRemote = try await remote.backupAssetDetail(id: primaryID) }
        catch ImoraError.http(404, _) { throw BackupVerificationError.component(primaryID, .missing) }
        try await checkCurrent(current)
        var primary = try validate(primaryRemote, id: primaryID, checksum: entry.primaryChecksum,
                                   type: asset.isVideo && !asset.isLivePhoto ? "VIDEO" : "IMAGE", ownerID: ownerID)
        var motion: BackupComponentProof?
        if entry.isLivePhoto {
            guard let id = entry.motionRemoteId, let checksum = entry.motionChecksum else { throw BackupVerificationError.component(primaryID, .pairPending) }
            let video: BackupRemoteAsset
            do { video = try await remote.backupAssetDetail(id: id) }
            catch ImoraError.http(404, _) { throw BackupVerificationError.component(id, .missing) }
            try await checkCurrent(current)
            motion = try validate(video, id: id, checksum: checksum, type: "VIDEO", ownerID: ownerID)
            if let linked = primaryRemote.livePhotoVideoId, linked != id {
                throw BackupVerificationError.component(primaryID, .pairConflict)
            }
            if primaryRemote.livePhotoVideoId == nil, repairEmptyPair {
                // Give Immich's metadata worker a finite chance to pair by Apple
                // content ID before repairing only an observed empty link.
                for attempt in 0..<3 {
                    try await wait(attempt)
                    try await checkCurrent(current)
                    primaryRemote = try await remote.backupAssetDetail(id: primaryID)
                    try await checkCurrent(current)
                    primary = try validate(primaryRemote, id: primaryID, checksum: entry.primaryChecksum, type: "IMAGE", ownerID: ownerID)
                    if let linked = primaryRemote.livePhotoVideoId {
                        guard linked == id else { throw BackupVerificationError.component(primaryID, .pairConflict) }
                        break
                    }
                }
                // Revalidate the video after waiting, then re-read the still
                // immediately before the possible write. This avoids overwriting
                // observed conflicts, but 3.4.1 has no atomic conditional update.
                let refreshedVideo = try await remote.backupAssetDetail(id: id)
                try await checkCurrent(current)
                motion = try validate(refreshedVideo, id: id, checksum: checksum, type: "VIDEO", ownerID: ownerID)
                primaryRemote = try await remote.backupAssetDetail(id: primaryID)
                try await checkCurrent(current)
                primary = try validate(primaryRemote, id: primaryID, checksum: entry.primaryChecksum, type: "IMAGE", ownerID: ownerID)
                if let linked = primaryRemote.livePhotoVideoId {
                    guard linked == id else { throw BackupVerificationError.component(primaryID, .pairConflict) }
                } else {
                    do { try await remote.repairLivePhoto(stillID: primaryID, videoID: id) }
                    catch ImoraError.http(401, _), ImoraError.http(403, _) {
                        throw BackupVerificationError.component(primaryID, .pairPermissionDenied)
                    }
                    try await checkCurrent(current)
                    primaryRemote = try await remote.backupAssetDetail(id: primaryID)
                    try await checkCurrent(current)
                    primary = try validate(primaryRemote, id: primaryID, checksum: entry.primaryChecksum, type: "IMAGE", ownerID: ownerID)
                    let finalVideo = try await remote.backupAssetDetail(id: id)
                    try await checkCurrent(current)
                    motion = try validate(finalVideo, id: id, checksum: checksum, type: "VIDEO", ownerID: ownerID)
                }
            }
            guard primaryRemote.livePhotoVideoId == id else {
                throw BackupVerificationError.component(primaryID, primaryRemote.livePhotoVideoId == nil ? .pairPending : .pairConflict)
            }
        }
        try await checkCurrent(current)
        return BackupProof(account: account, generation: generation, localRevision: asset, primary: primary,
                           motion: motion, livePhotoVideoID: entry.isLivePhoto ? primaryRemote.livePhotoVideoId : nil, verifiedAt: Date())
    }
}

extension ImoraClient: BackupRemoteAPI {}
