import Foundation
import XCTest

/// The runner and loopback service must both identify this task's synthetic run.
@MainActor
final class S0SearchFlowTests: XCTestCase {
    private struct Fixture: Decodable {
        let version: Int
        let runID: String
        let simulatorUDID: String
        let apiURL: String
        let email: String
        let password: String
        let ownerID: String
        let filenames: [String]

        static func load() throws -> Self {
            let expectedSimulator = "4E132CEA-B752-4CA6-8365-BF595B32A390"
            guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == expectedSimulator else {
                throw XCTSkip("S0 uses its separately allocated synthetic simulator.")
            }
            let url = URL(fileURLWithPath: "/Users/achilles/mjora/execution/batch2-stage1-20261118/search/ui-fixture.json")
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            guard url.resolvingSymlinksInPath().path == url.path, mode?.intValue == 0o600 else {
                throw NSError(domain: "Unowned S0 manifest", code: 1)
            }
            let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard fixture.version == 1, fixture.runID == "batch2-s0-20261118",
                  fixture.simulatorUDID == expectedSimulator,
                  fixture.apiURL == "http://127.0.0.1:43927/api",
                  fixture.email.hasSuffix("@imora-batch2-fixture.invalid"),
                  UUID(uuidString: fixture.ownerID) != nil,
                  !fixture.password.isEmpty, !fixture.filenames.isEmpty,
                  fixture.filenames.allSatisfy({ $0.hasPrefix("S0_Synthetic_") }) else {
                throw NSError(domain: "Unowned S0 destination", code: 1)
            }
            return fixture
        }
    }

