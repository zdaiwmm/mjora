import Foundation
import UIKit
import XCTest

@MainActor
final class MemoryFlowTests: XCTestCase {
    private struct Fixture: Decodable {
        let apiURL: String
        let ownerID: String
    }

    private func fixture() throws -> Fixture {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "096710F4-E2E2-4F95-AAC2-3489F82B0F74" else {
            throw XCTSkip("Run memory UI acceptance only on its separately allocated synthetic simulator.")
        }
        let path = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4/legacy-ui-fixture.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard path.resolvingSymlinksInPath() == path, (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw NSError(domain: "Unsafe memory fixture", code: 1)
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        guard fixture.apiURL == "http://127.0.0.1:33284/api", UUID(uuidString: fixture.ownerID) != nil else {
            throw NSError(domain: "Unexpected memory fixture", code: 1)
        }
        return fixture
    }

    private func launch(memoryDiagnostics: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["IMORA_PHASE4_OWNED_FIXTURE"] = "memories"
        if memoryDiagnostics { app.launchEnvironment["IMORA_MEMORY_DIAGNOSTICS"] = "1" }
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 5) {
            app.textFields["auth-server"].tap(); app.textFields["auth-server"].typeText(fixture.apiURL)
            app.buttons["auth-continue"].tap()
            XCTAssertTrue(app.textFields["auth-email"].waitForExistence(timeout: 15))
            app.textFields["auth-email"].tap(); app.textFields["auth-email"].typeText("phase4-ui-placeholder@example.invalid")
            app.secureTextFields["auth-password"].tap(); app.secureTextFields["auth-password"].typeText("phase4-ui-placeholder")
            app.buttons["auth-sign-in"].tap()
        }
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
        if later.waitForExistence(timeout: 2), later.isHittable { later.tap() }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["shell-albums"].waitForExistence(timeout: 10))
        return app
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func memoryFixtureIDs() throws -> [String] {
        let fixture = try fixture()
        let path = "/Users/achilles/mjora/execution/memories-20261117/fixture.json"
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(data["apiURL"] as? String, fixture.apiURL)
        XCTAssertEqual(data["ownerID"] as? String, fixture.ownerID)
        return try XCTUnwrap(data["memoryIDs"] as? [String])
    }

    private func videoFrameIndex() throws -> Int {
        let path = URL(fileURLWithPath: "/Users/achilles/mjora/execution/memories-20261117/fixture.json")
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        return try XCTUnwrap(data["videoIndex"] as? Int)
    }

