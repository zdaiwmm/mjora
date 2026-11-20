import Foundation
import XCTest

/// Exercises only the task-owned loopback library and its isolated simulator.
@MainActor
final class GalleryPerformanceFlowTests: XCTestCase {
    private var dismissedPasswordPrompt = false

    private func dismissSyntheticPasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [springboard, app] {
            for label in ["Not Now", "Later", "以后", "稍后"] {
                let button = host.buttons[label]
                if button.exists, button.isHittable {
                    let evidence = XCTAttachment(screenshot: host.screenshot())
                    evidence.name = "synthetic-system-password-prompt"; evidence.lifetime = .keepAlways; add(evidence)
                    button.tap()
                    dismissedPasswordPrompt = true
                    return
                }
            }
        }
    }

    private func launch() async throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "AC2E8884-A59A-437D-854C-589335E31468" else {
            throw XCTSkip("Requires the isolated 12,000-photo performance fixture")
        }
        continueAfterFailure = false
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:44317/control/status")!)
        let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard fixture?["ownerID"] as? String == "cd542ec0-405c-423d-9535-cef6923f6b61",
              fixture?["count"] as? Int == 12_000 else {
            throw NSError(domain: "Unowned performance fixture", code: 1)
        }
        addUIInterruptionMonitor(withDescription: "Synthetic password saving") { alert in
            for label in ["Not Now", "Later", "以后", "稍后"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        let app = XCUIApplication()
        dismissedPasswordPrompt = false
        var performedLogin = false
        app.launchEnvironment["IMORA_FRAME_TRACE"] = "1"
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "1"
        app.launchEnvironment["IMORA_VIEWER_SPANS"] = ProcessInfo.processInfo.environment["IMORA_VIEWER_SPANS"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-imora.photos.resourceFilter", "cloud",
                               "-imora.backupEnabled", "NO"]
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 3) {
            performedLogin = true
            app.textFields["auth-server"].tap()
            app.textFields["auth-server"].typeText("http://127.0.0.1:44317/api")
            app.buttons["auth-continue"].tap()
            let email = app.textFields["auth-email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15)); email.tap()
            email.typeText("performance@imora-performance-fixture.invalid")
            app.secureTextFields["auth-password"].tap()
            app.secureTextFields["auth-password"].typeText("synthetic-performance-only")
            app.buttons["auth-sign-in"].tap()
        }
        let ready = NSPredicate { _, _ in
            self.dismissSyntheticPasswordPrompt(app)
            return app.buttons["photos-source-menu"].isHittable && app.buttons["photos-sort-filter"].isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed)
        XCTAssertTrue(app.buttons.matching(identifier: "asset-tile").firstMatch.waitForExistence(timeout: 30))
        let pixels = NSPredicate { _, _ in
            app.scrollViews.matching(identifier: "phase4-launch-grid-probe").allElementsBoundByIndex.contains { probe in
                guard let value = probe.value as? String, let data = value.data(using: .utf8),
                      let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let latest = summary["latest"] as? [String: Any], latest["galleryVisible"] as? Bool == true,
                      let tiles = latest["tiles"] as? [[String: Any]] else { return false }
                return tiles.contains { $0["realBitmap"] as? Bool == true && $0["adequatePixels"] as? Bool == true }
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pixels, object: nil)], timeout: 20), .completed,
                       "Interaction starts from current prepared image pixels")
        if performedLogin, !dismissedPasswordPrompt {
            let offeredPasswordPrompt = NSPredicate { _, _ in
                self.dismissSyntheticPasswordPrompt(app)
                return self.dismissedPasswordPrompt
            }
            // The system may offer password saving after the first real photo.
            // Absence is valid when AutoFill is disabled on this owned simulator.
            _ = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: offeredPasswordPrompt, object: nil)], timeout: 10)
        }
        dismissSyntheticPasswordPrompt(app)
        capture(app, "performance-input-ready")
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testWidePinchContractsAcrossPhotosChrome() async throws {
        let app = try await launch()
        defer { app.terminate() }
        let tiles = app.buttons.matching(identifier: "asset-tile")
        func tileWidth() throws -> CGFloat {
            try XCTUnwrap(tiles.allElementsBoundByIndex.filter {
                $0.isHittable && (220...580).contains($0.frame.midY)
            }.map { $0.frame.width }.max())
        }
        let originalWidth = try tileWidth()
        app.pinch(withScale: 1.87, velocity: 0.43)
        let expandedWidth = try tileWidth()
        XCTAssertGreaterThan(expandedWidth, originalWidth + 10)
        app.pinch(withScale: 0.34, velocity: -0.46)
        XCTAssertLessThan(try tileWidth(), expandedWidth - 10,
                          "A wide inward pinch must shrink the grid even when a touch starts over its chrome")
        XCTAssertFalse(app.buttons["viewer-close"].exists)
    }

    func testLongLibraryScrollPinchPeriodsViewerAndCollections() async throws {
        let app = try await launch()
        defer { app.terminate() }
        XCTAssertEqual(app.buttons["photos-source-menu"].label, "Cloud Library")
        for _ in 0..<3 { dismissSyntheticPasswordPrompt(app); app.swipeUp(velocity: .fast) }
        for _ in 0..<3 { dismissSyntheticPasswordPrompt(app); app.swipeDown(velocity: .fast) }
        let tiles = app.buttons.matching(identifier: "asset-tile")
        func visibleTile() throws -> XCUIElement {
            dismissSyntheticPasswordPrompt(app)
            let tile = tiles.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.midY > 220 && $0.frame.midY < 580
            }
            if tile == nil {
                capture(app, "performance-no-hittable-photo")
                let hierarchy = XCTAttachment(string: app.debugDescription + "\nSPRINGBOARD\n"
                    + XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
                hierarchy.name = "performance-input-obstruction"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
            return try XCTUnwrap(tile)
        }
        try visibleTile().pinch(withScale: 0.6, velocity: -1)
        try visibleTile().pinch(withScale: 1.8, velocity: 1)
        XCTAssertFalse(app.buttons["viewer-close"].exists, "Lifting a pinch must leave the gallery visible")
        capture(app, "performance-pinch")
        let visible = try XCTUnwrap(tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 220 && $0.frame.midY < 580
        })
        visible.tap()
        XCTAssertTrue(app.buttons["viewer-close"].firstMatch.waitForExistence(timeout: 2))
        let strip = app.descendants(matching: .any)["viewer-carousel"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 2))
        let viewer = app.descendants(matching: .any)["asset-viewer"].firstMatch
        let initialID = viewer.value as? String
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85)).press(forDuration: 0.1,
            thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.85)))
        XCTAssertNotEqual(viewer.value as? String, initialID, "The visible strip must scrub the real pager")
        capture(app, "performance-viewer")
        let selectedAfterScrub = viewer.value as? String
        let information = app.buttons["viewer-info"].firstMatch
        XCTAssertTrue(information.waitForExistence(timeout: 3)); information.tap()
        XCTAssertTrue(app.descendants(matching: .any)["asset-details"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "performance-viewer-information")
        information.tap()
        let edit = app.buttons["viewer-edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3)); edit.tap()
        let cancelEdit = app.buttons["edit-cancel"].firstMatch
        XCTAssertTrue(cancelEdit.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["edit-more"].firstMatch.waitForExistence(timeout: 15))
        capture(app, "performance-viewer-editor")
        cancelEdit.tap()
        XCTAssertTrue(cancelEdit.waitForNonExistence(timeout: 5))
        XCTAssertEqual(viewer.value as? String, selectedAfterScrub)
        app.buttons["viewer-close"].firstMatch.tap()
        app.swipeDown()
        let picker = app.segmentedControls["photos-period-picker"]
        if !picker.exists { app.swipeDown() }
        if picker.waitForExistence(timeout: 5) {
            for title in ["Years", "Months", "All"] {
                let segment = picker.buttons[title]
                segment.tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in segment.isSelected }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed,
                               "The native date picker must highlight \(title) after a tap")
                let chromeReady = NSPredicate { _, _ in
                    guard picker.isHittable else { return false }
                    let sort = app.buttons["photos-sort-filter"]
                    let source = app.buttons["photos-source-menu"]
                    let periods = app.scrollViews.matching(identifier: "photos-periods")
                    return title == "All" ? sort.isHittable && source.isHittable && periods.count == 0
                        : !sort.isHittable && !source.isHittable && periods.count == 1
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: chromeReady, object: nil)], timeout: 4),
                               .completed, "The period page and toolbar must hand off while retaining the picker")
                capture(app, "performance-period-" + title)
            }
        } else { XCTFail("Period controls must be reachable in a long library") }
        if app.buttons["photos-show-navigation"].exists { app.buttons["photos-show-navigation"].tap() }
        app.buttons["shell-albums"].tap()
        XCTAssertTrue(app.scrollViews["collections-home"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Collection 1"].waitForExistence(timeout: 10))
        capture(app, "performance-collections")
        app.swipeUp(); app.swipeDown()
        app.buttons["shell-photos"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 2))
    }

    func testPreparedPhotoViewerOpenProfile() async throws {
        let app = try await launch()
        defer { app.terminate() }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:44317/control/viewer-profile-ready")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        // Profiler attachment settles before any measured opening begins.
        if ProcessInfo.processInfo.environment["IMORA_VIEWER_PROFILE_ATTACH"] != "0" {
            try await Task.sleep(for: .seconds(30))
        }
        let iterations = Int(ProcessInfo.processInfo.environment["IMORA_VIEWER_PROFILE_ITERATIONS"] ?? "") ?? 5
        XCTAssertTrue((1...5).contains(iterations))
        for iteration in 0..<iterations {
            var frame: CGRect?
            var sourceID: String?
            let preparedPhoto = NSPredicate { _, _ in
                for probe in app.scrollViews.matching(identifier: "phase4-launch-grid-probe").allElementsBoundByIndex {
                    guard let text = probe.value as? String, let data = text.data(using: .utf8),
                          let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let latest = summary["latest"] as? [String: Any],
                          latest["galleryVisible"] as? Bool == true,
                          let observed = latest["tiles"] as? [[String: Any]] else { continue }
                    let candidates = observed.compactMap { tile -> (CGRect, String)? in
                        guard tile["realBitmap"] as? Bool == true, tile["adequatePixels"] as? Bool == true,
                              let rect = tile["rect"] as? [Double], rect.count == 4,
                              let id = tile["assetID"] as? String else { return nil }
                        let rectFrame = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                        return rectFrame.midY > 220 && rectFrame.midY < 580 ? (rectFrame, id) : nil
                    }.sorted { lhs, rhs in
                        lhs.0.minY == rhs.0.minY ? lhs.0.minX < rhs.0.minX : lhs.0.minY < rhs.0.minY
                    }
                    frame = candidates.first?.0
                    sourceID = candidates.first?.1
                    if frame != nil { return true }
                }
                return false
            }
            let readiness = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: preparedPhoto, object: nil)], timeout: 15)
            XCTAssertEqual(readiness, .completed)
            let source = try XCTUnwrap(frame)
            print("VIEWER_PROFILE_OPEN \(iteration) \(sourceID ?? "unknown") \(Date().timeIntervalSince1970)")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: source.midX, dy: source.midY)).tap()
            let close = app.buttons["viewer-close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 2))
            XCTAssertTrue(app.descendants(matching: .any)["viewer-carousel"].firstMatch.waitForExistence(timeout: 2))
            for control in ["viewer-menu", "viewer-share", "viewer-favorite", "viewer-info", "viewer-edit"] {
                XCTAssertTrue(app.buttons[control].firstMatch.exists, "Real viewer control must remain mounted: \(control)")
            }
            capture(app, "viewer-profile-open-\(iteration)")
            close.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "asset-tile").firstMatch.waitForExistence(timeout: 10))
        }
    }

    func testVideoTransportAndFilmstripMountTogetherOnOpening() async throws {
        let app = try await launch()
        defer { app.terminate() }
        app.buttons["photos-sort-filter"].tap()
        let mediaTypes = app.buttons["Media Types"]
        XCTAssertTrue(mediaTypes.waitForExistence(timeout: 5)); mediaTypes.tap()
        let videos = app.buttons["Videos"]
        XCTAssertTrue(videos.waitForExistence(timeout: 5)); videos.tap()
        let video = app.buttons.matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 20)); video.tap()
        XCTAssertTrue(app.buttons["viewer-close"].firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(app.descendants(matching: .any)["video-controls"].firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(app.descendants(matching: .any)["viewer-carousel"].firstMatch.waitForExistence(timeout: 1))
        capture(app, "performance-video-opening-controls")
        let playPause = app.buttons["video-play-pause"].firstMatch
        let scrubber = app.descendants(matching: .any)["video-scrubber"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        func waitForVideo(_ condition: @escaping () -> Bool) async {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        func seek(to fraction: CGFloat) {
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)))
        }
        await waitForVideo { (scrubber.value as? String)?.hasSuffix(" / 0:03") == true }
        if playPause.label == "Pause" { playPause.tap() }
        await waitForVideo { playPause.label == "Play" }
        seek(to: 0.02)
        await waitForVideo { (scrubber.value as? String)?.hasPrefix("0:00 / ") == true }
        playPause.tap()
        await waitForVideo { playPause.label == "Pause" }
        playPause.tap()
        await waitForVideo { playPause.label == "Play" }
        XCTAssertFalse((scrubber.value as? String)?.hasPrefix("0:03 / ") == true,
                       "Pause must stop playback before the clip ends naturally")
        seek(to: 0.02)
        await waitForVideo { (scrubber.value as? String)?.hasPrefix("0:00 / ") == true }
        capture(app, "performance-video-seek-start")
        seek(to: 0.75)
        await waitForVideo { (scrubber.value as? String)?.hasPrefix("0:02 / ") == true }
        XCTAssertEqual(playPause.label, "Play", "Seeking a paused video must keep it paused")
        capture(app, "performance-video-seek-two-seconds")
        app.buttons["viewer-close"].firstMatch.tap()
    }
}
