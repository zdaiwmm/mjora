import Foundation

extension MediaCounts {
    nonisolated init(assets: [DeviceAsset]) {
        for asset in assets { add(asset) }
    }

    nonisolated mutating func add(_ asset: DeviceAsset) {
        if asset.countsAsBackupVideo { videos += 1 } else { photos += 1 }
    }
}

/// Counts device items using their retained backup evidence.
nonisolated struct BackupLibraryStatus: Equatable, Sendable {
    private struct CloudCopy: Hashable {
        let remoteID: String
        let isVideo: Bool
    }

    var lastSuccessfulCloudSync: Date? = nil
    private(set) var totalMedia = MediaCounts()
    private(set) var cloudConfirmedMedia = MediaCounts()
    private(set) var historicalOnlyMedia = MediaCounts()
    private(set) var unindexedMedia = MediaCounts()
    private(set) var unsupportedMedia = MediaCounts()
    private(set) var pendingMedia = MediaCounts()
    private(set) var excludedMedia = MediaCounts()
    private(set) var cloudDeletedMedia = MediaCounts()
    private(set) var uniqueCloudKnownMedia = MediaCounts()
    private var cloudConfirmedIDs: Set<String> = []
    private var historicalOnlyIDs: Set<String> = []
    private var pendingVideoByID: [String: Bool] = [:]
    private var unindexedIDs: Set<String> = []
    private var cloudCopyByLocalID: [String: CloudCopy] = [:]
    private var localCountByCloudCopy: [CloudCopy: Int] = [:]
    var deviceLibraryMedia: MediaCounts {
        MediaCounts(photos: totalMedia.photos + excludedMedia.photos, videos: totalMedia.videos + excludedMedia.videos)
    }
    var cloudDeleted: Int { cloudDeletedMedia.total }
    var cloudKnownMedia: MediaCounts {
        MediaCounts(photos: cloudConfirmedMedia.photos + historicalOnlyMedia.photos,
                    videos: cloudConfirmedMedia.videos + historicalOnlyMedia.videos)
    }
    var duplicateMedia: MediaCounts {
        MediaCounts(photos: cloudKnownMedia.photos - uniqueCloudKnownMedia.photos,
                    videos: cloudKnownMedia.videos - uniqueCloudKnownMedia.videos)
    }

    var excluded: Int { excludedMedia.total }
    var total: Int { totalMedia.total }
    /// Current revisions with a known server copy. A separate fresh proof is
    /// still required before cleanup can remove the local original.
    var backedUp: Int { cloudKnownMedia.total }
    /// Current revisions proved against this exact account and local revision.
    var verified: Int { cloudConfirmedMedia.total }
    var awaitingVerification: Int { historicalOnlyMedia.total }
    var unindexed: Int { unindexedMedia.total }
    var unsupported: Int { unsupportedMedia.total }
    var pending: Int { pendingMedia.total }
    var isUpToDate: Bool {
        pending == 0 && unsupported == 0 && cloudDeleted == 0
    }

    init(assets: [DeviceAsset], entries: [String: BackupEntry], excludeScreenshots: Bool = false) {
        for asset in assets {
            if excludeScreenshots && asset.isScreenshot {
                excludedMedia.add(asset)
                continue
            }
            totalMedia.add(asset)
            // Removal protection outlives revisions and login sessions.
            if entries[asset.localIdentifier]?.isUploadBlockedByRemoteRemoval == true {
                cloudDeletedMedia.add(asset)
                continue
            }
            guard let entry = entries[asset.localIdentifier],
                  entry.matches(modificationDate: asset.modificationDate),
                  entry.isLivePhoto == asset.isLivePhoto else {
                unindexedMedia.add(asset)
                unindexedIDs.insert(asset.localIdentifier)
                pendingMedia.add(asset)
                pendingVideoByID[asset.localIdentifier] = asset.countsAsBackupVideo
                continue
            }
            if let remoteID = entry.primaryRemoteId, entry.hasHistoricalBackup {
                if entry.isBackedUp {
                    cloudConfirmedMedia.add(asset)
                    cloudConfirmedIDs.insert(asset.localIdentifier)
                } else {
                    historicalOnlyMedia.add(asset)
                    historicalOnlyIDs.insert(asset.localIdentifier)
                }
                recordCloudCopy(asset, remoteID: remoteID)
            } else if entry.unsupported {
                unsupportedMedia.add(asset)
            } else {
                pendingMedia.add(asset)
                pendingVideoByID[asset.localIdentifier] = asset.countsAsBackupVideo
            }
        }
    }

    /// Apply a server match as soon as one item finishes. A known copy counts
    /// as backed up, while the separate verification counter remains honest
    /// until a fresh proof is recorded.
    mutating func recordKnownCopy(_ asset: DeviceAsset, remoteID: String) {
        let id = asset.localIdentifier
        guard !cloudConfirmedIDs.contains(id), canRecordCloudCopy(asset) else { return }
        recordCloudCopy(asset, remoteID: remoteID)
        guard historicalOnlyIDs.insert(id).inserted else { return }
        historicalOnlyMedia.add(asset)
        if pendingVideoByID.removeValue(forKey: id) != nil {
            pendingMedia.remove(asset)
        }
        if unindexedIDs.remove(id) != nil {
            unindexedMedia.remove(asset)
        }
    }

    /// Apply a proof as soon as one item finishes instead of waiting for the
    /// whole library check. The set makes repeated progress events idempotent.
    mutating func recordVerified(_ asset: DeviceAsset, remoteID: String) {
        let id = asset.localIdentifier
        guard canRecordCloudCopy(asset) else { return }
        recordCloudCopy(asset, remoteID: remoteID)
        guard cloudConfirmedIDs.insert(id).inserted else { return }
        cloudConfirmedMedia.add(asset)
        if historicalOnlyIDs.remove(id) != nil {
            historicalOnlyMedia.remove(asset)
        }
        if pendingVideoByID.removeValue(forKey: id) != nil {
            pendingMedia.remove(asset)
        }
        if unindexedIDs.remove(id) != nil {
            unindexedMedia.remove(asset)
        }
    }

    private func canRecordCloudCopy(_ asset: DeviceAsset) -> Bool {
        let id = asset.localIdentifier
        let snapshotIsVideo = pendingVideoByID[id] ?? cloudCopyByLocalID[id]?.isVideo
        return snapshotIsVideo == asset.countsAsBackupVideo
    }

    private mutating func recordCloudCopy(_ asset: DeviceAsset, remoteID: String) {
        let id = asset.localIdentifier
        let copy = CloudCopy(remoteID: remoteID, isVideo: asset.countsAsBackupVideo)
        let previous = cloudCopyByLocalID[id]
        guard previous != copy else { return }
        cloudCopyByLocalID[id] = copy
        if let previous {
            if localCountByCloudCopy[previous] == 1 {
                localCountByCloudCopy[previous] = nil
                uniqueCloudKnownMedia.remove(asset)
            } else {
                localCountByCloudCopy[previous, default: 0] -= 1
            }
        }
        localCountByCloudCopy[copy, default: 0] += 1
        if localCountByCloudCopy[copy] == 1 {
            uniqueCloudKnownMedia.add(asset)
        }
    }

    var countText: String {
        if total == 0 {
            return excluded > 0 ? String(localized: "No photos or videos selected for backup.")
                : String(localized: "No photos or videos on this device.")
        }
        if cloudKnownMedia.total == 0 { return String(localized: "No cloud copies confirmed.") }
        return String(localized: "Device items with cloud copies confirmed at last check: \(cloudKnownMedia.text)")
    }

    static let upToDateText = String(localized: "Done. No new photos or videos to back up.")

    func completionText(_ summary: BackupSummary) -> String {
        var details: [String] = []
        if summary.uploaded > 0 { details.append(String(localized: "\(summary.uploadedMedia.text) uploaded")) }
        if summary.failed > 0 { details.append(String(localized: "\(summary.failedMedia.text) failed")) }
        if summary.skipped > 0 { details.append(String(localized: "\(summary.skippedMedia.text) skipped")) }
        if unsupported > 0 { details.append(String(localized: "\(unsupportedMedia.text) unsupported")) }
        if cloudDeleted > 0 {
            details.append(String(localized: "Deleted in Cloud") + ": " + cloudDeletedMedia.text)
        }
        if pending > 0 { details.append(String(localized: "\(pendingMedia.text) still to index or back up")) }
        if details.isEmpty { return Self.upToDateText }
        let detail = ListFormatter.localizedString(byJoining: details)
        return summary.failed > 0 || pending > 0 || unsupported > 0 || cloudDeleted > 0
            ? String(localized: "Backup incomplete. \(detail).")
            : String(localized: "Done. \(detail).")
    }
}

private extension MediaCounts {
    nonisolated mutating func remove(_ asset: DeviceAsset) {
        if asset.countsAsBackupVideo {
            videos = max(0, videos - 1)
        } else {
            photos = max(0, photos - 1)
        }
    }
}

private extension DeviceAsset {
    nonisolated var countsAsBackupVideo: Bool { isVideo && !isLivePhoto }
}
