import XCTest
@testable import Imora

final class BackupRemovalDisplayTests: XCTestCase {
    func testBackupCountAndHeadlineIncludeHistoricalOnlyItems() {
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
        XCTAssertEqual(status.uniqueCloudKnownMedia, MediaCounts(photos: 1, videos: 1))
        XCTAssertEqual(status.duplicateMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.verified, 2)
        XCTAssertEqual(status.backedUp, 3)
        XCTAssertEqual(status.awaitingVerification, 1)
        XCTAssertEqual(status.countText, String(localized: "Device items with cloud copies confirmed at last check: \(MediaCounts(photos: 2, videos: 1).text)"))
        XCTAssertEqual(status.pending, 0)
        XCTAssertTrue(status.isUpToDate)
    }

    func testExtraDeviceCopiesCountByMediaTypeAcrossVerifiedAndHistoricalBackups() {
        let photo = fixtureDevice(id: "photo")
        let duplicatePhoto = fixtureDevice(id: "duplicate-photo")
        let video = fixtureDevice(id: "video", video: true)
        let duplicateVideo = fixtureDevice(id: "duplicate-video", video: true)
        let thirdVideo = fixtureDevice(id: "third-video", video: true)
        let firstLive = fixtureDevice(id: "live-first", live: true)
        let secondLive = fixtureDevice(id: "live-second", live: true)
        let pending = fixtureDevice(id: "pending")
        let deleted = fixtureDevice(id: "deleted", video: true)
        var deletedEntry = backedUpEntry(deleted, remoteID: "video-copy")
        deletedEntry.remoteDeletionDetected = true
        let assets = [photo, duplicatePhoto, video, duplicateVideo, thirdVideo, firstLive, secondLive, pending, deleted]
        let status = BackupLibraryStatus(assets: assets, entries: [
            photo.localIdentifier: backedUpEntry(photo, remoteID: "still-copy"),
            duplicatePhoto.localIdentifier: backedUpEntry(duplicatePhoto, remoteID: "still-copy", verified: false),
            video.localIdentifier: backedUpEntry(video, remoteID: "video-copy", verified: false),
            duplicateVideo.localIdentifier: backedUpEntry(duplicateVideo, remoteID: "video-copy"),
            thirdVideo.localIdentifier: backedUpEntry(thirdVideo, remoteID: "video-copy"),
            firstLive.localIdentifier: backedUpEntry(firstLive, remoteID: "live-first-copy"),
            secondLive.localIdentifier: backedUpEntry(secondLive, remoteID: "live-second-copy"),
            deleted.localIdentifier: deletedEntry
        ])

        XCTAssertEqual(status.uniqueCloudKnownMedia, MediaCounts(photos: 3, videos: 1))
        XCTAssertEqual(status.duplicateMedia, MediaCounts(photos: 1, videos: 2))
        XCTAssertEqual(status.deviceLibraryMedia, MediaCounts(photos: 5, videos: 4))
        XCTAssertEqual(status.pendingMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.cloudDeletedMedia, MediaCounts(videos: 1))
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
            XCTAssertEqual(status.awaitingVerification, 1)
            XCTAssertEqual(status.verified, 0)
            XCTAssertEqual(status.backedUp, 1)
            XCTAssertEqual(status.countText, String(localized: "Device items with cloud copies confirmed at last check: \(MediaCounts(photos: 1).text)"))
            XCTAssertEqual(status.pending, 0)
            XCTAssertTrue(status.isUpToDate, "A known server copy completes backup even when cleanup proof is stale")
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
            XCTAssertFalse(status.isUpToDate, "A deleted cloud copy leaves the local item incomplete")
        }
    }

    func testFullyVerifiedCurrentLibraryIsUpToDate() {
        let asset = fixtureDevice()
        let status = BackupLibraryStatus(assets: [asset], entries: [
            asset.localIdentifier: confirmedPhotoEntry(asset)
        ])

        XCTAssertEqual(status.backedUp, 1)
        XCTAssertEqual(status.verified, 1)
        XCTAssertEqual(status.awaitingVerification, 0)
        XCTAssertEqual(status.pending, 0)
        XCTAssertTrue(status.isUpToDate)
    }

    func testProofProgressMovesOnlyThatItemOutOfPendingImmediately() {
        let first = fixtureDevice(id: "first")
        let second = fixtureDevice(id: "second")
        var status = BackupLibraryStatus(assets: [first, second], entries: [:])

        XCTAssertEqual(status.pending, 2)
        XCTAssertEqual(status.unindexed, 2)
        status.recordVerified(first, remoteID: "first-copy")
        status.recordVerified(first, remoteID: "first-copy")

        XCTAssertEqual(status.verified, 1)
        XCTAssertEqual(status.backedUp, 1)
        XCTAssertEqual(status.uniqueCloudKnownMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.duplicateMedia, MediaCounts())
        XCTAssertEqual(status.pending, 1)
        XCTAssertEqual(status.unindexed, 1)
        XCTAssertFalse(status.isUpToDate)
    }

    func testServerMatchMovesOnlyThatItemToBackedUpBeforeVerification() {
        let first = fixtureDevice(id: "first")
        let second = fixtureDevice(id: "second")
        var status = BackupLibraryStatus(assets: [first, second], entries: [:])

        status.recordKnownCopy(first, remoteID: "first-copy")
        status.recordKnownCopy(first, remoteID: "first-copy")

        XCTAssertEqual(status.backedUp, 1)
        XCTAssertEqual(status.verified, 0)
        XCTAssertEqual(status.awaitingVerification, 1)
        XCTAssertEqual(status.pending, 1)
        XCTAssertEqual(status.unindexed, 1)

        status.recordVerified(first, remoteID: "first-copy")

        XCTAssertEqual(status.backedUp, 1)
        XCTAssertEqual(status.verified, 1)
        XCTAssertEqual(status.awaitingVerification, 0)
        XCTAssertEqual(status.pending, 1)
        XCTAssertEqual(status.unindexed, 1)
    }

    func testDuplicateCountFollowsProgressAndDoesNotCountAnItemOutsideTheSnapshot() {
        let first = fixtureDevice(id: "first")
        let second = fixtureDevice(id: "second")
        let newlyAdded = fixtureDevice(id: "newly-added")
        var status = BackupLibraryStatus(assets: [first, second], entries: [:])

        status.recordKnownCopy(first, remoteID: "shared-copy")
        status.recordKnownCopy(second, remoteID: "shared-copy")
        status.recordKnownCopy(second, remoteID: "shared-copy")
        status.recordVerified(second, remoteID: "shared-copy")
        status.recordKnownCopy(second, remoteID: "stale-copy")
        status.recordVerified(newlyAdded, remoteID: "shared-copy")

        XCTAssertEqual(status.deviceLibraryMedia, MediaCounts(photos: 2))
        XCTAssertEqual(status.uniqueCloudKnownMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.duplicateMedia, MediaCounts(photos: 1))
        XCTAssertEqual(status.awaitingVerification, 1)
        XCTAssertEqual(status.pending, 0)

        status.recordVerified(first, remoteID: "new-copy")

        XCTAssertEqual(status.uniqueCloudKnownMedia, MediaCounts(photos: 2))
        XCTAssertEqual(status.duplicateMedia, MediaCounts())
        XCTAssertEqual(status.awaitingVerification, 0)
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
        backedUpEntry(asset, remoteID: "shared-cloud-copy")
    }

    private func backedUpEntry(_ asset: DeviceAsset, remoteID: String, verified: Bool = true) -> BackupEntry {
        let primary = BackupComponentProof(remoteID: remoteID, checksum: "\(remoteID)-checksum",
            ownerID: "owner", type: asset.isVideo && !asset.isLivePhoto ? "VIDEO" : "IMAGE")
        let motion = asset.isLivePhoto ? BackupComponentProof(remoteID: "shared-motion-copy", checksum: "motion-checksum",
            ownerID: "owner", type: "VIDEO") : nil
        var entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: asset.isLivePhoto,
            primaryChecksum: primary.checksum, primaryRemoteId: primary.remoteID,
            motionChecksum: motion?.checksum, motionRemoteId: motion?.remoteID)
        entry.historicalBackupConfirmed = true
        guard verified else { return entry }
        entry.verificationState = .verified
        entry.proof = BackupProof(account: "server|owner", generation: UUID(), localRevision: asset,
            primary: primary, motion: motion, livePhotoVideoID: motion?.remoteID, verifiedAt: Date(timeIntervalSince1970: 150))
        return entry
    }
}
