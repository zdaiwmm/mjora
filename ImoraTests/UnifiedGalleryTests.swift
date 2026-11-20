import XCTest
@testable import Imora

@MainActor
final class UnifiedGalleryTests: XCTestCase {
    func testSourcesUseIndependentPreferenceAndLaunchPacks() {
        XCTAssertEqual(PhotosLibrarySource.allCases.map(\.rawValue), ["all", "cloud", "local"])
        XCTAssertNotEqual(PhotosLibrarySource.preferenceKey, "imora.photos.source")
        XCTAssertEqual(PhotosLibrarySource.all.launchSource, "mixed")
        XCTAssertEqual(PhotosLibrarySource.cloud.launchSource, "cloud")
        XCTAssertEqual(PhotosLibrarySource.local.launchSource, "device")
    }

    func testAllShowsCloudOnlyDeviceOnlyAndOneCopyOfAnUnchangedPair() async {
        let local = fixtureDevice(id: "paired").asAsset(backedUp: true)
        let remote = cloud("remote-pair")
        let extra = fixtureDevice(id: "device-only").asAsset(backedUp: false)
        let cloudOnly = cloud("cloud-only")
        let merged = await PhotosLocalMediaLibrary.merged(cloud: [remote, cloudOnly], device: [local, extra],
            remoteByLocal: ["paired": "remote-pair"])
        XCTAssertEqual(Set(merged.map(\.id)), ["remote-pair", cloudOnly.id, extra.id])
        XCTAssertEqual(merged.count, 3)
        var edited = local
        edited.isLocalBackedUp = false
        let editedMerge = await PhotosLocalMediaLibrary.merged(cloud: [remote], device: [edited],
            remoteByLocal: ["paired": "remote-pair"])
        XCTAssertEqual(editedMerge.count, 2,
            "An unbacked local revision must not disappear behind an older cloud copy")
    }

