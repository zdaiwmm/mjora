import Photos
import XCTest
@testable import Imora

@MainActor
final class Phase4MediaFactsTests: XCTestCase {
    func testDeviceMediaPinAndPreviewPreferencesRoundTripWithoutChangingOldPins() throws {
        var layout = CollectionsLayout()
        let existing = layout.pinnedIDs
        layout.previewSize = .none
        layout.toggleCollapsed(.media)
        layout.togglePin("deviceMedia:panoramas")
        layout.togglePin("deviceMedia:all")
        let restored = CollectionsLayout.decode(try JSONEncoder().encode(layout))
        XCTAssertEqual(restored.pinnedIDs, existing + ["deviceMedia:panoramas"])
        XCTAssertEqual(restored.previewSize, .none)
        XCTAssertTrue(restored.collapsed.contains(.media))
    }

    private func metadata(_ id: String, video: Bool = false, subtypes: PHAssetMediaSubtype = [],
                          portrait: Bool? = false, resources: [AccessiblePhotoSnapshot.Resource]? = nil,
                          favorite: Bool = false) -> AccessiblePhotoSnapshot.Metadata {
        .init(device: .init(localIdentifier: id, isVideo: video, isLivePhoto: subtypes.contains(.photoLive),
            isScreenshot: subtypes.contains(.photoScreenshot), creationDate: .distantPast, modificationDate: .distantPast,
            isFavorite: favorite, durationMs: video ? 3_000 : 0, pixelWidth: 2_048, pixelHeight: 1_536),
            subtypes: subtypes.rawValue,
            resources: resources ?? [.init(type: video ? PHAssetResourceType.video.rawValue : PHAssetResourceType.photo.rawValue,
                uniformTypeIdentifier: video ? "com.apple.quicktime-movie" : "public.jpeg")],
            burstIdentifier: nil, selfPortraitMember: portrait)
    }

    private func extract(_ assets: [AccessiblePhotoSnapshot.Metadata], visible: Set<String>? = nil,
                         coverage: AccessiblePhotoSnapshot.Coverage = .fullLibrary) -> MediaFactsSnapshot {
        DeviceMediaFacts.extract(snapshot: .init(coverage: coverage,
            visibleIdentifiers: visible ?? Set(assets.map { $0.device.localIdentifier }), assets: assets))
    }

    func testSelfPortraitUsesSmartAlbumMembership() {
        let facts = extract([metadata("front", portrait: true), metadata("other", portrait: false), metadata("unknown", portrait: nil)])
        XCTAssertEqual(facts.value(.selfPortrait, for: "front"), .yes)
        XCTAssertEqual(facts.factsByIdentifier["front"]?[.selfPortrait]?.evidence, .smartAlbumMembership)
        XCTAssertEqual(facts.value(.selfPortrait, for: "other"), .no)
        XCTAssertEqual(facts.value(.selfPortrait, for: "unknown"), .unknown)
        XCTAssertEqual(facts.counts(in: .selfPortrait).unknown, 1)
    }

    func testHighFPSIsNotAutomaticallySlowMotion() {
        let facts = extract([metadata("fast", video: true, subtypes: [.videoHighFrameRate, .videoScreenRecording])])
        XCTAssertEqual(facts.value(.highFrameRate, for: "fast"), .yes)
        XCTAssertEqual(facts.value(.screenRecording, for: "fast"), .yes)
        XCTAssertEqual(facts.value(.slowMotion, for: "fast"), .unknown)
        XCTAssertEqual(facts.counts(in: .slowMotion).knownYes, 0)
        XCTAssertEqual(facts.counts(in: .slowMotion).unknown, 1)
    }

    func testLimitedAccessCountsOnlyVisibleAssets() {
        let assets = [metadata("visible", portrait: true), metadata("revoked", portrait: true)]
        let full = extract(assets)
        let limited = extract(assets, visible: ["visible"], coverage: .selectedPhotos)
        XCTAssertEqual(limited.coverage, .selectedPhotos)
        XCTAssertEqual(limited.identifiers(in: .selfPortrait), ["visible"])
        XCTAssertNil(limited.factsByIdentifier["revoked"])
        XCTAssertNotEqual(limited.revision, full.revision)
        let denied = extract(assets, coverage: .unavailable)
        XCTAssertTrue(denied.factsByIdentifier.isEmpty)
    }

