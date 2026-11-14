import Foundation

nonisolated struct CleanupCandidate: Equatable, Sendable {
    let source: BackupEntry
    let proof: BackupProof
    var asset: DeviceAsset { proof.localRevision }
}

/// An immutable confirmation scope. Expiry limits when confirmation may start;
/// the running operation continually obtains fresh evidence, even for long videos.
nonisolated struct CleanupReport: Equatable, Sendable {
    let id = UUID()
    let account: String
    let generation: UUID
    let candidates: [CleanupCandidate]
    let keptMedia: MediaCounts
    let route: URL
    let createdAt: Date
    let expiresAt: Date
    let retention: CleanupRetentionSnapshot?
    let retainedReasons: [CleanupRetentionReason: MediaCounts]

    init(account: String, generation: UUID, candidates: [CleanupCandidate], keptMedia: MediaCounts,
         route: URL, createdAt: Date = Date(), expiresAt: Date? = nil,
         retention: CleanupRetentionSnapshot? = nil, retainedReasons: [CleanupRetentionReason: MediaCounts] = [:]) {
        self.account = account; self.generation = generation; self.candidates = candidates
        self.keptMedia = keptMedia; self.route = route; self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(600)
        self.retention = retention
        self.retainedReasons = retainedReasons
    }
    var eligible: [String] { candidates.map { $0.asset.localIdentifier } }
    var eligibleMedia: MediaCounts { MediaCounts(assets: candidates.map(\.asset)) }
    var keptLocalOnly: Int { keptMedia.total }
    var estimatedOriginalBytes: Int64? {
        var total: Int64 = 0
        for candidate in candidates {
            guard let primary = candidate.source.primaryByteCount, primary > 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(primary)
            guard !overflow else { return nil }; total = next
            if candidate.asset.isLivePhoto {
                guard let motion = candidate.source.motionByteCount, motion > 0 else { return nil }
                let (next, overflow) = total.addingReportingOverflow(motion)
                guard !overflow else { return nil }; total = next
            }
        }
        return total
    }
}

nonisolated struct CleanupOutcome: Sendable {
    let deletedIDs: [String]
    let deletedMedia: MediaCounts
    let keptMedia: MediaCounts
    var count: Int { deletedIDs.count }
}

nonisolated enum CleanupVerificationError: Error, LocalizedError {
    case changed, expired, permission, invalidReport
    var errorDescription: String? {
        switch self {
        case .changed: String(localized: "The account, server route, photo selection, or backup evidence changed. Scan again and confirm the new report.")
        case .expired: String(localized: "This cleanup report expired. Scan again before removing device copies.")
        case .permission: String(localized: "Full photo library access is required to remove verified device copies.")
        case .invalidReport: String(localized: "This cleanup report is incomplete. No device copies were removed.")
        }
    }
}

nonisolated protocol CleanupPhotoLibrary: Sendable {
    func hasFullAccess() async -> Bool
    func assets(ids: [String]) async throws -> [DeviceAsset]
    func hashes(for asset: DeviceAsset) async throws -> LocalResourceHashes
    func delete(_ assets: [DeviceAsset], permitted: @escaping @Sendable () -> Bool) async throws -> [String]
    func protectedAlbumMemberIDs(_ albumIDs: Set<String>) async throws -> Set<String>
    func delete(_ assets: [DeviceAsset], retention: CleanupRetentionSnapshot?, permitted: @escaping @Sendable () -> Bool) async throws -> [String]
}

nonisolated extension CleanupPhotoLibrary {
    func protectedAlbumMemberIDs(_ albumIDs: Set<String>) async throws -> Set<String> {
        guard albumIDs.isEmpty else { throw CleanupVerificationError.changed }
        return []
    }
    func delete(_ assets: [DeviceAsset], retention: CleanupRetentionSnapshot?, permitted: @escaping @Sendable () -> Bool) async throws -> [String] {
        try await delete(assets, permitted: permitted)
    }
}

nonisolated protocol CleanupRemoteAPI: BackupRemoteAPI {
    func bulkUploadCheck(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult]
    func readbackOriginal(assetID: String, expected: ResourceDigest) async throws -> ResourceDigest
}

