import Foundation

extension MediaCounts {
    nonisolated init(assets: [DeviceAsset]) {
        for asset in assets { add(asset) }
    }

    nonisolated mutating func add(_ asset: DeviceAsset) {
        if asset.isVideo && !asset.isLivePhoto { videos += 1 } else { photos += 1 }
    }
}

/// a Live Photo only counts as backed up when both resources are confirmed.
nonisolated struct BackupLibraryStatus: Equatable, Sendable {
    var lastSuccessfulCloudSync: Date? = nil
    private(set) var totalMedia = MediaCounts()
    private(set) var backedUpMedia = MediaCounts()
    private(set) var unindexedMedia = MediaCounts()
    private(set) var unsupportedMedia = MediaCounts()
    private(set) var pendingMedia = MediaCounts()
    private(set) var excludedMedia = MediaCounts()
    private(set) var cloudDeletedMedia = MediaCounts()
    var cloudDeleted: Int { cloudDeletedMedia.total }

    var excluded: Int { excludedMedia.total }
    var total: Int { totalMedia.total }
    var backedUp: Int { backedUpMedia.total }
    var unindexed: Int { unindexedMedia.total }
    var unsupported: Int { unsupportedMedia.total }
    var pending: Int { pendingMedia.total }
    var isUpToDate: Bool { pending == 0 && unsupported == 0 }

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
                pendingMedia.add(asset)
                continue
            }
            if entry.isBackedUp || entry.hasHistoricalBackup { backedUpMedia.add(asset) }
            else if entry.unsupported { unsupportedMedia.add(asset) }
            else { pendingMedia.add(asset) }
        }
    }

    var countText: String {
        total == 0 ? (excluded > 0 ? String(localized: "No photos or videos selected for backup.") : String(localized: "No photos or videos in your library."))
            : String(localized: "\(backedUpMedia.text) backed up")
    }

    static let upToDateText = String(localized: "Done. No new photos or videos to back up.")

    func completionText(_ summary: BackupSummary) -> String {
        var details: [String] = []
        if summary.uploaded > 0 { details.append(String(localized: "\(summary.uploadedMedia.text) uploaded")) }
        if summary.failed > 0 { details.append(String(localized: "\(summary.failedMedia.text) failed")) }
        if summary.skipped > 0 { details.append(String(localized: "\(summary.skippedMedia.text) skipped")) }
        if unsupported > 0 { details.append(String(localized: "\(unsupportedMedia.text) unsupported")) }
        if pending > 0 { details.append(String(localized: "\(pendingMedia.text) still to index or back up")) }
        if details.isEmpty { return Self.upToDateText }
        let detail = ListFormatter.localizedString(byJoining: details)
        return summary.failed > 0 || pending > 0 || unsupported > 0
            ? String(localized: "Backup incomplete. \(detail).")
            : String(localized: "Done. \(detail).")
    }
}
