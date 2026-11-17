import XCTest

@MainActor
final class SettingsNavigationFlowTests: XCTestCase {
    func testChineseNativeSettingsFlow() throws { try checkFlow(language: "zh-Hans", chinese: true, appearance: "Light") }
    func testEnglishNativeSettingsFlow() throws { try checkFlow(language: "en", chinese: false, appearance: "Dark") }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let element = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        for _ in 0..<6 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        XCTAssertTrue(element.isHittable, id)
        element.tap()
    }

    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func checkFlow(language: String, chinese: Bool, appearance: String) throws {
        continueAfterFailure = false
        let fixture = try OwnedUIFixture.load()
        let app = XCUIApplication()
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", chinese ? "zh_CN" : "en_US",
                               "-AppleInterfaceStyle", appearance]
        app.launch()
        defer { app.terminate() }
        if app.textFields["auth-server"].waitForExistence(timeout: 3) {
            app.terminate()
            OwnedUIFixture.configure(app)
            app.launch()
        }
        guard app.buttons["photos-source-menu"].waitForExistence(timeout: 15) else {
            throw XCTSkip("The owned fixture needs a cached session or its local server on port 33284.")
        }
        let probe = app.scrollViews["phase4-launch-grid-probe"]
        let owned = NSPredicate { _, _ in
            guard let text = probe.value as? String, let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = value["latest"] as? [String: Any] else { return false }
            return latest["accountID"] as? String == fixture.ownerID
                && latest["serverIdentity"] as? String == fixture.apiURL
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: owned, object: nil)], timeout: 10) == .completed else {
            throw XCTSkip("No confirmed cached account belonging to the dedicated fixture.")
        }
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
        if later.waitForExistence(timeout: 2), later.isHittable { later.tap() }
        app.buttons["photos-source-menu"].tap()
        app.buttons[chinese ? "账号与设置" : "Account & Settings"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "设置" : "Settings"].waitForExistence(timeout: 10))
        capture(app, "\(language)-native-settings")

        tap(app, "settings-photo-preferences")
        XCTAssertTrue(app.switches[chinese ? "回忆" : "Memories"].waitForExistence(timeout: 10))
        capture(app, "\(language)-native-photo-preferences")
        back(app)
        tap(app, "settings-account")
        tap(app, "settings-privacy")
        XCTAssertTrue(app.switches["privacy-apple-maps"].waitForExistence(timeout: 10))
        back(app); back(app)

        tap(app, "settings-backup")
        XCTAssertTrue(app.switches["backup-auto-toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["backup-status"].firstMatch.exists)
        capture(app, "\(language)-native-backup")
        tap(app, "backup-content")
        XCTAssertTrue(app.switches["backup-include-screenshots-toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["backup-upload-size-limit-toggle"].exists)
        capture(app, "\(language)-native-backup-content")
        back(app)
        tap(app, "backup-conditions")
        XCTAssertTrue(app.switches["backup-cellular-toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["backup-low-battery-toggle"].exists)
        capture(app, "\(language)-native-backup-conditions")
        tap(app, "backup-background")
        XCTAssertTrue(app.buttons["backup-continue-background"].waitForExistence(timeout: 10))
        back(app); back(app)
        tap(app, "backup-advanced")
        XCTAssertTrue(app.descendants(matching: .any)["backup-hash-workers"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["server-route-mode"].firstMatch.exists)
        capture(app, "\(language)-native-backup-advanced")
        back(app)
        tap(app, "backup-cleanup")
        XCTAssertTrue(app.descendants(matching: .any)["cleanup-retention-days"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["cleanup-keep-favorites"].exists)
        capture(app, "\(language)-native-cleanup")
        back(app); back(app)

        tap(app, "settings-local-network")
        XCTAssertTrue(app.descendants(matching: .any)["server-route-mode"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "\(language)-native-local-network")
        tap(app, "local-network-address-settings")
        XCTAssertTrue(app.textFields["local-network-address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["local-network-save-address"].exists)
        capture(app, "\(language)-native-local-address")
        back(app)
        tap(app, "local-network-verification")
        XCTAssertTrue(app.descendants(matching: .any)["local-network-identity-state"].firstMatch.waitForExistence(timeout: 10))
        back(app)
        tap(app, "local-network-wifi-settings")
        XCTAssertTrue(app.buttons[chinese ? "添加当前网络" : "Add Current Network"].waitForExistence(timeout: 10))
        capture(app, "\(language)-native-local-wifi")
    }
}
