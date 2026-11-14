import Foundation
import XCTest

@MainActor
final class PhotosCollectionsFlowTests: XCTestCase {
    private struct Fixture: Decodable { let apiURL: String; let email: String; let password: String }

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        let url = URL(fileURLWithPath: "/private/tmp/imora-341-ios-fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the dedicated local fixture first.") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard fixture.apiURL == "http://127.0.0.1:32283/api", fixture.email.hasSuffix("@imora-fixture.invalid") else {
            throw NSError(domain: "Unsafe fixture destination", code: 1)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 4) {
            let field = app.textFields["auth-server"]
            field.tap(); field.typeText(fixture.apiURL)
            app.buttons["auth-continue"].tap()
            XCTAssertTrue(app.textFields["auth-email"].waitForExistence(timeout: 20))
            app.textFields["auth-email"].tap(); app.textFields["auth-email"].typeText(fixture.email)
            app.secureTextFields["auth-password"].tap(); app.secureTextFields["auth-password"].typeText(fixture.password)
            app.buttons["auth-sign-in"].tap()
        }
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
        if later.waitForExistence(timeout: 2), later.isHittable { later.tap() }
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let item = app.buttons.matching(identifier: id).firstMatch
        for _ in 0..<6 where !item.exists || !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 10), id)
        item.tap()
    }

    func testNativePhotosMenusSelectionAndSourceSwitch() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.segmentedControls["photos-source-picker"].exists)
        XCTAssertFalse(app.tabBars.buttons["图库"].exists)
        snapshot(app, "native-photos-home")
        app.buttons["photos-sort-filter"].tap()
        snapshot(app, "native-photos-filter-menu")
        app.buttons["显示选项"].tap()
        snapshot(app, "native-photos-view-options")
        app.buttons["缩小"].tap()
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        app.buttons["timeline-select"].tap()
        let visible = tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 150 && $0.frame.midY < app.frame.height - 120
        }
        try XCTUnwrap(visible).tap()
        XCTAssertTrue(app.buttons["selection-show-selected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        snapshot(app, "native-photos-selection")
        app.buttons["selection-show-selected"].tap()
        snapshot(app, "native-photos-selected-preview")
        let done = app.buttons.matching(NSPredicate(format: "label == '完成' OR label == 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        app.buttons["selection-cancel"].tap()
        try XCTUnwrap(tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 150 && $0.frame.midY < app.frame.height - 120
        }).tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 8))
        snapshot(app, "native-photos-viewer")
        app.navigationBars.buttons.matching(identifier: "viewer-close").firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForNonExistence(timeout: 8))
        app.buttons["photos-source-menu"].tap()
        app.buttons["本机"].tap()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 8))
        snapshot(app, "native-device-photos")
        app.buttons["photos-source-menu"].tap(); app.buttons["云端照片"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
    }

    func testCollectionsPreservesUtilitiesAndAlbumCreation() throws {
        let app = try launch()
        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 25))
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(app.scrollViews["collections-home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["albums-all-cloud-photos"].exists)
        snapshot(app, "native-collections-home")
        tap(app, "collections-albums")
        XCTAssertTrue(app.buttons["albums-create"].waitForExistence(timeout: 10))
        app.buttons["albums-create"].tap()
        let name = "交互验证-\(UUID().uuidString.prefix(6))"
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 15))
        snapshot(app, "native-album-created")
        app.staticTexts[name].firstMatch.tap()
        XCTAssertTrue(app.buttons["album-menu"].waitForExistence(timeout: 8))
        snapshot(app, "native-album-detail")
        app.buttons["album-menu"].tap()
        let delete = app.buttons.matching(NSPredicate(format: "label == '删除相册' OR label == 'Delete Album'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '删除相册' OR label == 'Delete Album'")).allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(confirm); confirm?.tap()
        XCTAssertTrue(app.buttons["albums-create"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "collections-archive")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "collections-largeFiles")
        snapshot(app, "native-collections-utilities")
    }

    func testCollectionsPinsAndCollapsePersistAcrossLaunches() throws {
        let app = try launch()
        app.tabBars.buttons["相册"].tap()
        let collapse = app.buttons["collections-collapse-memories"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        if collapse.label.hasPrefix("展开") { collapse.tap() }
        collapse.tap()
        XCTAssertTrue(collapse.label.hasPrefix("展开"))
        tap(app, "collections-edit-pins")
        let favorite = app.buttons["collections-pin-favorites"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        if favorite.value as? String == "未置顶" { favorite.tap() }
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "未置顶")
        snapshot(app, "native-pinned-collections-editor")
        app.buttons["完成"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        XCTAssertTrue(collapse.label.hasPrefix("展开"))
        tap(app, "collections-edit-pins")
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.value as? String, "未置顶")
        favorite.tap()
        app.buttons["完成"].tap()
        collapse.tap()
        app.buttons["collections-layout-menu"].tap()
        app.buttons["自定精选集"].tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "native-collections-layout-editor")
        app.buttons["完成"].tap()
    }

    func testLongLibraryRestoresSourceAnchorAndDrillsIntoPeriods() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 20))
        let tiles = app.buttons.matching(identifier: "asset-tile")
        func visibleLabels() -> [String] {
            tiles.allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.midY > 180 && $0.frame.midY < app.frame.height - 140
            }.map(\.label)
        }
        XCTAssertTrue(visibleLabels().contains { $0.contains("2026年11月") }, "A cold cloud library opens at its newest end")
        app.swipeDown()
        app.swipeDown()
        let anchor = try XCTUnwrap(visibleLabels().first)
        snapshot(app, "native-long-library-anchor")
        app.buttons["photos-source-menu"].tap()
        app.buttons["本机"].tap()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 10))
        snapshot(app, "native-device-library")
        app.buttons["photos-source-menu"].tap()
        app.buttons["云端照片"].tap()
        let restored = NSPredicate { _, _ in visibleLabels().contains(anchor) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 15), .completed)
        let picker = app.segmentedControls["photos-period-picker"]
        if !picker.exists { app.swipeDown() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["年"].tap()
        let year = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photos-period-'")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 10))
        snapshot(app, "native-years")
        year.tap()
        XCTAssertTrue(app.buttons["所有年份"].waitForExistence(timeout: 5))
        snapshot(app, "native-months")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photos-period-'")).firstMatch.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        snapshot(app, "native-period-revealed")
    }
}
