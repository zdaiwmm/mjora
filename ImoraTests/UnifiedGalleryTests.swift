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
        let device = fixtureDevice(id: "local")
        let remote = cloud("remote")
        let source = await TimelineModel.makeLocalMergeSource([
            LocalTimelineItem(device: device, remoteId: "remote", backedUp: true),
            LocalTimelineItem(device: fixtureDevice(id: "new"), remoteId: nil, backedUp: false)
        ])
        let month = "1970-01-01"
        let section = TimelineSection(id: month, monthTitle: month, count: 1,
            days: [DayGroup(id: "0", title: "day", assets: [remote])])
        let merged = TimelineModel.mergedSections([section], local: source)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(Set(merged.flatMap { $0.days ?? [] }.flatMap(\.assets).map(\.id)), ["remote", "local-new"])
        let offline = TimelineModel.mergedSections([], local: source)
        XCTAssertEqual(offline.reduce(0) { $0 + $1.count }, 2)
        let unloaded = TimelineSection(id: month, monthTitle: month, count: 1, days: nil)
        let pending = TimelineModel.mergedSections([unloaded], local: source)
        XCTAssertEqual(pending.first?.count, 2)
        XCTAssertEqual(pending.first?.leadingUnloadedAssetCount, 1)
        XCTAssertEqual(pending.first?.days?.flatMap(\.assets).map(\.id), ["local-new"])
        let partial = TimelineSection(id: month, monthTitle: month, count: 2,
            days: section.days, leadingUnloadedAssetCount: 1)
        let withPartial = TimelineModel.mergedSections([partial], local: source)
        XCTAssertEqual(withPartial.first?.count, 3)
        XCTAssertEqual(withPartial.first?.leadingUnloadedAssetCount, 1)
    }

    func testFavoritesDoNotAdmitNonfavoriteDevicePhotos() async {
        let source = await TimelineModel.makeLocalMergeSource([
            LocalTimelineItem(device: fixtureDevice(id: "not-favorite"), remoteId: nil, backedUp: false)
        ], favoritesOnly: true)
        XCTAssertTrue(TimelineModel.mergedSections([], local: source).isEmpty)
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

    private func cloud(_ id: String) -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: nil,
            fileCreatedAt: Date(timeIntervalSince1970: 50), localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
    }

}