nonisolated enum CleanupVerifier {
    private static func check(library: any CleanupPhotoLibrary, isCurrent: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CleanupVerificationError.changed }
        guard await library.hasFullAccess() else { throw CleanupVerificationError.permission }
        try Task.checkCancellation()
        guard await isCurrent() else { throw CleanupVerificationError.changed }
    }

    private static func validateLocal(_ expected: [DeviceAsset], library: any CleanupPhotoLibrary,
                                      retention: CleanupRetentionSnapshot? = nil,
                                      isCurrent: @Sendable () async -> Bool) async throws {
        let actual = try await library.assets(ids: expected.map(\.localIdentifier))
        try await check(library: library, isCurrent: isCurrent)
        guard actual.count == expected.count, Set(actual.map(\.localIdentifier)).count == actual.count else { throw CleanupVerificationError.changed }
        let byID = Dictionary(uniqueKeysWithValues: actual.map { ($0.localIdentifier, $0) })
        guard expected.allSatisfy({ byID[$0.localIdentifier] == $0 }) else { throw CleanupVerificationError.changed }
        if let retention {
            let protected = try await library.protectedAlbumMemberIDs(retention.policy.protectedAlbumIDs)
            try await check(library: library, isCurrent: isCurrent)
            guard actual.allSatisfy({ retention.reasons(creationDate: $0.creationDate, isFavorite: $0.isFavorite,
                protectedAlbumMember: protected.contains($0.localIdentifier)).isEmpty }) else { throw CleanupVerificationError.changed }
        }
    }

    static func perform(report: CleanupReport, account: String, generation: UUID,
                        library: any CleanupPhotoLibrary, remote: any CleanupRemoteAPI,
                        isCurrent: @escaping @Sendable () async -> Bool,
                        canCommit: @escaping @Sendable () -> Bool = { true },
                        evidenceCurrent: @escaping @Sendable (CleanupCandidate) async -> Bool = { _ in true }) async throws -> CleanupOutcome {
        guard report.account == account, report.generation == generation else { throw CleanupVerificationError.changed }
        guard report.expiresAt > Date(), report.createdAt <= Date() else { throw CleanupVerificationError.expired }
        let ids = report.eligible
        guard !ids.isEmpty, Set(ids).count == ids.count,
              report.candidates.allSatisfy({ $0.proof.account == account && $0.proof.generation == generation && $0.proof.matches($0.source) }),
              let owner = account.split(separator: "|").last.map(String.init)
        else { throw CleanupVerificationError.invalidReport }
        try await check(library: library, isCurrent: isCurrent)
        try await validateLocal(report.candidates.map(\.asset), library: library, retention: report.retention, isCurrent: isCurrent)

        var items: [BulkUploadCheckItem] = []
        var expectedIDs: [String: String] = [:]
        for (index, candidate) in report.candidates.enumerated() {
            let primaryID = "cleanup-\(index)-primary"
            items.append(BulkUploadCheckItem(id: primaryID, checksum: candidate.proof.primary.checksum))
            expectedIDs[primaryID] = candidate.proof.primary.remoteID
            if candidate.asset.isLivePhoto {
                guard let motion = candidate.proof.motion else { throw CleanupVerificationError.invalidReport }
                let motionID = "cleanup-\(index)-motion"
                items.append(BulkUploadCheckItem(id: motionID, checksum: motion.checksum))
                expectedIDs[motionID] = motion.remoteID
            }
        }
        // Bound the request just like ordinary backup; no missing, duplicate,
        // unknown or remapped response row can authorize a deletion.
        for offset in stride(from: 0, to: items.count, by: 100) {
            let batch = Array(items[offset..<min(offset + 100, items.count)])
            let response = try await remote.bulkUploadCheck(batch)
            try await check(library: library, isCurrent: isCurrent)
            let rows = try BackupVerifier.validatedResults(items: batch, results: response)
            guard rows.values.allSatisfy({ $0.isConfirmedDuplicate && $0.isTrashed == false && $0.assetId == expectedIDs[$0.id] }) else { throw CleanupVerificationError.changed }
        }

        for candidate in report.candidates {
            let asset = candidate.asset
            let current: @Sendable () async -> Bool = {
                guard await isCurrent(), await evidenceCurrent(candidate) else { return false }
                do { try await validateLocal([asset], library: library, retention: report.retention, isCurrent: isCurrent); return true }
                catch { return false }
            }
            try await BackupVerifier.checkCurrent(current)
            let hashes: LocalResourceHashes
            if asset.modificationDate != nil, let bytes = candidate.source.primaryByteCount, bytes > 0,
               !asset.isLivePhoto || (candidate.source.motionByteCount ?? 0) > 0 {
                hashes = LocalResourceHashes(primaryDigest: ResourceDigest(checksum: candidate.source.primaryChecksum, byteCount: bytes),
                    motionDigest: asset.isLivePhoto ? ResourceDigest(checksum: candidate.source.motionChecksum!, byteCount: candidate.source.motionByteCount!) : nil)
            } else {
                hashes = try await library.hashes(for: asset)
                try await BackupVerifier.checkCurrent(current)
            }
            guard hashes.primary == candidate.proof.primary.checksum, hashes.primaryBytes > 0,
                  !asset.isLivePhoto || (hashes.motion == candidate.proof.motion?.checksum && (hashes.motionBytes ?? 0) > 0)
            else { throw CleanupVerificationError.changed }
            _ = try await BackupVerifier.verify(asset: asset, entry: candidate.source, ownerID: owner, account: account,
                                                generation: generation, remote: remote, current: current)
            let primary = try await remote.readbackOriginal(assetID: candidate.proof.primary.remoteID, expected: hashes.primaryDigest)
            try await BackupVerifier.checkCurrent(current)
            guard primary == hashes.primaryDigest else { throw OriginalReadbackError.contentMismatch }
            if asset.isLivePhoto {
                guard let motion = candidate.proof.motion, let digest = hashes.motionDigest else { throw CleanupVerificationError.invalidReport }
                let original = try await remote.readbackOriginal(assetID: motion.remoteID, expected: digest)
                try await BackupVerifier.checkCurrent(current)
                guard original == digest else { throw OriginalReadbackError.contentMismatch }
            }
        }
        // Recheck availability after all original streams; PhotoKit checks the
        // exact revision/set again inside its commit closure. There is no
        // atomic transaction spanning Immich and the system confirmation UI.
        for candidate in report.candidates {
            guard await evidenceCurrent(candidate) else { throw CleanupVerificationError.changed }
            _ = try await BackupVerifier.verify(asset: candidate.asset, entry: candidate.source, ownerID: owner, account: account,
                                                generation: generation, remote: remote, current: {
                                                    guard await isCurrent() else { return false }
                                                    return await evidenceCurrent(candidate)
                                                })
        }
        try await validateLocal(report.candidates.map(\.asset), library: library, retention: report.retention, isCurrent: isCurrent)
        try await check(library: library, isCurrent: isCurrent)
        for candidate in report.candidates {
            guard await evidenceCurrent(candidate) else { throw CleanupVerificationError.changed }
        }
        guard canCommit() else { throw CleanupVerificationError.changed }
        let deleted = try await library.delete(report.candidates.map(\.asset), retention: report.retention, permitted: canCommit)
        guard Set(deleted).count == deleted.count, Set(deleted).isSubset(of: Set(ids)) else { throw CleanupVerificationError.invalidReport }
        let deletedSet = Set(deleted)
        let removed = MediaCounts(assets: report.candidates.filter { deletedSet.contains($0.asset.localIdentifier) }.map(\.asset))
        var kept = report.keptMedia
        for candidate in report.candidates where !deletedSet.contains(candidate.asset.localIdentifier) { kept.add(candidate.asset) }
        return CleanupOutcome(deletedIDs: deleted, deletedMedia: removed, keptMedia: kept)
    }
}

