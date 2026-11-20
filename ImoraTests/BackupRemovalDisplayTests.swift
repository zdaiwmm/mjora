import XCTest
@testable import Imora

final class BackupRemovalDisplayTests: XCTestCase {
    func testBackupCountAndHeadlineOmitHistoricalOnlyItems() {
        let photo = fixtureDevice(id: "photo")
        let duplicate = fixtureDevice(id: "duplicate")
        let video = fixtureDevice(id: "video", video: true)
        var videoEntry = BackupEntry(modificationDate: video.modificationDate, isLivePhoto: false,
            primaryChecksum: "video-checksum", primaryRemoteId: "video-cloud-copy")
        videoEntry.historicalBackupConfirmed = true
        let status = BackupLibraryStatus(assets: [photo, duplicate, video], entries: [
            photo.localIdentifier: confirmedPhotoEntry(photo),
            duplicate.localIdentifier: confirmedPhotoEntry(duplicate),
            video.localIdentifier: videoEntry
        ])

        let confirmed = MediaCounts(photos: 2)
        XCTAssertEqual(status.deviceLibraryMedia, MediaCounts(photos: 2, videos: 1))
        XCTAssertEqual(status.cloudConfirmedMedia, confirmed)
        XCTAssertEqual(status.historicalOnlyMedia, MediaCounts(videos: 1))
        XCTAssertEqual(status.backedUp, 2)
        XCTAssertEqual(status.countText, String(localized: "Device items with cloud copies confirmed at last check: \(confirmed.text)"))
        XCTAssertEqual(status.pending, 0)
    }

    func testInvalidatedOrMismatchedProofFallsBackToHistoryEvenAfterSuccessfulSync() {
        let asset = fixtureDevice()
        var invalidated = confirmedPhotoEntry(asset)
        invalidated.verificationState = .pending
        invalidated.proof = nil
        var mismatched = confirmedPhotoEntry(asset)
        mismatched.primaryRemoteId = "different-cloud-copy"

        for entry in [invalidated, mismatched] {
            var status = BackupLibraryStatus(assets: [asset], entries: [asset.localIdentifier: entry])
            status.lastSuccessfulCloudSync = Date(timeIntervalSince1970: 200)
            XCTAssertEqual(status.cloudConfirmedMedia.total, 0)
            XCTAssertEqual(status.historicalOnlyMedia, MediaCounts(photos: 1))
            XCTAssertEqual(status.countText, String(localized: "No cloud copies confirmed."))
            XCTAssertEqual(status.pending, 0)
            XCTAssertTrue(status.isUpToDate)
        }
    }

    func testDeviceInventoryIncludesScreenshotsEvenWhenBackupExcludesThem() {
        let screenshot = DeviceAsset(localIdentifier: "screenshot", isVideo: false, isLivePhoto: false,
            isScreenshot: true, creationDate: nil, modificationDate: nil, isFavorite: false,
            durationMs: 0, pixelWidth: 4, pixelHeight: 3)
        let live = fixtureDevice(id: "live", live: true)
        let video = fixtureDevice(id: "unsupported", video: true)
        var unpairedLive = BackupEntry(modificationDate: live.modificationDate, isLivePhoto: true,
            primaryChecksum: "still", primaryRemoteId: "cloud-still", motionChecksum: "motion")
        unpairedLive.historicalBackupConfirmed = true
        let unsupported = BackupEntry(modificationDate: video.modificationDate, isLivePhoto: false,
            primaryChecksum: "video", unsupported: true)
        let assets = [screenshot, live, video]
        let entries = [live.localIdentifier: unpairedLive, video.localIdentifier: unsupported]
        let excluded = BackupLibraryStatus(assets: assets, entries: entries, excludeScreenshots: true)
        let included = BackupLibraryStatus(assets: assets, entries: entries)

        XCTAssertEqual(excluded.deviceLibraryMedia, MediaCounts(photos: 2, videos: 1))
        XCTAssertEqual(included.deviceLibraryMedia, excluded.deviceLibraryMedia)
        XCTAssertEqual(excluded.excludedMedia, MediaCounts(photos: 1))
        XCTAssertEqual(excluded.pendingMedia, MediaCounts(photos: 1))
        XCTAssertEqual(included.pendingMedia, MediaCounts(photos: 2))
        XCTAssertEqual(excluded.unsupportedMedia, MediaCounts(videos: 1))
        XCTAssertEqual(excluded.cloudConfirmedMedia.total, 0)
        XCTAssertEqual(excluded.historicalOnlyMedia.total, 0)
    }

    func testCloudRemovedRevisionIsNeitherPendingNorFailedEvenAfterEdit() {
        let asset = fixtureDevice()
        var entry = confirmedPhotoEntry(asset)
        entry.remoteDeletionDetected = true
        for revision in [asset.modificationDate, Date(timeIntervalSince1970: 999)] {
            entry.modificationDate = revision
            let status = BackupLibraryStatus(assets: [asset], entries: [asset.localIdentifier: entry])
            XCTAssertEqual(status.pending, 0)
            XCTAssertEqual(status.cloudDeletedMedia, MediaCounts(photos: 1))
            XCTAssertEqual(status.cloudConfirmedMedia.total, 0)
            XCTAssertEqual(status.historicalOnlyMedia.total, 0)
            XCTAssertEqual(status.unindexed, 0)
        }
    }

    func testEditedDeviceItemDoesNotCountThePreviousRevisionAsBackedUp() {
        let before = fixtureDevice()
        let after = fixtureDevice(modified: Date(timeIntervalSince1970: 999))
        let status = BackupLibraryStatus(assets: [after], entries: [before.localIdentifier: confirmedPhotoEntry(before)])

        XCTAssertEqual(status.cloudConfirmedMedia.total, 0)
        XCTAssertEqual(status.historicalOnlyMedia.total, 0)
        XCTAssertEqual(status.pendingMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.unindexed, 1)
    }

    private func confirmedPhotoEntry(_ asset: DeviceAsset) -> BackupEntry {
        let primary = BackupComponentProof(remoteID: "shared-cloud-copy", checksum: "photo-checksum",
            ownerID: "owner", type: "IMAGE")
        var entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: false,
            primaryChecksum: primary.checksum, primaryRemoteId: primary.remoteID)
        entry.historicalBackupConfirmed = true
        entry.verificationState = .verified
        entry.proof = BackupProof(account: "server|owner", generation: UUID(), localRevision: asset,
            primary: primary, motion: nil, livePhotoVideoID: nil, verifiedAt: Date(timeIntervalSince1970: 150))
        return entry
    }
}
