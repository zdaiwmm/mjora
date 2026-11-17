import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotosPresentationTests: XCTestCase {
    private func periodFixture() async throws -> (SessionStore, LocalHTTPServer, Asset) {
        let userID = "period-motion-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1536, height: 1536), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1536, height: 1536))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start()
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-motion-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let asset = Asset(id: "period-fixture-\(UUID())", ownerId: userID, isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: "period-r1", fileCreatedAt: .now,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        return (session, server, asset)
    }

    func testPeriodSurfaceKeepsTheCardBoundsAfterAThumbnailWithDifferentIntrinsicSizeArrives() async throws {
        let expected = CGSize(width: 179, height: 241.3333333333333)
        let asset = Asset(id: "surface-size-fixture", ownerId: "fixture", isImage: true, isFavorite: false,
                          isTrashed: false, visibility: .timeline, thumbhash: nil,
                          fileCreatedAt: Date(timeIntervalSince1970: 1_735_689_600), localOffsetHours: 0,
                          duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        let session = SessionStore()
        let motion = PhotoPeriodMotion()
        let host = UIHostingController(rootView: Color.clear.frame(width: expected.width, height: expected.height)
            .overlay { PhotoPeriodCoverSurface(asset: asset, mode: .months, session: session, motion: motion, size: expected) }
            .clipped())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        func surface(in view: UIView) -> PeriodPhotoImageView? {
            if let image = view as? PeriodPhotoImageView { return image }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        for _ in 0..<20 where surface(in: host.view) == nil {
            window.layoutIfNeeded(); host.view.layoutIfNeeded(); await Task.yield()
        }
        let image = try XCTUnwrap(surface(in: host.view))
        for intrinsic in [CGSize(width: 288, height: 240), CGSize(width: 900, height: 600)] {
            image.image = UIGraphicsImageRenderer(size: intrinsic).image { context in
                UIColor.blue.setFill(); context.fill(CGRect(origin: .zero, size: intrinsic))
            }
            host.view.setNeedsLayout()
            for _ in 0..<6 { await Task.yield(); window.layoutIfNeeded(); host.view.layoutIfNeeded() }
            XCTAssertEqual(image.bounds.width, expected.width, accuracy: 0.5,
                           "The image's real motion surface must match its day card, not its decoded thumbnail width")
            XCTAssertEqual(image.bounds.height, expected.height, accuracy: 0.5)
        }
    }

    func testReleasingPeriodOwnerCannotLeaveItsPhotoOverTheNextScreen() async throws {
        let (session, server, asset) = try await periodFixture()
        defer { server.stop() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let cover = PeriodPhotoImageView(frame: .zero)
        cover.frame = CGRect(x: 16, y: 150, width: 358, height: 224)
        controller.view.addSubview(cover)
        var motion: PhotoPeriodMotion? = PhotoPeriodMotion()
        cover.configure(asset: asset, mode: .years, session: session, motion: try XCTUnwrap(motion), targetPixelSize: 1152)
        for _ in 0..<200 {
            if cover.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(cover.preparedSurfaceForMotion())
        motion?.begin(assetID: asset.id, from: .years, to: .months,
                      gridSource: nil, session: session, reduceMotion: false)
        XCTAssertEqual(window.subviews.filter { $0.tag == PhotoPeriodMotion.replicaTag }.count, 1)
        motion = nil
        try await Task.sleep(for: .seconds(1.8))
        XCTAssertTrue(window.subviews.allSatisfy { $0.tag != PhotoPeriodMotion.replicaTag },
                      "The window must not retain a photo after its period owner is released")
        XCTAssertEqual(cover.alpha, 1)
        await session.logOut(reportRemoteFailure: false)
    }

    func testLegacyCollectionLayoutMigratesPreviewWithoutLosingCustomization() throws {
        let legacy = Data(#"{"sectionIDs":["albums","pinned"],"collapsedIDs":["people"],"pinnedIDs":["album:family"]}"#.utf8)
        let layout = CollectionsLayout.decode(legacy)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
        XCTAssertEqual(encoded["previewSize"] as? String, "large")
        XCTAssertEqual(layout.sections.first, .albums)
        XCTAssertEqual(layout.pinnedIDs, ["album:family"])
        XCTAssertTrue(layout.collapsed.contains(.people))
    }

    func testPreviewModeRoundTripsAndRemainsAccountScoped() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "photos-presentation-\(UUID())"))
        let store = CollectionsLayoutStore(defaults: defaults)
        for mode in ["small", "none"] {
            let layout = CollectionsLayout.decode(Data("{\"previewSize\":\"\(mode)\"}".utf8))
            store.save(layout, account: "one")
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load(account: "one"))) as? [String: Any])
            XCTAssertEqual(encoded["previewSize"] as? String, mode)
        }
        let other = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load(account: "two"))) as? [String: Any])
        XCTAssertEqual(other["previewSize"] as? String, "large")
        store.save(CollectionsLayout.decode(Data(#"{"previewSize":"none"}"#.utf8)), account: nil)
        let signedOut = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load(account: nil))) as? [String: Any])
        XCTAssertEqual(signedOut["previewSize"] as? String, "large")
    }

    func testUnknownPreviewModeRecoversWithoutDiscardingPins() throws {
        let layout = CollectionsLayout.decode(Data(#"{"previewSize":"future","pinnedIDs":["album:family"]}"#.utf8))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
        XCTAssertEqual(encoded["previewSize"] as? String, "large")
        XCTAssertEqual(layout.pinnedIDs, ["album:family"])
    }
    func testPeriodDrillDownTargetsTheBucketOfItsVisibleCover() throws {
        let cover = Asset(id: "visible-photo", ownerId: "fixture", isImage: true, isFavorite: false,
                          isTrashed: false, visibility: .timeline, thumbhash: nil,
                          fileCreatedAt: Date(timeIntervalSince1970: 1_735_689_600), localOffsetHours: 0,
                          duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        let sections = [
            TimelineSection(id: "2025-02-01T00:00:00.000Z", monthTitle: "February", count: 10, days: nil),
            TimelineSection(id: "2025-01-01T00:00:00.000Z", monthTitle: "January", count: 1,
                            days: [DayGroup(id: "day", title: "day", assets: [cover])])
        ]
        let year = try XCTUnwrap(PhotoPeriod.years(in: sections).first)
        XCTAssertEqual(year.cover?.id, "visible-photo")
        XCTAssertEqual(year.representativeBucketID, "2025-01-01T00:00:00.000Z",
                       "A year must drill toward the photo it actually displays, even while a newer bucket is unloaded")
    }

    func testBackupDisplayPreferenceSurvivesRelaunchWithoutCrossingAccounts() throws {
        let name = "backup-presentation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PhotosVisualPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.load(account: "one").showsAllBackupStatuses)
        store.save(PhotosVisualPreferences(showsAllBackupStatuses: true), account: "one")
        XCTAssertTrue(PhotosVisualPreferencesStore(defaults: defaults).load(account: "one").showsAllBackupStatuses)
        XCTAssertFalse(store.load(account: "two").showsAllBackupStatuses)
        store.save(PhotosVisualPreferences(showsAllBackupStatuses: true), account: nil)
        XCTAssertFalse(store.load(account: nil).showsAllBackupStatuses)
    }

    func testLastPeriodRevealWinsWhileRetainingExactPhotoIdentity() {
        let controls = PhotosGridControls()
        controls.mode = .months
        controls.reveal(bucketID: "january", assetID: "photo-one")
        let oldRequest = controls.scrollRequest
        controls.mode = .years
        controls.reveal(bucketID: "february", assetID: "photo-two")
        XCTAssertNotEqual(controls.scrollRequest, oldRequest)
        XCTAssertEqual(controls.scrollRequest?.assetID, "photo-two")
        XCTAssertEqual(controls.scrollRequest?.bucketID, "february")
        XCTAssertEqual(controls.mode, .all)
    }

    func testPreferredAnchorIsTheSamePhotoAcrossYearAndMonthCovers() throws {
        func photo(_ id: String) -> Asset {
            Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false,
                  isTrashed: false, visibility: .timeline, thumbhash: nil,
                  fileCreatedAt: Date(timeIntervalSince1970: 1_735_689_600), localOffsetHours: 0,
                  duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil, createdAt: nil)
        }
        let sections = [TimelineSection(id: "2025-01-01T00:00:00.000Z", monthTitle: "January", count: 2,
                                        days: [DayGroup(id: "day", title: "day", assets: [photo("first"), photo("anchor")])])]
        XCTAssertEqual(PhotoPeriod.years(in: sections, preferredAssetID: "anchor").first?.cover?.id, "anchor")
        XCTAssertEqual(PhotoPeriod.months(in: sections, preferredAssetID: "anchor").first?.cover?.id, "anchor")
        XCTAssertEqual(PhotoPeriod.months(in: sections, preferredAssetID: "removed").first?.cover?.id, "first")
    }

    func testInterruptedPeriodGeometryRestoresBothSurfacesAndRemovesReplica() async throws {
        let (session, server, asset) = try await periodFixture()
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let year = PeriodPhotoImageView(frame: .zero), month = PeriodPhotoImageView(frame: .zero)
        year.frame = CGRect(x: 16, y: 100, width: 330, height: 224)
        month.frame = CGRect(x: 16, y: 360, width: 330, height: 224)
        host.view.addSubview(year); host.view.addSubview(month)
        let originalCount = window.subviews.count
        let motion = PhotoPeriodMotion()
        year.configure(asset: asset, mode: .years, session: session, motion: motion, targetPixelSize: 1024)
        month.configure(asset: asset, mode: .months, session: session, motion: motion, targetPixelSize: 1024)
        for _ in 0..<200 {
            if year.preparedSurfaceForMotion() != nil, month.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(year.preparedSurfaceForMotion()); XCTAssertNotNil(month.preparedSurfaceForMotion())
        motion.begin(assetID: asset.id, from: .years, to: .months, gridSource: nil, session: session, reduceMotion: false)
        let first = try XCTUnwrap(motion.transitionID)
        // Both fixture views are already mounted. Supply the same arrival
        // event that a newly mounted destination sends in the real screen.
        motion.arrive(at: month, mode: .months)
        XCTAssertEqual(year.alpha, 0)
        XCTAssertEqual(month.alpha, 0)
        XCTAssertEqual(window.subviews.count, originalCount + 1)
        motion.begin(assetID: asset.id, from: .months, to: .years, gridSource: nil, session: session, reduceMotion: false)
        XCTAssertNotEqual(motion.transitionID, first)
        motion.cancel()
        XCTAssertEqual(year.alpha, 1)
        XCTAssertEqual(month.alpha, 1)
        XCTAssertNil(motion.transitionID)
        XCTAssertEqual(window.subviews.count, originalCount)
        motion.begin(assetID: asset.id, from: .years, to: .months, gridSource: nil, session: session, reduceMotion: true)
        XCTAssertNil(motion.transitionID)
        XCTAssertEqual(year.alpha, 1)
        XCTAssertEqual(month.alpha, 1)
        XCTAssertEqual(window.subviews.count, originalCount)
        await session.logOut(reportRemoteFailure: false)
    }

}
