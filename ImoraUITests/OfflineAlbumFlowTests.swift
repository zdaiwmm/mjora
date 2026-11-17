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
            let title = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[cd] %@", "保存密码", "Save Password")
            guard alert.label.contains("保存密码") || alert.label.localizedCaseInsensitiveContains("Save Password")
                    || alert.descendants(matching: .any).matching(title).firstMatch.exists else { return false }
            for label in ["以后", "Not Now", "Later"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func dismissPasswordPrompt(_ app: XCUIApplication) {
        let title = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[cd] %@", "保存密码", "Save Password")
        for surface in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            guard surface.descendants(matching: .any).matching(title).firstMatch.exists else { continue }
            for label in ["以后", "Not Now", "Later"] {
                let button = surface.buttons[label]
                if button.exists { button.tap(); return }
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

    private func waitForHittable(_ target: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let ready = NSPredicate { _, _ in
            self.dismissPasswordPrompt(app)
            guard target.exists else { return false }
            let frame = target.frame
            return frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
                && !frame.isEmpty && target.isHittable && target.isEnabled
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout) == .completed
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        dismissPasswordPrompt(app)
        if id == "settings-sign-out" {
            let list = app.collectionViews.firstMatch
            for _ in 0..<6 where !app.buttons[id].isHittable {
                if list.exists { list.swipeUp() } else { app.swipeUp() }
            }
        }
        var target: XCUIElement?
        let ready = NSPredicate { _, _ in
            self.dismissPasswordPrompt(app)
            target = app.descendants(matching: .any).matching(identifier: id)
                .allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
            return target != nil
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15) == .completed,
              let target else { XCTFail("No hittable control: \(id)"); return }
        target.tap()
    }

    private func enter(_ value: String, in field: XCUIElement, app: XCUIApplication) {
        guard waitForHittable(field, app: app) else { XCTFail("Input field is not hittable: \(field.identifier)"); return }
        field.tap()
        var previousFrame = field.frame
        var stableFrames = 0
        let keyboardReady = NSPredicate { _, _ in
            self.dismissPasswordPrompt(app)
            guard field.isHittable, app.keyboards.firstMatch.exists else { stableFrames = 0; return false }
            let currentFrame = field.frame
            stableFrames = currentFrame == previousFrame ? stableFrames + 1 : 0
            previousFrame = currentFrame
            return stableFrames >= 2
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: keyboardReady, object: nil)], timeout: 6) == .completed
        else { XCTFail("Keyboard or input layout did not settle: \(field.identifier)"); return }
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    private func openAlbum(_ app: XCUIApplication, destination: String = "album-menu") {
        dismissPasswordPrompt(app)
        let title = "Offline acceptance"
        let label = NSPredicate(format: "label CONTAINS %@", title)
        let offline = destination == "offline-album-progress"
        var content: XCUIElement?
        let active = NSPredicate { _, _ in
            self.dismissPasswordPrompt(app)
            guard offline || app.buttons["shell-albums"].isSelected else { return false }
            let candidates = offline
                ? app.descendants(matching: .any).matching(identifier: "offline-albums").allElementsBoundByIndex
                : app.scrollViews.matching(identifier: "collections-home").allElementsBoundByIndex
            let viewport = app.windows.firstMatch.frame
            content = candidates.first { candidate in
                let frame = candidate.frame
                return frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
                    && !frame.isEmpty && frame.intersects(viewport)
            }
            return content != nil
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: active, object: nil)], timeout: 10) == .completed,
              let content else { capture(app, "offline-album-container-inactive"); XCTFail("The expected album list is not active"); return }
        var target: XCUIElement?
        for attempt in 0..<4 {
            let ready = NSPredicate { _, _ in
                self.dismissPasswordPrompt(app)
                let containers = content.buttons.matching(label).allElementsBoundByIndex
                    + content.links.matching(label).allElementsBoundByIndex
                    + content.cells.containing(.staticText, identifier: title).allElementsBoundByIndex
                    + content.otherElements.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
                let viewport = content.frame.intersection(app.windows.firstMatch.frame)
                target = containers.first { candidate in
                    let frame = candidate.frame
                    guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                          !frame.isEmpty, frame.intersects(viewport) else { return false }
                    return candidate.isHittable && candidate.isEnabled
                }
                return target != nil
            }
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 3) == .completed { break }
            if attempt < 3 { dismissPasswordPrompt(app); content.swipeUp() }
        }
        guard let target else {
            capture(app, "offline-album-link-unavailable")
            XCTFail("No hittable album navigation container"); return
        }
        dismissPasswordPrompt(app)
        target.tap()
        let arrived = element(app, destination)
        guard waitForHittable(arrived, app: app) else {
            capture(app, "offline-album-navigation-failed")
            XCTFail("Album navigation did not reach \(destination)"); return
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }

    private func signIn(_ app: XCUIApplication) {
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 3) {
            enter(api, in: server, app: app)
            tap(app, "auth-continue")
            enter("offline@imora-offline-fixture.invalid", in: app.textFields["auth-email"], app: app)
            enter("synthetic-offline-fixture", in: app.secureTextFields["auth-password"], app: app)
            tap(app, "auth-sign-in")
        }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 30))
        dismissPasswordPrompt(app)
        dismissPasswordPrompt(app)
    }

    private func collections(_ app: XCUIApplication) {
        dismissPasswordPrompt(app)
        let albums = app.buttons["shell-albums"], library = app.buttons["shell-photos"]
        for attempt in 0..<2 {
            if attempt == 1 {
                guard waitForHittable(library, app: app, timeout: 5) else { break }
                library.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
                let selectedLibrary = NSPredicate { _, _ in
                    self.dismissPasswordPrompt(app)
                    return library.isSelected
                }
                guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selectedLibrary, object: nil)], timeout: 5) == .completed else { break }
            }
            let expand = app.buttons["photos-show-navigation"]
            if expand.exists, expand.isHittable { expand.tap() }
            var previousFrame = CGRect.zero
            var stableFrames = 0
            let ready = NSPredicate { _, _ in
                self.dismissPasswordPrompt(app)
                guard albums.exists, !app.keyboards.firstMatch.exists else { stableFrames = 0; return false }
                let frame = albums.frame
                guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                      !frame.isEmpty, frame.intersects(app.windows.firstMatch.frame), albums.isEnabled else {
                    stableFrames = 0; return false
                }
                stableFrames = frame == previousFrame ? stableFrames + 1 : 0
                previousFrame = frame
                return stableFrames >= 2
            }
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 8) == .completed else { continue }
            dismissPasswordPrompt(app)
            albums.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            let selectedCollections = NSPredicate { _, _ in
                self.dismissPasswordPrompt(app)
                guard albums.isSelected, !library.isSelected else { return false }
                let home = app.scrollViews["collections-home"]
                guard home.exists else { return false }
                let frame = home.frame
                return frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
                    && !frame.isEmpty && frame.intersects(app.windows.firstMatch.frame)
            }
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selectedCollections, object: nil)], timeout: 6) == .completed { return }
        }
        capture(app, "offline-collections-selection-failed")
        XCTFail("Collections did not become selected with a visible content container")
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
        openAlbum(app)
        tap(app, "album-menu")
        tap(app, "album-keep-offline")
        tap(app, "offline-album-download")
        XCTAssertTrue(waitForHittable(app.buttons["Download on Wi-Fi"], app: app, timeout: 5))
        app.buttons["Download on Wi-Fi"].tap()
        XCTAssertTrue(app.staticTexts["Available Offline"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-asset-'")).count, 3)
        capture(app, "offline-en-downloaded")

        try await control("offline")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        // Clear the ordinary cache before using the independent retained list.
        tap(app, "photos-source-menu")
        tap(app, "Account & Settings")
        tap(app, "settings-storage")
        let clear = app.buttons["storage-clear-cache"]
        if clear.exists, clear.isEnabled {
            XCTAssertTrue(waitForHittable(clear, app: app))
            clear.tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label == 'Clear Cache' AND identifier != 'storage-clear-cache'")).firstMatch
            XCTAssertTrue(waitForHittable(confirm, app: app, timeout: 5)); confirm.tap()
        }
        let offline = app.buttons["Offline Albums"].firstMatch
        XCTAssertTrue(waitForHittable(offline, app: app, timeout: 8)); offline.tap()
        openAlbum(app, destination: "offline-album-progress")
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
        openAlbum(app)
        tap(app, "album-menu")
        tap(app, "album-keep-offline")
        if !app.staticTexts["可离线使用"].waitForExistence(timeout: 2) {
            tap(app, "offline-album-download")
            XCTAssertTrue(waitForHittable(app.buttons["通过 Wi-Fi 下载"], app: app, timeout: 5))
            app.buttons["通过 Wi-Fi 下载"].tap()
            XCTAssertTrue(app.staticTexts["可离线使用"].waitForExistence(timeout: 30))
        }
        try await control("offline")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        openOfflineList(app)
        XCTAssertTrue(app.staticTexts["Offline acceptance"].waitForExistence(timeout: 10))
        openAlbum(app, destination: "offline-album-progress")
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
        XCTAssertTrue(waitForHittable(remove, app: app, timeout: 10))
        capture(app, "offline-recovery-\(language)-before-removal")
        remove.tap()
        capture(app, "offline-recovery-\(language)-confirmation")
        let confirm = app.buttons["offline-recovery-confirm-remove"]
        if waitForHittable(confirm, app: app, timeout: 3) { confirm.tap() }
        else {
            let label = language == "en" ? "Remove Local Copy" : "移除本地副本"
            let query = app.buttons.matching(NSPredicate(format: "label == %@", label))
            let ready = NSPredicate { _, _ in query.allElementsBoundByIndex.contains(where: \.isHittable) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
            try XCTUnwrap(query.allElementsBoundByIndex.last(where: \.isHittable)).tap()
        }
        let gone = NSPredicate { _, _ in !remove.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 15), .completed)
        XCTAssertTrue(healthy.exists)
        capture(app, "offline-recovery-\(language)-after-removal")
        openAlbum(app, destination: "offline-album-progress")
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