    private func memoryButton(_ app: XCUIApplication, id: String) -> XCUIElement {
        let button = app.buttons[id].firstMatch
        func visible() -> Bool {
            guard button.exists, app.frame.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) else { return false }
            return button.isHittable
        }
        for _ in 0..<3 where !visible() { app.scrollViews["memory-lane"].firstMatch.swipeLeft() }
        for _ in 0..<3 where !visible() { app.scrollViews["memory-lane"].firstMatch.swipeRight() }
        XCTAssertTrue(visible(), id)
        return button
    }

    private func playbackControl(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let control = app.buttons[id]
        if !control.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        XCTAssertTrue(control.waitForExistence(timeout: 4))
        return control
    }

    private func waitForMemoryProbe(_ app: XCUIApplication, _ fragment: String) {
        let probe = app.staticTexts["memory-playback-probe"]
        let matches = NSPredicate { _, _ in probe.exists && (probe.value as? String ?? "").contains(fragment) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 15), .completed,
                       "Expected \(fragment), observed \(probe.exists ? probe.value as? String ?? "no value" : "missing probe")")
    }

    func testMemoryCardsWithSharedCoverRepeatedlyOpenTheWholeCollection() throws {
        let ids = try memoryFixtureIDs(), app = try launch()
        app.buttons["shell-albums"].tap()
        for _ in 0..<2 {
            for id in ids {
                memoryButton(app, id: "memory-card-\(id)").tap()
                snapshot(app, "memory-card-open")
                XCTAssertTrue(app.scrollViews["memory-collection"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["memory-photo-0"].exists)
                XCTAssertTrue(app.buttons["memory-photo-3"].exists)
                XCTAssertFalse(app.buttons["viewer-close"].exists)
                snapshot(app, "memory-photo-collection")
                app.buttons["memory-photo-0"].tap()
                XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 8))
                app.buttons["viewer-close"].tap()
                XCTAssertTrue(app.buttons["memory-collection-play"].waitForExistence(timeout: 5))
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(app.scrollViews["collections-home"].waitForExistence(timeout: 5))
            }
        }
    }

    func testMemoryMoviePlaysBundledMusicPausesMutesSeeksAndReopens() throws {
        let ids = try memoryFixtureIDs(), app = try launch(memoryDiagnostics: true)
        app.buttons["shell-albums"].tap()
        memoryButton(app, id: "memory-card-\(ids[0])").tap()
        XCTAssertTrue(app.buttons["memory-collection-play"].waitForExistence(timeout: 5))
        app.buttons["memory-collection-play"].tap()
        waitForMemoryProbe(app, "music=true")
        snapshot(app, "memory-fullscreen-music")
        playbackControl(app, "memory-playback-toggle").tap()
        waitForMemoryProbe(app, "playing=false")
        waitForMemoryProbe(app, "music=false")
        let paused = app.staticTexts["memory-playback-probe"].value as? String
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(app.staticTexts["memory-playback-probe"].value as? String, paused)
        playbackControl(app, "memory-playback-toggle").tap()
        waitForMemoryProbe(app, "music=true")
        playbackControl(app, "memory-playback-mute").tap()
        waitForMemoryProbe(app, "muted=true")
        waitForMemoryProbe(app, "audible=false")
        playbackControl(app, "memory-playback-mute").tap()
        waitForMemoryProbe(app, "music=true")
        playbackControl(app, "memory-frame-\(try videoFrameIndex())").tap()
        waitForMemoryProbe(app, "video=true")
        waitForMemoryProbe(app, "ready=true")
        snapshot(app, "memory-video-in-slideshow")
        playbackControl(app, "memory-playback-close").tap()
        XCTAssertTrue(app.buttons["memory-collection-play"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        for id in ids {
            memoryButton(app, id: "memory-play-\(id)").tap()
            waitForMemoryProbe(app, "music=true")
            playbackControl(app, "memory-playback-close").tap()
            XCTAssertTrue(app.buttons["memory-playback-close"].waitForNonExistence(timeout: 5))
        }
    }

    func testMemoryMoviePausesInBackgroundAndKeepsItsSelectedFrame() throws {
        let ids = try memoryFixtureIDs(), app = try launch(memoryDiagnostics: true)
        app.buttons["shell-albums"].tap()
        memoryButton(app, id: "memory-play-\(ids[0])").tap()
        waitForMemoryProbe(app, "music=true")
        playbackControl(app, "memory-frame-1").tap()
        waitForMemoryProbe(app, "index=1;")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForMemoryProbe(app, "playing=false")
        waitForMemoryProbe(app, "music=false")
        waitForMemoryProbe(app, "index=1;")
        snapshot(app, "memory-background-return-paused")
        playbackControl(app, "memory-playback-close").tap()
    }

    func testMemoryMovieWithRealSystemReduceMotion() throws {
        _ = try fixture()
        let control = try SystemReduceMotionControl()
        addTeardownBlock { try await MainActor.run { try control.restoreOriginal() } }
        try control.setEnabled(true)
        XCTAssertTrue(UIAccessibility.isReduceMotionEnabled)
        let ids = try memoryFixtureIDs(), app = try launch(memoryDiagnostics: true)
        app.buttons["shell-albums"].tap()
        memoryButton(app, id: "memory-card-\(ids[0])").tap()
        XCTAssertTrue(app.buttons["memory-collection-play"].waitForExistence(timeout: 5))
        app.buttons["memory-collection-play"].tap()
        waitForMemoryProbe(app, "music=true")
        playbackControl(app, "memory-playback-next").tap()
        waitForMemoryProbe(app, "index=1;")
        snapshot(app, "memory-real-reduce-motion")
        playbackControl(app, "memory-playback-close").tap()
        XCTAssertTrue(app.buttons["memory-collection-play"].waitForExistence(timeout: 5))
    }

}