extension ImoraClient: CleanupRemoteAPI {}

nonisolated struct PhotosCleanupLibrary: CleanupPhotoLibrary {
    func hasFullAccess() async -> Bool { PhotoLibraryService.hasFullAccess }
    func protectedAlbumMemberIDs(_ albumIDs: Set<String>) async throws -> Set<String> {
        try PhotoLibraryService.protectedAlbumMemberIDs(albumIDs)
    }
    func delete(_ assets: [DeviceAsset], retention: CleanupRetentionSnapshot?, permitted: @escaping @Sendable () -> Bool) async throws -> [String] {
        try await PhotoLibraryService.deleteVerified(assets, retention: retention, permitted: permitted)
    }
    func assets(ids: [String]) async throws -> [DeviceAsset] {
        var result: [DeviceAsset] = []
        for id in ids { if let asset = await PhotoLibraryService.assetInfo(localIdentifier: id) { result.append(asset) } }
        return result
    }
    func hashes(for asset: DeviceAsset) async throws -> LocalResourceHashes {
        try await PhotoLibraryService.hash(localIdentifier: asset.localIdentifier, includeMotion: asset.isLivePhoto)
    }
    func delete(_ assets: [DeviceAsset], permitted: @escaping @Sendable () -> Bool) async throws -> [String] {
        try await PhotoLibraryService.deleteVerified(assets, permitted: permitted)
    }
}