    func testMotionHalfNotCountedAsStandaloneVideoAndLabelsCanCoexist() {
        let facts = extract([metadata("live", subtypes: [.photoLive, .photoHDR], resources: [
            .init(type: PHAssetResourceType.photo.rawValue, uniformTypeIdentifier: "public.jpeg"),
            .init(type: PHAssetResourceType.pairedVideo.rawValue, uniformTypeIdentifier: "com.apple.quicktime-movie"),
            .init(type: PHAssetResourceType.adjustmentData.rawValue, uniformTypeIdentifier: "com.apple.property-list")])])
        XCTAssertEqual(facts.identifiers(in: .livePhoto), ["live"])
        XCTAssertEqual(facts.counts(in: .photo).knownYes, 1)
        XCTAssertEqual(facts.counts(in: .video).knownYes, 0)
        XCTAssertEqual(facts.value(.hdr, for: "live"), .yes)
        XCTAssertEqual(facts.value(.edited, for: "live"), .yes)
    }

    func testFilenameDoesNotProveScreenshotOrPanorama() {
        let input = metadata("ordinary")
        var asset = input.device.asAsset(backedUp: false)
        asset.originalFileName = "Screenshot_Panorama_240fps.jpg"; asset.ratio = 10
        let facts = extract([input])
        XCTAssertFalse(PhotoMediaFilter.screenshots.includes(asset, facts: facts))
        XCTAssertFalse(PhotoMediaFilter.panoramas.includes(asset, facts: facts))
        XCTAssertEqual(facts.value(.panorama, for: "ordinary"), .no)
    }

    func testMissingMetadataRemainsUnknown() {
        let facts = extract([], visible: ["missing"])
        XCTAssertEqual(facts.counts(in: .photo).knownYes, 0)
        XCTAssertEqual(facts.counts(in: .photo).unknown, 1)
        let unavailableResources = extract([metadata("raw-unknown", resources: [])])
        XCTAssertEqual(unavailableResources.value(.raw, for: "raw-unknown"), .unknown)
        XCTAssertEqual(unavailableResources.value(.edited, for: "raw-unknown"), .unknown)
    }

    func testRawUsesResourceTypeAndFavoriteDoesNotChangeClassificationRevision() {
        let resources = [AccessiblePhotoSnapshot.Resource(type: PHAssetResourceType.alternatePhoto.rawValue, uniformTypeIdentifier: "com.adobe.raw-image")]
        let first = extract([metadata("raw", resources: resources)])
        let favorite = extract([metadata("raw", resources: resources, favorite: true)])
        XCTAssertEqual(first.value(.raw, for: "raw"), .yes)
        XCTAssertEqual(first.revision, favorite.revision)
        XCTAssertEqual(first.factsByIdentifier["raw"]?[.raw]?.evidence, .resourceType)
    }

    func testCountsAndFilterUseTheSameSnapshotAndRevision() {
        let visible = metadata("panorama", subtypes: .photoPanorama), ordinary = metadata("plain")
        let first = extract([visible, ordinary])
        let same = extract([ordinary, visible])
        let assets = [visible.device.asAsset(backedUp: false), ordinary.device.asAsset(backedUp: false)]
        XCTAssertEqual(first.revision, same.revision)
        let matches = assets.filter { PhotoMediaFilter.panoramas.includes($0, facts: first) }
        XCTAssertEqual(matches.count, first.counts(in: .panorama).knownYes)
        XCTAssertEqual(matches.map(\.localIdentifier), ["panorama"])
        XCTAssertFalse(PhotoMediaFilter.panoramas.isAvailable(onDevice: false))
        XCTAssertTrue(PhotoMediaFilter.panoramas.isAvailable(onDevice: true))
    }
}