    func testBucketProjectionIncludesDeviceOnlyMonthsAndDeduplicatesPairs() async {
        let device = januaryDevice("local")
        let remote = cloud("remote")
        let source = await TimelineModel.makeLocalMergeSource([
            LocalTimelineItem(device: device, remoteId: "remote", backedUp: true),
            LocalTimelineItem(device: januaryDevice("new"), remoteId: nil, backedUp: false)
        ])
        let month = "1970-01-01"
        let section = TimelineSection(id: month, monthTitle: month, count: 1,
            days: [DayGroup(id: "0", title: "day", assets: [remote])])
        let merged = TimelineModel.mergedSections([section], local: source)
        XCTAssertEqual(merged.sections.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(visibleIDs(in: merged.sections), ["remote", "local-new"])
        let offline = TimelineModel.mergedSections([], local: source)
        XCTAssertEqual(offline.sections.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(visibleIDs(in: offline.sections), ["local-local", "local-new"])
        let partial = TimelineSection(id: month, monthTitle: month, count: 2,
            days: section.days, leadingUnloadedAssetCount: 1)
        let withPartial = TimelineModel.mergedSections([partial], local: source)
        XCTAssertEqual(withPartial.sections.first?.count, 3)
        XCTAssertEqual(withPartial.sections.first?.leadingUnloadedAssetCount, 1)
        XCTAssertEqual(withPartial.unresolvedPairItemCount, 0)
    }

    func testUnloadedBucketsRetainPairedDevicePhotosAndCloudSlots() async {
        let source = await TimelineModel.makeLocalMergeSource([
            .init(device: januaryDevice("first"), remoteId: "shared-checksum", backedUp: true),
            .init(device: januaryDevice("second"), remoteId: "shared-checksum", backedUp: true),
            .init(device: januaryDevice("no-remote-id"), remoteId: nil, backedUp: true),
        ])
        let month = "1970-01-01"
        let unloaded = TimelineSection(id: month, monthTitle: month, count: 1, days: nil)
        let pending = TimelineModel.mergedSections([unloaded], local: source)
        XCTAssertEqual(visibleIDs(in: pending.sections), ["local-first", "local-second", "local-no-remote-id"])
        XCTAssertEqual(pending.sections.first?.count, 4)
        XCTAssertEqual(pending.sections.first?.leadingUnloadedAssetCount, 1)
        XCTAssertEqual(pending.unresolvedPairItemCount, 2)

        let partial = TimelineSection(id: month, monthTitle: month, count: 4,
            days: [DayGroup(id: "0", title: "day", assets: [cloud("other")])],
            leadingUnloadedAssetCount: 1, trailingUnloadedAssetCount: 2)
        let withPartial = TimelineModel.mergedSections([partial], local: source)
        XCTAssertEqual(visibleIDs(in: withPartial.sections), ["other", "local-first", "local-second", "local-no-remote-id"])
        XCTAssertEqual(withPartial.sections.first?.count, 7)
        XCTAssertEqual(withPartial.sections.first?.leadingUnloadedAssetCount, 1)
        XCTAssertEqual(withPartial.sections.first?.trailingUnloadedAssetCount, 2)
        XCTAssertEqual(withPartial.unresolvedPairItemCount, 2)
    }

    func testMissingPairRemainsVisibleUntilItsCloudIDAppearsInAnotherMonth() async {
        let source = await TimelineModel.makeLocalMergeSource([
            .init(device: januaryDevice("first"), remoteId: "shared-checksum", backedUp: true),
            .init(device: januaryDevice("second"), remoteId: "shared-checksum", backedUp: true),
        ])
        let january = TimelineSection(id: "1970-01-01", monthTitle: "January", count: 1,
            days: [DayGroup(id: "0", title: "day", assets: [cloud("other")])])
        let missing = TimelineModel.mergedSections([january], local: source)
        XCTAssertEqual(visibleIDs(in: missing.sections), ["other", "local-first", "local-second"])
        XCTAssertEqual(missing.sections.first?.count, 3)
        XCTAssertEqual(missing.unresolvedPairItemCount, 0)

        var february = TimelineSection(id: "1970-02-01", monthTitle: "February", count: 1, days: nil)
        let pending = TimelineModel.mergedSections([february, january], local: source)
        XCTAssertEqual(visibleIDs(in: pending.sections), ["other", "local-first", "local-second"])
        XCTAssertEqual(pending.unresolvedPairItemCount, 2)

        february.days = [DayGroup(id: "31", title: "day",
            assets: [cloud("shared-checksum", capturedAt: Date(timeIntervalSince1970: 31 * 86_400))])]
        let restored = TimelineModel.mergedSections([february, january], local: source)
        XCTAssertEqual(visibleIDs(in: restored.sections), ["other", "shared-checksum"])
        XCTAssertEqual(restored.sections.map(\.count), [1, 1])
        XCTAssertEqual(restored.unresolvedPairItemCount, 0)
    }

    func testFavoritesDoNotAdmitNonfavoriteDevicePhotos() async {
        let source = await TimelineModel.makeLocalMergeSource([
            LocalTimelineItem(device: fixtureDevice(id: "not-favorite"), remoteId: nil, backedUp: false)
        ], favoritesOnly: true)
        XCTAssertTrue(TimelineModel.mergedSections([], local: source).sections.isEmpty)
    }

    func testFirstFailureIsRecoverableAfterRestartAndScopedToItsAccount() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var ledger = RepeatedBackupFailures()
        ledger.recordFailure(account: "owner", localIdentifier: "photo", modificationDate: nil,
            isVideo: false, kind: .connection)
        ledger.recordFailure(account: "other", localIdentifier: "private", modificationDate: nil,
            isVideo: false, kind: .authorization)
        ledger.save(to: defaults)
        let cold = RepeatedBackupFailures.load(from: defaults)
        XCTAssertEqual(cold.failures(account: "owner").map(\.localIdentifier), ["photo"])
        XCTAssertTrue(cold.needingAttention(account: "owner").isEmpty,
            "Recovery must not wait for the six-failure banner threshold")
        ledger.clear(account: "owner", localIdentifier: "photo")
        XCTAssertTrue(ledger.failures(account: "owner").isEmpty)
        XCTAssertEqual(ledger.failures(account: "other").count, 1)
    }

    func testFailureRecoveryUsesTypedCauses() {
        XCTAssertEqual(RepeatedBackupFailureKind(error: PhotoLibraryError.resourceMissing), .originalUnavailable)
        XCTAssertEqual(RepeatedBackupFailureKind(error: PhotoLibraryError.insufficientStorage), .deviceStorage)
        XCTAssertEqual(RepeatedBackupFailureKind(error: ImoraError.http(507, "存储空间不足")), .cloudStorage)
        XCTAssertEqual(RepeatedBackupFailureKind(error: ImoraError.http(400, "quota full")), .other,
            "Unverified server prose must not masquerade as a quota diagnosis")
    }

    func testCachedBackedUpFlagCannotHideMissingLiveEvidence() {
        let cached = fixtureDevice().asAsset(backedUp: true)
        XCTAssertEqual(PhotoBackupStatus.resolve(asset: cached, backup: nil), .notBackedUp)
    }

    private func visibleIDs(in sections: [TimelineSection]) -> Set<String> {
        Set(sections.flatMap { $0.days ?? [] }.flatMap(\.assets).map(\.id))
    }

    private func januaryDevice(_ id: String) -> DeviceAsset {
        let date = Date(timeIntervalSince1970: 14 * 86_400)
        return DeviceAsset(localIdentifier: id, isVideo: false, isLivePhoto: false, isScreenshot: false,
            creationDate: date, modificationDate: date,
            isFavorite: false, durationMs: 0, pixelWidth: 4, pixelHeight: 3)
    }

    private func cloud(_ id: String, capturedAt: Date = Date(timeIntervalSince1970: 50)) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: nil,
            fileCreatedAt: capturedAt, localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
    }

}
