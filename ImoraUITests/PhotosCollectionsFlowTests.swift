import Foundation
import XCTest

@MainActor
final class PhotosCollectionsFlowTests: XCTestCase {
    private func launch(tracesLaunch: Bool = false, enablesMapForLaunch: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        let fixture = try OwnedUIFixture.load()
        let app = XCUIApplication()
        OwnedUIFixture.configure(app)
        if tracesLaunch { app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if enablesMapForLaunch { app.launchArguments += ["-imora.maps.appleServicesAllowed", "YES"] }
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 4) {
            let field = app.textFields["auth-server"]
            field.tap(); field.typeText(fixture.apiURL)
            app.buttons["auth-continue"].tap()
            XCTAssertTrue(app.textFields["auth-email"].waitForExistence(timeout: 20))
            app.textFields["auth-email"].tap(); app.textFields["auth-email"].typeText(OwnedUIFixture.placeholderEmail)
            app.secureTextFields["auth-password"].tap(); app.secureTextFields["auth-password"].typeText(OwnedUIFixture.placeholderPassword)
            app.buttons["auth-sign-in"].tap()
        }
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
        if later.waitForExistence(timeout: 2), later.isHittable { later.tap() }
        let ready = NSPredicate { _, _ in
            // Password AutoFill can present its save prompt after the main
            // screen mounts. Decline it while waiting for usable navigation.
            if later.exists && later.isHittable { later.tap() }
            let title = app.buttons["photos-source-menu"]
            let albums = app.buttons["shell-albums"]
            return title.exists && title.isHittable && albums.exists && albums.isHittable
        }
        let readiness = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 25)
        if readiness != .completed {
            snapshot(app, "login-navigation-not-ready")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "login-navigation-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(readiness, .completed,
                       "Wait for signed-in navigation and dismiss the synthetic password prompt")
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func chooseSourceItem(_ app: XCUIApplication, _ title: String) {
        let items = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", title, "photos-source-menu"))
        let visible = items.allElementsBoundByIndex.first(where: \.isHittable) ?? items.firstMatch
        XCTAssertTrue(visible.waitForExistence(timeout: 5)); visible.tap()
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let item = app.buttons.matching(identifier: id).firstMatch
        let ready = NSPredicate { _, _ in item.exists && item.isHittable }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 2) != .completed {
            for _ in 0..<6 where !item.exists || !item.isHittable {
                if item.exists, item.frame.midY < app.frame.midY { app.swipeDown() }
                else { app.swipeUp() }
            }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 10), id)
        XCTAssertTrue(item.isHittable, id)
        item.tap()
    }

    func testPhotoEditorHistoryAspectPanelAndSaveReturn() throws {
        let app = try launch()
        app.buttons["photos-source-menu"].tap()
        app.buttons["云端"].tap()
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        try XCTUnwrap(tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 170 && $0.frame.midY < app.frame.height - 140
        }).tap()
        let edit = app.buttons["viewer-edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        let aspect = app.buttons["edit-aspect-ratio"]
        if !aspect.exists {
            let crop = app.buttons.matching(NSPredicate(format: "label IN %@", ["裁剪", "Crop"])).firstMatch
            XCTAssertTrue(crop.waitForExistence(timeout: 15)); crop.tap()
        }
        XCTAssertTrue(aspect.waitForExistence(timeout: 15))
        // Glass publishes a shared AX rectangle for its native menu. Verify
        // real aspect/menu actions below; EditorMenuGeometryTests separately
        // proves their physical bounds and native hit areas do not overlap.
        snapshot(app, "editor-crop-tools")
        aspect.tap()
        let square = app.buttons.matching(NSPredicate(format: "label IN %@", ["SQUARE", "正方形"])).firstMatch
        XCTAssertTrue(square.waitForExistence(timeout: 4)); square.tap()
        snapshot(app, "editor-aspect-ratios")
        aspect.tap()
        let rotate = app.buttons.matching(NSPredicate(format: "label IN %@", ["Rotate Left", "向左旋转"])).firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 4)); rotate.tap()
        let done = app.buttons["edit-done"]
        XCTAssertTrue(done.isEnabled)
        app.buttons["edit-more"].tap()
        let undo = app.buttons.matching(NSPredicate(format: "label IN %@", ["Undo", "撤销"])).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 4)); undo.tap()
        app.buttons["edit-more"].tap()
        let redo = app.buttons.matching(NSPredicate(format: "label IN %@", ["Redo", "重做"])).firstMatch
        XCTAssertTrue(redo.waitForExistence(timeout: 4)); redo.tap()
        XCTAssertTrue(done.isEnabled)
        app.buttons["edit-more"].tap()
        let revert = app.buttons.matching(NSPredicate(format: "label IN %@", ["Revert to Original", "还原为原始版本"])).firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: 4)); revert.tap()
        snapshot(app, "editor-revert-confirmation")
        // Dismissing the confirmation preserves the unsaved geometry.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(app.buttons["edit-done"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.buttons["viewer-close"].firstMatch.waitForExistence(timeout: 8))
        snapshot(app, "editor-save-return")
        edit.tap()
        XCTAssertTrue(app.buttons["edit-more"].waitForExistence(timeout: 15))
        app.buttons["edit-more"].tap()
        XCTAssertTrue(revert.waitForExistence(timeout: 4)); revert.tap()
        // Confirming restoration stays in the editor until Done accepts it.
        XCTAssertTrue(revert.waitForExistence(timeout: 4)); revert.tap()
        XCTAssertTrue(done.isEnabled)
        snapshot(app, "editor-reverted-original")
        done.tap()
        XCTAssertTrue(app.buttons["edit-done"].waitForNonExistence(timeout: 15))
        edit.tap()
        if !aspect.exists {
            let crop = app.buttons.matching(NSPredicate(format: "label IN %@", ["裁剪", "Crop"])).firstMatch
            XCTAssertTrue(crop.waitForExistence(timeout: 15)); crop.tap()
        }
        XCTAssertTrue(aspect.waitForExistence(timeout: 15))
        rotate.tap()
        app.buttons["edit-cancel"].tap()
        let discard = app.buttons.matching(NSPredicate(format: "label IN %@", ["Discard Changes", "放弃更改"])).firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 4)); discard.tap()
        XCTAssertTrue(app.buttons["edit-done"].waitForNonExistence(timeout: 10))
        app.buttons["viewer-close"].firstMatch.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
    }

    func testPinchColumnTransitionKeepsTilesUsableAcrossRepeatedGestures() throws {
        let app = try launch()
        app.buttons["photos-source-menu"].tap()
        app.buttons["云端"].tap()
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        func mediaTile() throws -> XCUIElement {
            try XCTUnwrap(tiles.allElementsBoundByIndex.first {
                $0.frame.midY > 170 && $0.frame.midY < app.frame.height - 140 && $0.isHittable
            })
        }
        func tileWidth() -> CGFloat {
            tiles.allElementsBoundByIndex.first {
                $0.frame.midY > 170 && $0.frame.midY < app.frame.height - 140 && $0.isHittable
            }?.frame.width ?? 0
        }
        // First establish the small-tile endpoint, then test a real reflow.
        try mediaTile().pinch(withScale: 0.5, velocity: -1)
        let small = tileWidth()
        try mediaTile().pinch(withScale: 1.8, velocity: 1)
        let large = tileWidth()
        XCTAssertGreaterThan(large, small + 15)
        snapshot(app, "grid-pinch-enlarged")
        try mediaTile().pinch(withScale: 0.65, velocity: -1)
        let start = Date()
        var observedMS: Double?
        let contracted = NSPredicate { _, _ in
            guard tileWidth() < large else { return false }
            observedMS = Date().timeIntervalSince(start) * 1000
            return true
        }
        let contraction = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: contracted, object: nil)], timeout: 3)
        snapshot(app, "grid-pinch-contracted")
        let timing = XCTAttachment(string: "Milliseconds from pinch return to observed smaller tile: \(observedMS.map { String(format: "%.1f", $0) } ?? "not observed"); wait result: \(contraction.rawValue)")
        timing.name = "grid-pinch-contraction-timing"; timing.lifetime = .keepAlways; add(timing)
        XCTAssertEqual(contraction, .completed)
        XCTAssertLessThan(tileWidth(), large)
        try mediaTile().pinch(withScale: 1.4, velocity: 1)
        try XCTUnwrap(tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 170 && $0.frame.midY < app.frame.height - 140
        }).tap()
        XCTAssertTrue(app.buttons["viewer-close"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["viewer-close"].firstMatch.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 8))
        snapshot(app, "grid-pinch-return")
    }

    func testNativePhotosMenusSelectionAndSourceSwitch() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 25))
        if !app.descendants(matching: .any)["photos-initial-preparation"].firstMatch.waitForNonExistence(timeout: 20) {
            let probe = app.scrollViews["phase4-launch-grid-probe"].value as? String ?? ""
            let tiles = app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex
                .compactMap { $0.value as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
            let trace = XCTAttachment(string: probe + "\n" + tiles)
            trace.name = "initial-photo-readiness"; trace.lifetime = .keepAlways; add(trace)
            XCTFail("The initial gallery must finish preparing its visible photos")
        }
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
        let share = app.buttons["selection-share"]
        let trash = app.buttons["selection-trash"]
        let selectionPrompt = app.staticTexts["选择照片和视频"]
        XCTAssertTrue(selectionPrompt.waitForExistence(timeout: 5))
        XCTAssertEqual(share.frame.height, trash.frame.height, accuracy: 1)
        XCTAssertEqual(share.frame.height, 46, accuracy: 1)
        XCTAssertEqual(selectionPrompt.frame.midY, share.frame.midY, accuracy: 1)
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
        app.buttons["photos-source-menu"].tap(); app.buttons["云端"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
    }

    func testSortPaletteShowsTitlesAndSelectionForBothOrders() throws {
        let app = try launch()
        app.buttons["photos-sort-filter"].tap()
        let added = app.buttons["添加日期"]
        let captured = app.buttons["拍摄日期"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertTrue(captured.exists)
        snapshot(app, "feedback-sort-captured-selected")
        added.tap()
        app.buttons["photos-sort-filter"].tap()
        snapshot(app, "feedback-sort-added-selected")
        captured.tap()
    }

    func testCloudFavoritesScreenshotsAndTrashConfirmation() throws {
        let app = try launch()
        app.buttons["photos-sort-filter"].tap()
        app.buttons["个人收藏"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["photos-initial-preparation"].firstMatch.waitForNonExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["无法加载"].exists, "Favorites must load without an unsupported partner predicate")
        snapshot(app, "feedback-cloud-favorites")
        app.buttons["photos-sort-filter"].tap()
        app.buttons["截屏"].tap()
        XCTAssertTrue(app.staticTexts["photos-filter-count"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["photos-screenshot-loading"].firstMatch.waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["photos-initial-preparation"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["无法加载照片"].exists)
        XCTAssertFalse(app.staticTexts["无法完成此筛选"].exists)
        XCTAssertFalse(app.staticTexts["可在本机照片中使用"].exists)
        snapshot(app, "feedback-cloud-screenshots")
        app.buttons["photos-sort-filter"].tap()
        app.buttons["所有项目"].tap()
        app.buttons["shell-albums"].tap()
        let collections = app.scrollViews["collections-home"]
        XCTAssertTrue(collections.waitForExistence(timeout: 10))
        let trash = app.buttons["collections-trash"]
        for _ in 0..<6 where !trash.exists || !trash.isHittable {
            collections.swipeUp()
        }
        collections.swipeUp()
        XCTAssertTrue(trash.isHittable)
        XCTAssertLessThanOrEqual(trash.frame.maxY, app.buttons["shell-albums"].frame.minY,
                                 "The bottom collection must remain above the floating navigation")
        snapshot(app, "feedback-collections-bottom-clearance")
        tap(app, "collections-trash")
        let more = app.navigationBars.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let deleteAll = app.buttons["全部删除"].firstMatch
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5)); deleteAll.tap()
        XCTAssertTrue(app.buttons["全部删除"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "feedback-trash-delete-all-confirmation")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75)).tap()
    }

    func testCollectionsPreservesUtilitiesAndAlbumCreation() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["shell-albums"].waitForExistence(timeout: 25))
        app.buttons["shell-albums"].tap()
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
        app.buttons["shell-albums"].tap()
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
        app.buttons["shell-albums"].tap()
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

    func testCompactCollectionsHasOnlyOneBottomNavigation() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["shell-albums"].waitForExistence(timeout: 20))
        app.buttons["shell-albums"].tap()
        XCTAssertTrue(app.scrollViews["collections-home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The native tab bar must not duplicate the compact glass navigation")
        XCTAssertFalse(app.photoSearchField.exists, "Global photo search belongs to its dedicated tab")
        let avatar = app.buttons["profile-avatar"]
        XCTAssertEqual(avatar.frame.width, avatar.frame.height, accuracy: 1,
                       "The avatar's glass background must remain circular")
        snapshot(app, "feedback-collections-single-navigation")
    }

    func testConsentedCollectionsPlacesPreviewOpensFullMap() throws {
        let app = try launch(enablesMapForLaunch: true)
        defer { app.terminate() }
        app.buttons["shell-albums"].tap()
        let home = app.scrollViews["collections-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let map = app.buttons["collections-places-map"]
        for _ in 0..<8 where !map.isHittable { home.swipeUp() }
        XCTAssertTrue(map.isHittable)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["map-settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["apple-maps-enable"].exists)
    }

    func testPolishedViewerSearchMenuPeriodsAndFullScreenMap() throws {
        let app = try launch(tracesLaunch: true)
        defer { app.terminate() }
        app.buttons["photos-source-menu"].tap()
        chooseSourceItem(app, "云端")
        XCTAssertTrue(app.descendants(matching: .any)["photos-initial-preparation"].firstMatch.waitForNonExistence(timeout: 25))
        let tiles = app.buttons.matching(identifier: "asset-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20))
        // The existing opt-in bitmap probe distinguishes current, covering
        // pixels from retry/placeholder surfaces without changing app readiness.
        let probe = app.scrollViews["phase4-launch-grid-probe"]
        var chosenFrame: CGRect?
        let readyTile = NSPredicate { _, _ in
            guard let text = probe.value as? String, let data = text.data(using: .utf8),
                  let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = summary["latest"] as? [String: Any],
                  let observed = latest["tiles"] as? [[String: Any]] else { return false }
            chosenFrame = observed.compactMap { item -> CGRect? in
                guard item["realBitmap"] as? Bool == true, item["adequatePixels"] as? Bool == true,
                      let rect = item["rect"] as? [Double], rect.count == 4 else { return nil }
                let frame = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                return frame.midY > 200 && frame.midY < 600 ? frame : nil
            }.first
            return chosenFrame != nil
        }
        let readiness = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readyTile, object: nil)], timeout: 10)
        let diagnostic = XCTAttachment(string: probe.value as? String ?? "No bitmap probe")
        diagnostic.name = "polish-opening-qualified-bitmap"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertEqual(readiness, .completed)
        let frame = try XCTUnwrap(chosenFrame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let close = app.buttons["viewer-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 1))
        let viewer = app.descendants(matching: .any)["asset-viewer"].firstMatch
        let first = try XCTUnwrap(viewer.value as? String)
        let strip = app.descendants(matching: .any)["viewer-carousel"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 1))
        XCTAssertGreaterThanOrEqual(strip.frame.height, 50)
        app.swipeLeft()
        XCTAssertNotEqual(viewer.value as? String, first, "Paging must work as soon as the viewer opens")
        let paged = viewer.value as? String
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.85)))
        XCTAssertNotEqual(viewer.value as? String, paged, "The strip's lower hit area must scrub the pager")
        snapshot(app, "polish-viewer-after-filmstrip-scrub")
        app.swipeUp()
        snapshot(app, "polish-viewer-information")
        app.buttons["viewer-info"].firstMatch.tap()
        close.tap()

        let visible = try XCTUnwrap(tiles.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 200 && $0.frame.midY < 600
        })
        visible.press(forDuration: 0.6)
        let share = app.buttons["共享"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        let more = app.buttons["更多"].firstMatch
        XCTAssertTrue(more.exists)
        XCTAssertTrue(app.frame.contains(more.frame), "The complete context menu must fit on screen")
        snapshot(app, "polish-complete-thumbnail-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.1)).tap()
        app.buttons["photos-search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.segmentedControls["photos-source-picker"].exists)
        XCTAssertFalse(app.buttons["photos-source-menu"].exists)
        snapshot(app, "polish-search-immediate-keyboard")
        app.terminate()

        let reopened = try launch()
        let grid = reopened.scrollViews.firstMatch
        grid.swipeDown()
        let periods = reopened.segmentedControls["photos-period-picker"]
        if !periods.exists { grid.swipeDown() }
        XCTAssertTrue(periods.waitForExistence(timeout: 5))
        for title in ["年", "月", "全部"] {
            periods.buttons[title].tap()
            snapshot(reopened, "polish-period-" + title)
        }
        let homeButton = reopened.buttons["photos-show-navigation"]
        if homeButton.exists { homeButton.tap() }
        reopened.buttons["shell-albums"].tap()
        let home = reopened.scrollViews["collections-home"]
        let map = reopened.buttons["collections-places-map"]
        for _ in 0..<8 where !map.isHittable { home.swipeUp() }
        XCTAssertTrue(map.isHittable); map.tap()
        XCTAssertFalse(reopened.buttons["shell-albums"].isHittable)
        XCTAssertTrue(reopened.buttons["apple-maps-enable"].exists || reopened.buttons["map-settings"].exists,
                      "Map preview must navigate directly to the map, including its existing consent gate")
        snapshot(reopened, "polish-collections-full-screen-map")
        reopened.terminate()
    }

    func testCollectionTimelineSelectionOwnsBottomControls() throws {
        let previous = try launch()
        previous.buttons["photos-source-menu"].tap()
        previous.buttons["账号与设置"].tap()
        tap(previous, "settings-sign-out")
        let confirmation = previous.buttons.matching(identifier: "settings-confirm-sign-out")
            .allElementsBoundByIndex.first(where: \.isHittable)
        try XCTUnwrap(confirmation).tap()
        XCTAssertTrue(previous.textFields["auth-server"].waitForExistence(timeout: 20))
        previous.terminate()
        let app = try launch()
        // This flow exercises the owned cloud collection; the source preference
        // can persist as On Device after another UI acceptance flow.
        app.buttons["photos-source-menu"].tap()
        chooseSourceItem(app, "云端")
        XCTAssertTrue(app.descendants(matching: .any)["photos-initial-preparation"].firstMatch.waitForNonExistence(timeout: 25))
        XCTAssertTrue(app.buttons["shell-albums"].waitForExistence(timeout: 20))
        app.buttons["shell-albums"].tap()
        tap(app, "collections-media-photos")
        XCTAssertTrue(app.buttons["timeline-select"].waitForExistence(timeout: 15))
        app.buttons["timeline-select"].tap()
        XCTAssertTrue(app.buttons["selection-cancel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shell-photos"].exists, "Collection selection owns the bottom controls")
        snapshot(app, "feedback-collection-selection")
        app.buttons["selection-cancel"].tap()
        XCTAssertTrue(app.buttons["shell-photos"].waitForExistence(timeout: 5))
    }

    func testScrollingToNewestRestoresCompactNavigationAndDateButtonsAlign() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 20))
        let newest = app.buttons.matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "label CONTAINS '2026年11月'"))
        let ready = NSPredicate { _, _ in newest.allElementsBoundByIndex.contains(where: \.isHittable) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed,
                       "Wait for cold-login restoration before exercising scroll gestures")
        let picker = app.segmentedControls["photos-period-picker"]
        for _ in 0..<3 where !picker.exists { app.swipeDown() }
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        let search = app.buttons["photos-search"]
        XCTAssertEqual(picker.frame.midY, search.frame.midY, accuracy: 2)
        let navigation = app.buttons["photos-show-navigation"]
        // Measured on system Photos, same iPhone17/iOS27.2: 48pt controls,
        // 28pt side/bottom margins and 14pt gaps (222pt center at 402pt width).
        XCTAssertEqual(picker.frame.height, 48, accuracy: 1)
        XCTAssertEqual(search.frame.height, 48, accuracy: 1)
        XCTAssertEqual(navigation.frame.height, 48, accuracy: 1)
        XCTAssertEqual(navigation.frame.minX, 28, accuracy: 1)
        XCTAssertEqual(app.frame.width - search.frame.maxX, 28, accuracy: 1)
        XCTAssertEqual(picker.frame.minX - navigation.frame.maxX, 14, accuracy: 1)
        XCTAssertEqual(search.frame.minX - picker.frame.maxX, 14, accuracy: 1)
        XCTAssertEqual(app.frame.height - search.frame.maxY, 28, accuracy: 1)
        let bounds = XCTAttachment(string: "System reference: 48pt high; side/bottom28pt; gap14pt. Current navigation=\(navigation.frame); picker=\(picker.frame); search=\(search.frame).")
        bounds.name = "native-reference-date-row-comparison"; bounds.lifetime = .keepAlways; add(bounds)
        snapshot(app, "feedback-compact-date-navigation")
        for _ in 0..<12 where !app.buttons["shell-photos"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["shell-photos"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["shell-albums"].exists)
        XCTAssertFalse(picker.exists)
        snapshot(app, "feedback-newest-navigation-restored")
        app.buttons["photos-search"].tap()
        XCTAssertTrue(app.photoSearchField.waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2), "Entering search must focus the field immediately")
        snapshot(app, "feedback-search-transition")
    }

    func testLongLibraryRestoresSourceAnchorAndDrillsIntoPeriods() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 20))
        app.buttons["photos-source-menu"].tap()
        chooseSourceItem(app, "云端")
        let tiles = app.buttons.matching(identifier: "asset-tile")
        func visibleLabels() -> [String] {
            tiles.allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.midY > 180 && $0.frame.midY < app.frame.height - 140
            }.map(\.label)
        }
        XCTAssertTrue(visibleLabels().contains { $0.contains("2026年11月") }, "A cold cloud library opens at its newest end")
        app.swipeDown()
        app.swipeDown()
        let anchorLoaded = NSPredicate { _, _ in !visibleLabels().isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: anchorLoaded, object: nil)], timeout: 25), .completed,
                       "Scrolling into an unloaded date bucket must finish before capturing its anchor")
        let anchor = try XCTUnwrap(visibleLabels().first)
        snapshot(app, "native-long-library-anchor")
        app.buttons["photos-source-menu"].tap()
        chooseSourceItem(app, "本机")
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 10))
        snapshot(app, "native-device-library")
        app.buttons["photos-source-menu"].tap()
        chooseSourceItem(app, "云端")
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
        let months = app.buttons.matching(NSPredicate(format: "identifier MATCHES '^photos-period-(photo-|day-)?[0-9]{4}-[0-9]{2}.*$'"))
        let monthReady = NSPredicate { _, _ in months.allElementsBoundByIndex.contains(where: \.isHittable) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: monthReady, object: nil)], timeout: 5), .completed)
        snapshot(app, "native-months")
        try XCTUnwrap(months.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        snapshot(app, "native-period-revealed")
    }
}