    func testCloudDefaultAndExplicitDeviceFilenameSearch() async throws {
        continueAfterFailure = false
        let fixture = try Fixture.load()
        let status = try await control("status")
        guard status["runID"] as? String == fixture.runID, status["ownerID"] as? String == fixture.ownerID else {
            throw NSError(domain: "Unowned S0 service", code: 1)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        signIn(app, fixture: fixture)
        selectDevice(app)
        tap(app, "photos-search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertEqual(field.placeholderValue, "Search Cloud Photos")
        XCTAssertFalse(app.buttons["search-source"].exists)
        let initialCloudCount = try await cloudProbeRequests()
        field.tap(); field.typeText("S0_cloud_probe\n")
        var cloudCount = initialCloudCount
        for _ in 0..<50 where cloudCount <= initialCloudCount {
            try await Task.sleep(for: .milliseconds(100))
            cloudCount = try await cloudProbeRequests()
        }
        XCTAssertGreaterThan(cloudCount, initialCloudCount, "The regular search must reach the synthetic cloud API")
        capture(app, "s0-regular-search-cloud")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        selectDevice(app)
        tap(app, "photos-source-menu")
        tapMenuItem(app, "Search On Device")
        let source = app.buttons["search-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertEqual(source.value as? String, "On Device")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.placeholderValue, "Search On Device")
        // Let already-issued gallery work settle before measuring only the
        // explicit local query. The service records every search request.
        try await Task.sleep(for: .milliseconds(500))
        let beforeLocal = try await searchRequests()
        field.tap(); field.typeText(fixture.filenames[0] + "\n")
        waitUntil("One synthetic filename result") { self.visibleTiles(app).count == 1 }
        XCTAssertTrue(app.descendants(matching: .any)["local-search-results"].exists)
        let afterLocal = try await searchRequests()
        XCTAssertEqual(afterLocal, beforeLocal, "Local matching must not issue cloud search requests")
        capture(app, "s0-explicit-device-result")
        try XCTUnwrap(visibleTiles(app).first).tap()
        let close = app.buttons["viewer-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15)); close.tap()
        waitUntil("Return to the same local result") { self.visibleTiles(app).count == 1 }
        capture(app, "s0-device-viewer-return")
        signOutFixture(app)
    }

    private func control(_ name: String) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:43927/control/\(name)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Invalid S0 service response", code: 1)
        }
        return value
    }

    private func searchRequests() async throws -> Int {
        let value = try await control("counters")
        return try XCTUnwrap(value["searchRequests"] as? Int)
    }

    private func cloudProbeRequests() async throws -> Int {
        let value = try await control("counters")
        return try XCTUnwrap(value["cloudProbeRequests"] as? Int)
    }

    private func signIn(_ app: XCUIApplication, fixture: Fixture) {
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 4) {
            server.tap(); server.typeText(fixture.apiURL)
            app.buttons["auth-continue"].tap()
            let email = app.textFields["auth-email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15))
            email.tap(); email.typeText(fixture.email)
            let password = app.secureTextFields["auth-password"]
            password.tap(); password.typeText(fixture.password)
            app.buttons["auth-sign-in"].tap()
        }
        waitUntil("Synthetic signed-in Library", timeout: 30) {
            self.dismissKnownPrompt(app)
            return app.buttons["photos-source-menu"].isHittable
        }
    }

    private func selectDevice(_ app: XCUIApplication) {
        tap(app, "photos-source-menu")
        tapMenuItem(app, "On Device")
        var reselected = false
        waitUntil("Device Library") {
            self.dismissKnownPrompt(app)
            let item = self.menuItem(app, "On Device")
            let previousSourceStillSelected = ["All Sources", "Cloud"].contains { label in
                let previous = self.menuItem(app, label)
                return previous.exists && previous.isSelected
            }
            // A late password prompt can consume the first tap. Retry only
            // when the same foreground menu proves that selection did not land.
            if !reselected, previousSourceStillSelected, item.exists, item.isHittable {
                self.dismissKnownPrompt(app)
                if item.exists, item.isHittable {
                    reselected = true
                    item.tap()
                }
            }
            let headerReady = app.buttons.matching(identifier: "photos-source-menu").allElementsBoundByIndex.contains {
                $0.isHittable && $0.label == "On Device"
            }
            return headerReady && !(item.exists && item.isHittable)
        }
    }

    private func signOutFixture(_ app: XCUIApplication) {
        // Relaunch returns to Library even when Search uses the native tab bar.
        // Run this only after the successful flow, never from failure teardown.
        app.terminate(); app.launch()
        waitUntil("Library before synthetic sign-out") {
            self.dismissKnownPrompt(app)
            return app.buttons["photos-source-menu"].isHittable
        }
        tap(app, "photos-source-menu")
        tapMenuItem(app, "Account & Settings")
        let signOut = app.buttons["settings-sign-out"].firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !signOut.exists || !signOut.isHittable {
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        tap(app, "settings-sign-out")
        tap(app, "settings-confirm-sign-out")
        waitUntil("Synthetic account signed out") { app.textFields["auth-server"].exists }
        capture(app, "s0-synthetic-account-signed-out")
    }

    private func tap(_ app: XCUIApplication, _ identifier: String) {
        dismissKnownPrompt(app)
        let matches = app.buttons.matching(identifier: identifier)
        waitUntil(identifier) {
            self.dismissKnownPrompt(app)
            return matches.allElementsBoundByIndex.contains(where: \.isHittable)
        }
        guard let button = matches.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("The requested control lost its hit point before the tap: \(identifier)")
            return
        }
        button.tap()
    }

    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, "photos-source-menu")).firstMatch
    }

    private func tapMenuItem(_ app: XCUIApplication, _ label: String) {
        let item = menuItem(app, label)
        dismissKnownPrompt(app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The menu item must exist: \(label)")
        waitUntil("Menu item " + label) {
            self.dismissKnownPrompt(app)
            return item.exists && item.isHittable
        }
        dismissKnownPrompt(app)
        XCTAssertTrue(item.exists && item.isHittable, "The menu item must remain tappable: \(label)")
        item.tap()
    }

    private func dismissKnownPrompt(_ app: XCUIApplication) {
        for surface in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            for label in ["Not Now", "Later", "以后"] {
                let button = surface.buttons[label]
                if button.exists, button.isHittable { button.tap(); return }
            }
        }
    }

    private func visibleTiles(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.midY > 100 && $0.frame.midY < app.frame.height - 80
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 20, _ predicate: @escaping () -> Bool) {
        let ready = NSPredicate { _, _ in predicate() }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout)
        if result != .completed { capture(XCUIApplication(), "s0-failed-" + description) }
        XCTAssertEqual(result, .completed, description)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
