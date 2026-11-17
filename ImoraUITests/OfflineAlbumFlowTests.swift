import Foundation
import XCTest

@MainActor
final class OfflineAlbumFlowTests: XCTestCase {
    private var api: String { ProcessInfo.processInfo.environment["IMORA_OFFLINE_API"] ?? "http://127.0.0.1:43891/api" }
    private var simulator: String { ProcessInfo.processInfo.environment["IMORA_OFFLINE_SIMULATOR"] ?? "8F6070E7-63F5-4128-AD09-27518349CD0C" }
    private var controlRoot: URL { URL(string: api)!.deletingLastPathComponent().appending(path: "control") }

    override func setUp() {
        super.setUp()
        addUIInterruptionMonitor(withDescription: "Dismiss synthetic password saving") { alert in
            for label in ["以后", "Not Now", "Later"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func dismissPasswordPrompt(_ app: XCUIApplication) {
        for surface in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            for label in ["以后", "Not Now", "Later"] {
                let button = surface.buttons[label]
                if button.exists, button.isHittable { button.tap(); return }
            }
        }
    }

    private func control(_ command: String) async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == simulator else {
            throw XCTSkip("Offline UI acceptance uses only its separately allocated simulator.")
        }
        let (statusData, _) = try await URLSession.shared.data(from: controlRoot.appending(path: "status"))
        guard let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              status["ownerID"] as? String == "0d685e47-ddcb-4477-b3cc-199cf85f1100" else {
            throw NSError(domain: "Unowned offline UI fixture", code: 1)
        }
        var request = URLRequest(url: controlRoot.appending(path: command))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        dismissPasswordPrompt(app)
        let target = element(app, id)
        if id == "settings-sign-out" {
            let list = app.collectionViews.firstMatch
            for _ in 0..<6 where !target.exists || !target.isHittable {
                if list.exists { list.swipeUp() } else { app.swipeUp() }
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 15), id)
        target.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }

    private func signIn(_ app: XCUIApplication) {
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 3) {
            server.tap(); server.typeText(api); app.buttons["auth-continue"].tap()
            let email = app.textFields["auth-email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15))
            email.tap(); email.typeText("offline@imora-offline-fixture.invalid")
            app.secureTextFields["auth-password"].tap()
            app.secureTextFields["auth-password"].typeText("synthetic-offline-fixture")
            app.buttons["auth-sign-in"].tap()
        }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 30))
        dismissPasswordPrompt(app)
        let notNow = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "Later", "以后", "稍后"])).firstMatch
        if notNow.waitForExistence(timeout: 2), notNow.isHittable { notNow.tap() }
    }

    private func collections(_ app: XCUIApplication) {
        dismissPasswordPrompt(app)
        let expand = app.buttons["photos-show-navigation"]
        if expand.exists, expand.isHittable { expand.tap() }
        let ready = NSPredicate { _, _ in app.buttons["shell-albums"].isHittable && !app.keyboards.firstMatch.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed)
        tap(app, "shell-albums")
    }

    private func openOfflineList(_ app: XCUIApplication) {
        collections(app)
        tap(app, "collections-layout-menu")
        tap(app, "collections-offline-albums")
    }

    func testADownloadRestartOfflineCacheClearAndMediaViewer() async throws {
        continueAfterFailure = false
        try await control("online")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Light"]
        app.launch(); defer { app.terminate() }
        signIn(app)
        collections(app)
        let album = app.staticTexts["Offline acceptance"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15)); album.tap()
        tap(app, "album-menu")
        tap(app, "album-keep-offline")
        tap(app, "offline-album-download")
        XCTAssertTrue(app.buttons["Download on Wi-Fi"].waitForExistence(timeout: 5))
        app.buttons["Download on Wi-Fi"].tap()
        XCTAssertTrue(app.staticTexts["Available Offline"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-'")).count, 3)
        capture(app, "offline-en-downloaded")

        try await control("offline")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        // Clear the ordinary cache before using the independent retained list.
        app.buttons["photos-source-menu"].tap()
        app.buttons["Account & Settings"].tap()
        tap(app, "settings-storage")
        let clear = app.buttons["storage-clear-cache"]
        if clear.exists, clear.isEnabled {
            clear.tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label == 'Clear Cache' AND identifier != 'storage-clear-cache'")).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        }
        let offline = app.buttons["Offline Albums"].firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 8)); offline.tap()
        app.staticTexts["Offline acceptance"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Available Offline"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-'")).count, 3)
        capture(app, "offline-en-restarted-after-cache-clear")
        let photo = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-' AND label BEGINSWITH 'Photo,'")).allElementsBoundByIndex.first(where: \.isHittable))
        photo.tap()
        XCTAssertTrue(element(app, "asset-media").waitForExistence(timeout: 10))
        capture(app, "offline-en-photo-viewer")
        tap(app, "viewer-close")
        let video = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-' AND label BEGINSWITH 'Video,'")).allElementsBoundByIndex.first(where: \.isHittable))
        video.tap()
        XCTAssertTrue(element(app, "video-controls").waitForExistence(timeout: 15))
        capture(app, "offline-en-video-viewer")
        tap(app, "viewer-close")
        let live = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-' AND label BEGINSWITH 'Live Photo,'")).allElementsBoundByIndex.first(where: \.isHittable))
        live.tap()
        tap(app, "live-photo-mode")
        tap(app, "live-photo-play-pause")
        let playing = NSPredicate { _, _ in self.element(app, "live-photo-controls").value as? String == "Playing" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 15), .completed)
        capture(app, "offline-en-live-viewer")
        tap(app, "viewer-close")
    }

    func testBChineseOfflineListRemainsAvailableAfterRelaunch() async throws {
        continueAfterFailure = false
        try await control("online")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-AppleInterfaceStyle", "Dark"]
        app.launch(); defer { app.terminate() }
        signIn(app)
        collections(app)
        let album = app.staticTexts["Offline acceptance"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15)); album.tap()
        tap(app, "album-menu")
        tap(app, "album-keep-offline")
        if !app.staticTexts["可离线使用"].waitForExistence(timeout: 2) {
            tap(app, "offline-album-download")
            XCTAssertTrue(app.buttons["通过 Wi-Fi 下载"].waitForExistence(timeout: 5))
            app.buttons["通过 Wi-Fi 下载"].tap()
            XCTAssertTrue(app.staticTexts["可离线使用"].waitForExistence(timeout: 30))
        }
        try await control("offline")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        openOfflineList(app)
        XCTAssertTrue(app.staticTexts["Offline acceptance"].waitForExistence(timeout: 10))
        app.staticTexts["Offline acceptance"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["可离线使用"].waitForExistence(timeout: 10))
        capture(app, "offline-zh-dark-restarted")
    }

    private func recoveryFlow(language: String) async throws {
        guard ProcessInfo.processInfo.environment["IMORA_OFFLINE_RECOVERY_TEST"] == "1" else {
            throw XCTSkip("Recovery flow requires an explicitly injected, owned corrupt-download fixture")
        }
        continueAfterFailure = false
        try await control("offline")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        openOfflineList(app)
        let healthy = app.staticTexts["Offline acceptance"].firstMatch
        XCTAssertTrue(healthy.waitForExistence(timeout: 10))
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-recovery-remove-'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        capture(app, "offline-recovery-\(language)-before-removal")
        remove.tap()
        capture(app, "offline-recovery-\(language)-confirmation")
        let confirm = app.buttons["offline-recovery-confirm-remove"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        else {
            let label = language == "en" ? "Remove Local Copy" : "移除本地副本"
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            try XCTUnwrap(buttons.last).tap()
        }
        let gone = NSPredicate { _, _ in !remove.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 15), .completed)
        XCTAssertTrue(healthy.exists)
        capture(app, "offline-recovery-\(language)-after-removal")
        healthy.tap()
        XCTAssertTrue(app.staticTexts["offline-album-progress"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-'")).count, 3)
    }

    func testDRecoveryKeepsHealthyAlbumAndRemovesIncompleteLocalCopy() async throws {
        try await recoveryFlow(language: "en")
    }

    func testEChineseRecoveryKeepsHealthyAlbumAndRemovesIncompleteLocalCopy() async throws {
        try await recoveryFlow(language: "zh-Hans")
    }

    func testCClearFixtureLoginBeforeNativeRegressions() async throws {
        continueAfterFailure = false
        try await control("offline")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        if app.textFields["auth-server"].waitForExistence(timeout: 3) { return }
        tap(app, "photos-source-menu")
        app.buttons["Account & Settings"].tap()
        tap(app, "settings-sign-out")
        tap(app, "settings-confirm-sign-out")
        XCTAssertTrue(app.textFields["auth-server"].waitForExistence(timeout: 20))
    }
}
