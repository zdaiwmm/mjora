import Foundation
import XCTest

/// Only the phase4-owned synthetic server. Cached restart never logs in or
/// primes, allowing root to pause that server while recording the framebuffer.
@MainActor
final class Phase4LaunchPresentationTests: XCTestCase {
    private struct Fixture: Decodable { let apiURL: String; let email: String; let password: String; let ownerID: String }
    private struct Tile: Decodable {
        let assetID: String; let rect: [Double]; let bitmapPixels: [Int]
        let requestedPixels: Int; let realBitmap: Bool; let adequatePixels: Bool
        let sourceRevision: String; let contentGeneration: String
    }
    private struct Frame: Decodable {
        let timestamp: Double; let tiles: [Tile]; let placeholderRows: Int
        let expectedW0: [String]; let expectedAnchor: String?; let restoredComplete: Bool; let interactive: Bool
        let serverIdentity: String?; let accountID: String?
        let applicationActive: Bool; let viewInteractionEnabled: Bool
        let galleryVisible: Bool; let loadingOverlayVisible: Bool; let reportedItemCount: Int
        var qualified: Bool { !tiles.isEmpty && placeholderRows == 0 && tiles.allSatisfy { $0.realBitmap && $0.adequatePixels } }
    }
    private struct Probe: Decodable {
        let traceID: String; let observationComplete: Bool; let first: Frame?; let latest: Frame; let firstInteractive: Frame?
        let checkpointAnchor: String?; let checkpointW0: [String]; let processToFirstContentMS: Double?
        let sampledFrames: Int; let incompleteFrames: Int
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4/ui-fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the owned phase4 synthetic fixture") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard fixture.apiURL == "http://127.0.0.1:33284/api", fixture.email.hasSuffix("@imora-phase4-fixture.invalid") else {
            throw NSError(domain: "Unsafe phase4 fixture", code: 1)
        }
        return fixture
    }

    private func application(trace: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = trace ? "1" : "0"
        return app
    }

    private func dismissPrompts(_ app: XCUIApplication) {
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "Later", "以后"])).firstMatch
        if later.exists && later.isHittable { later.tap() }
    }

    private func probe(_ app: XCUIApplication, timeout: TimeInterval = 45, matching: (Probe) -> Bool) throws -> (Probe, String) {
        let deadline = Date().addingTimeInterval(timeout)
        let element = app.scrollViews["phase4-launch-grid-probe"]
        while Date() < deadline {
            dismissPrompts(app)
            if let json = element.value as? String, let data = json.data(using: .utf8),
               let value = try? JSONDecoder().decode(Probe.self, from: data), matching(value) { return (value, json) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "phase4-probe-timeout"; image.lifetime = .keepAlways; add(image)
        var hierarchy = app.debugDescription
        if let owned = try? fixture() {
            hierarchy = hierarchy.replacingOccurrences(of: owned.email, with: "[synthetic email]")
                .replacingOccurrences(of: owned.password, with: "[synthetic password]")
        }
        let tree = XCTAttachment(string: hierarchy); tree.name = "phase4-probe-timeout-hierarchy"; tree.lifetime = .keepAlways; add(tree)
        if let latest = element.value as? String {
            let state = XCTAttachment(string: latest); state.name = "phase4-probe-timeout-state"; state.lifetime = .keepAlways; add(state)
        }
        throw NSError(domain: "Phase4 grid probe did not satisfy the actual-tile contract", code: 1)
    }

    private func attach(_ app: XCUIApplication, evidence: String, name: String) {
        let json = XCTAttachment(string: evidence); json.name = name + "-tiles-rects-revisions"; json.lifetime = .keepAlways; add(json)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name + "-framebuffer"; image.lifetime = .keepAlways; add(image)
    }

    func testPrimeCloudCompletePack() throws { try prime(source: "cloud", expectedCount: 120) }

    // 147 includes the120 imported synthetic originals and27 earlier native
    // provider fixtures. Actual public PhotoKit scan count is recorded by the app.
    func testPrimeDeviceCompletePack() throws { try prime(source: "local", expectedCount: 147) }

    private func prime(source: String, expectedCount: Int) throws {
        continueAfterFailure = false
        let fixture = try fixture(), app = application()
        app.launch()
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 3) {
            server.tap(); server.typeText(fixture.apiURL); app.buttons["auth-continue"].tap()
            XCTAssertTrue(app.textFields["auth-email"].waitForExistence(timeout: 20))
            app.textFields["auth-email"].tap(); app.textFields["auth-email"].typeText(fixture.email)
            app.secureTextFields["auth-password"].tap(); app.secureTextFields["auth-password"].typeText(fixture.password)
            app.buttons["auth-sign-in"].tap()
        }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 30))
        dismissPrompts(app)
        app.buttons["photos-source-menu"].tap()
        let identified = app.descendants(matching: .any)["photos-source-\(source)"].firstMatch
        let label = source == "local" ? "On Device" : "Cloud Photos"
        let option = identified.exists ? identified : app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        let grid = app.scrollViews["phase4-launch-grid-probe"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        if source == "local" {
            _ = try probe(app) { $0.latest.qualified && $0.latest.reportedItemCount == expectedCount }
            // Browse from the newer native-test fixtures into the120 imported
            // full-resolution JPEGs, preserving the actual147-item library.
            for _ in 0..<3 { grid.swipeDown() }
        } else { grid.swipeDown() }
        let (value, json) = try probe(app) { value in
            value.latest.qualified && value.latest.reportedItemCount == expectedCount && !value.checkpointW0.isEmpty
                && Set(value.checkpointW0) == Set(value.latest.tiles.map(\.assetID))
        }
        XCTAssertEqual(value.latest.serverIdentity, fixture.apiURL)
        XCTAssertEqual(value.latest.accountID, fixture.ownerID)
        XCTAssertEqual(value.checkpointAnchor, value.latest.tiles.first?.assetID)
        XCTAssertEqual(value.latest.reportedItemCount, expectedCount)
        if source == "local" {
            XCTAssertTrue(value.latest.tiles.allSatisfy { $0.bitmapPixels.count == 2 && $0.bitmapPixels[0] > $0.bitmapPixels[1] },
                "This local W0 must cover the imported landscape JPEGs, not the square native-test fixtures")
        }
        XCTAssertEqual(value.latest.tiles.allSatisfy { $0.assetID.hasPrefix("local-") }, source == "local")
        attach(app, evidence: json, name: "phase4-primed-\(source)-W0")
    }

    func testCachedCloudRestartKeepsFirstVisibleGridCompleteForTwoSeconds() throws {
        continueAfterFailure = false
        let fixture = try fixture(), app = application()
        app.terminate(); app.launch()
        XCTAssertFalse(app.textFields["auth-server"].exists, "This selector requires the persisted verified session; it never logs in")
        let (value, json) = try probe(app) { $0.observationComplete }
        try assertCached(value, fixture: fixture)
        attach(app, evidence: json, name: "phase4-cached-cloud-restart-two-seconds")
    }

    func testCachedDeviceRestartKeepsFirstVisibleGalleryCompleteForTwoSeconds() throws {
        continueAfterFailure = false
        let fixture = try fixture(), app = application()
        app.terminate(); app.launch()
        XCTAssertFalse(app.textFields["auth-server"].exists)
        let (value, json) = try probe(app) { $0.observationComplete }
        try assertCached(value, fixture: fixture, expectedCount: 147)
        XCTAssertTrue(try XCTUnwrap(value.first).tiles.allSatisfy { $0.assetID.hasPrefix("local-") })
        attach(app, evidence: json, name: "phase4-cached-device-restart-two-seconds")
    }

    /// Root runs this with the explicitly optimized PHASE4_PERFORMANCE build.
    /// XCTest records full responsive-launch metrics separately from App.init
    /// trace timestamps; every iteration still checks actual W0 for2seconds.
    func testMeasureThirtyCachedCloudResponsiveLaunchesAndActualW0() throws {
        try measureCached(source: "cloud", expectedCount: 120)
    }

    func testMeasureThirtyCachedDeviceResponsiveLaunchesAndActualW0() throws {
        try measureCached(source: "device", expectedCount: 147)
    }

    // Independent shipping-default controls: no diagnostic probe, video or
    // trace-derived readiness assertion. A real tap/dismiss checks input.
    func testMeasureThirtyCachedCloudResponsiveLaunchesWithoutTraceAndOpenPhoto() throws {
        try measureWithoutTrace(source: "cloud")
    }

    func testMeasureThirtyCachedDeviceResponsiveLaunchesWithoutTraceAndOpenPhoto() throws {
        try measureWithoutTrace(source: "device")
    }

    func testCachedDeviceWithoutTraceOpensPhotoAndReturnsToGallery() throws {
        _ = try fixture()
        let app = application(trace: false)
        app.terminate(); app.launch()
        try openPhotoAndReturn(app, source: "device")
    }

    private func measureWithoutTrace(source: String) throws {
        continueAfterFailure = false
        _ = try fixture()
        let options = XCTMeasureOptions(); options.iterationCount = 30
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = application(trace: false)
            app.terminate(); app.launch()
            do { try openPhotoAndReturn(app, source: source) }
            catch { XCTFail("Untraced cached \(source) launch could not open and dismiss a real photo: \(error)") }
            app.terminate()
        }
    }

    private func openPhotoAndReturn(_ app: XCUIApplication, source: String) throws {
        XCTAssertFalse(app.textFields["auth-server"].exists, "The control requires the same persisted verified session")
        XCTAssertFalse(app.scrollViews["phase4-launch-grid-probe"].exists, "The shipping-default control must not enable the launch observer")
        let menu = app.buttons["photos-source-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        let tile = try XCTUnwrap(tiles.allElementsBoundByIndex.first { $0.isHittable })
        let photoLabel = tile.label
        tile.tap()
        let viewer = app.descendants(matching: .any)["asset-viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "A real gallery tap must open the photo viewer")
        let assetID = try XCTUnwrap(viewer.value as? String)
        XCTAssertFalse(assetID.isEmpty)
        XCTAssertEqual(assetID.hasPrefix("local-"), source == "device", "The control must retain the chosen cached source")
        let close = app.buttons["viewer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(tiles.matching(NSPredicate(format: "label == %@", photoLabel)).firstMatch.waitForExistence(timeout: 10),
            "Dismissing the photo must return to the same gallery")
        XCTAssertFalse(viewer.exists, "The viewer must actually dismiss")
    }

    private func measureCached(source: String, expectedCount: Int) throws {
        continueAfterFailure = false
        let fixture = try fixture()
        let options = XCTMeasureOptions(); options.iterationCount = 30
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = application()
            app.terminate(); app.launch()
            do {
                let (value, json) = try probe(app) { $0.observationComplete }
                try assertCached(value, fixture: fixture, expectedCount: expectedCount)
                let first = try XCTUnwrap(value.first)
                XCTAssertEqual(first.tiles.allSatisfy { $0.assetID.hasPrefix("local-") }, source == "device")
                attach(app, evidence: json, name: "phase4-\(source)-launch-metric-\(value.traceID)")
            } catch { XCTFail("Cached \(source) responsive launch did not meet the actual-gallery contract") }
            app.terminate()
        }
    }

    private func assertCached(_ value: Probe, fixture: Fixture, expectedCount: Int = 120) throws {
        let first = try XCTUnwrap(value.first)
        XCTAssertEqual(first.serverIdentity, fixture.apiURL)
        XCTAssertEqual(first.accountID, fixture.ownerID)
        XCTAssertTrue(first.galleryVisible)
        XCTAssertFalse(first.loadingOverlayVisible, "The first visible gallery exposed loading")
        XCTAssertEqual(first.reportedItemCount, expectedCount, "The synthetic gallery must report its complete known total")
        XCTAssertEqual(value.latest.reportedItemCount, expectedCount)
        XCTAssertTrue(first.restoredComplete, "No complete authorized pack was restored")
        XCTAssertTrue(first.qualified, "The first actual mounted content frame contained missing/undersized bitmaps")
        XCTAssertEqual(Set(first.expectedW0), Set(first.tiles.map(\.assetID)))
        XCTAssertEqual(first.expectedAnchor, first.tiles.first?.assetID)
        XCTAssertTrue(first.viewInteractionEnabled, "The visible gallery must not disable its view or ancestors")
        let interactive = try XCTUnwrap(value.firstInteractive, "A complete active/interactive gallery was never observed")
        XCTAssertTrue(interactive.applicationActive && interactive.interactive && interactive.qualified)
        XCTAssertEqual(interactive.tiles.map(\.assetID), first.tiles.map(\.assetID))
        XCTAssertEqual(value.incompleteFrames, 0, "A later actual frame filled in or changed the restored W0")
        XCTAssertGreaterThan(value.sampledFrames, 1)
        XCTAssertTrue(value.latest.qualified)
        XCTAssertEqual(Set(first.tiles.map(\.assetID)), Set(value.latest.tiles.map(\.assetID)))
    }
}
