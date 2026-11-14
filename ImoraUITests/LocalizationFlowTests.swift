import Foundation
import XCTest

@MainActor
final class LocalizationFlowTests: XCTestCase {
    private struct Fixture: Decodable { let apiURL: String; let email: String; let password: String }
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: "/private/tmp/imora-341-ios-fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the dedicated local fixture first.") }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard value.apiURL == "http://127.0.0.1:32283/api", value.email.hasSuffix("@imora-fixture.invalid") else {
            throw NSError(domain: "Unsafe fixture destination", code: 1)
        }
        return value
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func tap(_ app: XCUIApplication, _ id: String) {
        let element = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        element.tap()
    }
    private func enter(_ value: String, in field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        // Keyboard presentation can reposition the form during a locale change.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        field.tap()
        field.typeText(value)
    }
    private func tapViewerClose(_ app: XCUIApplication) {
        // The temporary opening overlay is removed as the toolbar appears.
        // Resolve the stable toolbar action after handoff, since an indexed
        // overlay element can disappear between AX selection and touch delivery.
        let toolbarClose = app.navigationBars.buttons.matching(identifier: "viewer-close")
        let ready = NSPredicate { _, _ in
            toolbarClose.count == 1 && toolbarClose.firstMatch.isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 8), .completed)
        let controls = app.buttons.matching(identifier: "viewer-close").allElementsBoundByIndex
            .map { "frame=\($0.frame) hittable=\($0.isHittable)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: controls)
        attachment.name = "viewer-close-before-tap"; attachment.lifetime = .keepAlways; add(attachment)
        toolbarClose.firstMatch.tap()
    }
    private func checkFlow(language: String, chinese: Bool) throws {
        continueAfterFailure = false
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", chinese ? "zh_CN" : "en_US"]
        app.launch()
        let server = app.textFields["auth-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 20), "A fresh signed-out fixture session is required")
        XCTAssertTrue(app.staticTexts[chinese ? "连接到您的 Imora 服务器" : "Connect to your Imora server"].exists)
        snapshot(app, "\(language)-login")
        enter(fixture.apiURL, in: server, app: app)
        app.buttons["auth-continue"].tap()
        let email = app.textFields["auth-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        enter(fixture.email, in: email, app: app)
        let password = app.secureTextFields["auth-password"]
        enter(fixture.password, in: password, app: app)
        app.buttons["auth-sign-in"].tap()
        XCTAssertTrue(app.buttons["profile-avatar"].waitForExistence(timeout: 25))
        snapshot(app, "\(language)-photos")
        app.buttons["profile-avatar"].tap()
        tap(app, "settings-app-updates")
        XCTAssertTrue(app.staticTexts[chinese ? "App 版本" : "App Version"].waitForExistence(timeout: 10))
        let version = app.descendants(matching: .any)["app-updates-installed-version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertTrue(version.label.contains("1.0.2"), version.label)
        XCTAssertTrue(app.descendants(matching: .any)["app-updates-installed-build"].firstMatch.label.contains("4"))
        XCTAssertTrue(app.staticTexts[chinese ? "未配置无线更新" : "Wireless Updates Not Configured"].exists)
        XCTAssertFalse(app.buttons["app-updates-install"].exists)
        snapshot(app, "\(language)-app-updates")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings-close"].tap()
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
        for (step, index) in [0, 1, 0, 1, 0].enumerated() {
            tiles.element(boundBy: index).tap()
            let close = app.buttons.matching(identifier: "viewer-close").firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 8), "A different asset must open after returning from the viewer")
            if step == 2 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
                XCTAssertTrue(close.waitForExistence(timeout: 8))
                tapViewerClose(app)
            } else if step == 3 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            } else {
                tapViewerClose(app)
            }
            XCTAssertTrue(close.waitForNonExistence(timeout: 8), "Returning must actually detach the fullscreen viewer")
            XCTAssertTrue(app.buttons["profile-avatar"].waitForExistence(timeout: 8))
            XCTAssertTrue(tiles.element(boundBy: (index + 1) % 2).isHittable)
        }
        app.buttons["profile-avatar"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "设置" : "Settings"].waitForExistence(timeout: 10))
        snapshot(app, "\(language)-settings")
        tap(app, "settings-privacy")
        XCTAssertTrue(app.switches["privacy-apple-maps"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["privacy-apple-maps"].value as? String, "0")
        snapshot(app, "\(language)-privacy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "settings-backup")
        XCTAssertTrue(app.switches["backup-auto-toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["backup-advanced"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["backup-cleanup"].exists)
        snapshot(app, "\(language)-backup-simple")
        tap(app, "backup-advanced")
        XCTAssertTrue(app.buttons["server-route-use-local"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["server-route-use-local"].label, chinese ? "立即使用局域网地址" : "Use Local Now")
        XCTAssertEqual(app.buttons["server-route-use-external"].label, chinese ? "使用外网地址" : "Use External Address")
        XCTAssertTrue(app.staticTexts["server-route-endpoint"].label.contains("127.0.0.1:32283"))
        snapshot(app, "\(language)-backup-advanced")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "backup-cleanup")
        XCTAssertTrue(app.descendants(matching: .any)["cleanup-retention-days"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["cleanup-keep-favorites"].exists)
        snapshot(app, "\(language)-cleanup-retention")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "settings-local-network")
        XCTAssertTrue(app.buttons["server-route-use-local"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["server-route-use-local"].label, chinese ? "立即使用局域网地址" : "Use Local Now")
        snapshot(app, "\(language)-local-network")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "settings-sign-out")
        let confirmation = app.buttons.matching(identifier: "settings-confirm-sign-out").allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(confirmation)
        confirmation?.tap()
        XCTAssertTrue(app.textFields["auth-server"].waitForExistence(timeout: 20))
        app.terminate()
    }
    func testChineseScreensUseShippedResources() throws { try checkFlow(language: "zh-Hans", chinese: true) }
    func testEnglishScreensRemainAvailable() throws { try checkFlow(language: "en", chinese: false) }

    /// Run against a test product enrolled with the existing Mac update host.
    /// Public source builds have no private host configuration and skip this case.
    func testManualCurrentVersionCheckShowsChineseToastOnEveryTap() throws {
        continueAfterFailure = false
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 5) {
            enter(fixture.apiURL, in: server, app: app)
            app.buttons["auth-continue"].tap()
            enter(fixture.email, in: app.textFields["auth-email"], app: app)
            enter(fixture.password, in: app.secureTextFields["auth-password"], app: app)
            app.buttons["auth-sign-in"].tap()
        }
        XCTAssertTrue(app.buttons["profile-avatar"].waitForExistence(timeout: 25))
        app.buttons["profile-avatar"].tap()
        tap(app, "settings-app-updates")
        let check = app.buttons["app-updates-check"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        guard check.isEnabled else { throw XCTSkip("Enroll the private test product with the Mac update host first.") }
        let toast = app.descendants(matching: .any)["information-toast"].firstMatch
        XCTAssertFalse(toast.exists, "Opening About must not announce a manual check")
        for index in 0..<2 {
            check.tap()
            XCTAssertTrue(toast.waitForExistence(timeout: 15))
            XCTAssertEqual(toast.value as? String, "当前已是最新版本")
            snapshot(app, "zh-Hans-current-version-toast-\(index)")
            XCTAssertTrue(toast.waitForNonExistence(timeout: 8))
        }
        app.terminate()
    }
}
