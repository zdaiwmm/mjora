import CoreGraphics
import Foundation
import UIKit
import XCTest

/// Phase123 acceptance against the dedicated synthetic fixture only.
/// Seed Phase123_Beach.jpg and an UNBACKED Phase123_Mountain.jpg in PhotoKit.
/// Appearance is intentionally left to the runner so the switch check can run
/// once in Light and once in Dark. Each case restores the Library cloud source.
@MainActor
final class PhotosPhase123FlowTests: XCTestCase {
    private typealias Fixture = OwnedUIFixture
    private enum Failure: Error { case invalidScreenshot, invalidFixtureResponse }

    private func fixture() throws -> Fixture {
        try OwnedUIFixture.load()
    }

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        let fixture = try fixture()
        let app = XCUIApplication()
        OwnedUIFixture.configure(app)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 4) {
            enter(fixture.apiURL, in: app.textFields["auth-server"], app: app)
            app.buttons["auth-continue"].tap()
            enter(OwnedUIFixture.placeholderEmail, in: app.textFields["auth-email"], app: app)
            enter(OwnedUIFixture.placeholderPassword, in: app.secureTextFields["auth-password"], app: app)
            app.buttons["auth-sign-in"].tap()
        }
        let environment = XCTAttachment(string: "Runner reducedMotion=\(UIAccessibility.isReduceMotionEnabled), interfaceStyle=\(UITraitCollection.current.userInterfaceStyle.rawValue). App appearance is verified by its captured pixels.")
        environment.name = "phase123-runner-accessibility-appearance"; environment.lifetime = .keepAlways; add(environment)
        waitUntil("Signed-in Library navigation") {
            self.dismissKnownPrompts(app)
            let library = app.buttons["shell-photos"]
            if library.exists && library.isHittable && !app.buttons["photos-source-menu"].isHittable { library.tap() }
            return app.buttons["photos-source-menu"].exists && app.buttons["photos-source-menu"].isHittable
        }
        return app
    }

    private func enter(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        field.tap(); field.typeText(text)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 25, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout),
                       .completed, description)
    }

    private func dismissKnownPrompts(_ app: XCUIApplication) {
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
        if later.exists && later.isHittable { later.tap() }
        // Only known PhotoKit authorization/modify prompts on this synthetic run.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "允许更改", "Allow", "Modify"])).firstMatch
        if allow.exists && allow.isHittable { allow.tap() }
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func button(_ app: XCUIApplication, labels: [String]) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
        return matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let ready = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout) == .completed
    }

    private func tapID(_ app: XCUIApplication, _ id: String) {
        let element = app.buttons.matching(identifier: id).firstMatch
        // These IDs are toolbar/menu/geometry controls, not scroll targets.
        // Waiting avoids moving an element offscreen during a sheet animation.
        XCTAssertTrue(waitForHittable(element), id)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if waitForHittable(element, timeout: 2) { return }
        for _ in 0..<6 {
            let frame = element.frame
            if element.exists && frame.midY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
            if waitForHittable(element, timeout: 1) { return }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Content target must have a usable hit point")
    }

    private func source(_ app: XCUIApplication, device: Bool) {
        let title = app.buttons["photos-source-menu"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let item = button(app, labels: device ? ["本机", "On Device"] : ["云端照片", "Cloud Photos"])
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        waitUntil("Source menu returns after selection") { title.exists && title.isHittable }
    }

    /// Relaunch gives failure cleanup a stable root, even if a sheet was open.
    private func finishOnCloud(_ app: XCUIApplication) {
        app.terminate(); app.launch()
        dismissKnownPrompts(app)
        let library = app.buttons["shell-photos"]
        if library.waitForExistence(timeout: 10), library.isHittable { library.tap() }
        let title = app.buttons["photos-source-menu"]
        if title.waitForExistence(timeout: 15), title.isHittable {
            title.tap()
            let cloud = button(app, labels: ["云端照片", "Cloud Photos"])
            if cloud.waitForExistence(timeout: 3), cloud.isHittable { cloud.tap() }
        }
    }

    private func visibleTiles(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.filter {
            $0.frame.midY > 120 && $0.frame.midY < app.frame.height - 100 && $0.isHittable
        }
    }

    private func searchDevice(_ app: XCUIApplication, filename: String) {
        source(app, device: true)
        tapID(app, "photos-search")
        let scope = app.buttons["search-source"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10))
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("本机"), "Search must inherit the device source")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        enter(filename, in: field, app: app)
        field.typeText("\n")
        let exactResult = NSPredicate { _, _ in self.visibleTiles(app).count == 1 }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exactResult, object: nil)], timeout: 25)
        if result != .completed { snapshot(app, "phase123-filename-search-failed") }
        XCTAssertEqual(result, .completed, "Exact seeded filename has one accessible result")
        XCTAssertTrue(app.descendants(matching: .any)["local-search-results"].exists)
    }

    private func openOnlyResult(_ app: XCUIApplication) throws {
        try XCTUnwrap(visibleTiles(app).first).tap()
        waitUntil("Stable viewer toolbar") {
            let close = app.navigationBars.buttons.matching(identifier: "viewer-close")
            return close.count == 1 && close.firstMatch.isHittable
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Opening a photo dismisses the search keyboard")
    }

    private func closeViewer(_ app: XCUIApplication) {
        let close = app.navigationBars.buttons.matching(identifier: "viewer-close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
    }

    func testSettingsSwitchTrackHasColorWhenOnAndRestoresInitialValue() async throws {
        let api = try FixtureAPI(fixture: fixture())
        try await api.login()
        let app = try launch()
        defer { finishOnCloud(app) }
        app.buttons["photos-source-menu"].tap()
        button(app, labels: ["账号与设置", "Account & Settings"]).tap()
        let toggle = app.switches.matching(NSPredicate(format: "label IN %@", ["回忆", "Memories"])).firstMatch
        XCTAssertTrue(waitForHittable(toggle, timeout: 10))
        let initial = toggle.value as? String == "1"
        func tapSwitchControl() {
            // SwiftUI exposes the labeled row as one AX switch. Its center
            // is label space; press the actual trailing UISwitch control.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        defer {
            if toggle.exists && toggle.isHittable && (toggle.value as? String == "1") != initial { tapSwitchControl() }
        }
        func set(_ on: Bool) {
            if (toggle.value as? String == "1") != on { tapSwitchControl() }
            waitUntil("Settings switch value updates", timeout: 10) { (toggle.value as? String == "1") == on }
        }
        set(false)
        try await api.waitForMemories(false)
        snapshot(app, "phase123-settings-switch-off")
        let off = try chromaticTrackFraction(app, toggle: toggle)
        set(true)
        snapshot(app, "phase123-settings-switch-on")
        let region = XCTAttachment(string: "AX row bounds: \(toggle.frame); screen: \(app.frame). Sampling the trailing 100pt band at the row center, excluding the leading colored icon.")
        region.name = "phase123-switch-sampling-region"; region.lifetime = .keepAlways; add(region)
        waitUntil("Enabled switch track has a chromatic accent", timeout: 6) {
            guard let fraction = try? self.chromaticTrackFraction(app, toggle: toggle) else { return false }
            return fraction > max(0.18, off + 0.10)
        }
        try await api.waitForMemories(true)
        let on = try chromaticTrackFraction(app, toggle: toggle)
        XCTAssertGreaterThan(on, 0.18, "On track must contain color, not a white/gray enabled state")
        XCTAssertGreaterThan(on, off + 0.10)
        let metric = XCTAttachment(string: "Trailing track chromatic fraction: off=\(off), on=\(on). Initial state restored by defer.")
        metric.name = "phase123-switch-track-fractions"; metric.lifetime = .keepAlways; add(metric)
        snapshot(app, "phase123-settings-switch-on")
        set(initial)
        try await api.waitForMemories(initial)
        app.buttons["settings-close"].tap()
    }

    /// SwiftUI exposes the entire labeled row as the AX switch. The current
    /// system switch is wider than the old 51pt control and sits inside the
    /// row's trailing inset. Sample the trailing band, excluding the icon and
    /// neighboring rows, rather than assuming the row edge is the track edge.
    private func chromaticTrackFraction(_ app: XCUIApplication, toggle: XCUIElement) throws -> Double {
        let screenshot = app.screenshot().image
        guard let image = screenshot.cgImage else { throw Failure.invalidScreenshot }
        let frame = toggle.frame
        let width = min(CGFloat(100), frame.width)
        let track = CGRect(x: frame.maxX - width, y: frame.midY - 8, width: width, height: 16)
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let pixels = CGRect(x: (track.minX - app.frame.minX) * sx, y: (track.minY - app.frame.minY) * sy,
                            width: track.width * sx, height: track.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let crop = image.cropping(to: pixels), crop.width > 0, crop.height > 0 else { throw Failure.invalidScreenshot }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height))); return true
        }
        guard drew else { throw Failure.invalidScreenshot }
        var chromatic = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let channels = [Double(bytes[pixel]), Double(bytes[pixel + 1]), Double(bytes[pixel + 2])]
            if (channels.max()! - channels.min()!) / 255 > 0.13 && channels.max()! > 40 { chromatic += 1 }
        }
        return Double(chromatic) / Double(crop.width * crop.height)
    }

    func testDeviceFavoriteInheritedFilenameSearchAndEnhancedEditRoundTrip() throws {
        let app = try launch()
        defer { finishOnCloud(app) }
        searchDevice(app, filename: "Phase123_Beach.jpg")
        snapshot(app, "phase123-inherited-device-filename-search")
        try openOnlyResult(app)
        let favorite = app.buttons.matching(identifier: "viewer-favorite").firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        let initialLabel = favorite.label
        favorite.tap()
        waitUntil("Device favorite changes") { favorite.label != initialLabel && favorite.isEnabled }
        let changedLabel = favorite.label
        closeViewer(app); try openOnlyResult(app)
        waitUntil("PhotoKit favorite survives reopening", timeout: 10) { favorite.label == changedLabel }
        favorite.tap()
        waitUntil("Restore initial device favorite") { favorite.label == initialLabel && favorite.isEnabled }
        app.buttons.matching(identifier: "viewer-edit").firstMatch.tap()
        waitForEditorReady(app)
        try resetExistingSyntheticEdits(app)
        let highlights = try setAdjustment(app, labels: ["高光", "Highlights"])
        let warmth = try setAdjustment(app, labels: ["色温", "Warmth"])
        button(app, labels: ["裁剪", "Crop"]).tap()
        tapID(app, "edit-geometry-straighten")
        let straighten = try moveRuler(app, id: "edit-geometry-ruler")
        snapshot(app, "phase123-local-enhanced-edits")
        saveEditor(app)
        app.buttons.matching(identifier: "viewer-edit").firstMatch.tap()
        waitForEditorReady(app)
        try assertAdjustment(app, labels: ["高光", "Highlights"], equals: highlights)
        try assertAdjustment(app, labels: ["色温", "Warmth"], equals: warmth)
        button(app, labels: ["裁剪", "Crop"]).tap(); tapID(app, "edit-geometry-straighten")
        XCTAssertEqual(try rulerValue(app, id: "edit-geometry-ruler"), straighten, accuracy: 1)
        revertEditor(app); saveEditor(app)
        app.buttons.matching(identifier: "viewer-edit").firstMatch.tap()
        waitForEditorReady(app)
        try assertAdjustment(app, labels: ["高光", "Highlights"], equals: 0)
        try assertAdjustment(app, labels: ["色温", "Warmth"], equals: 0)
        button(app, labels: ["裁剪", "Crop"]).tap(); tapID(app, "edit-geometry-straighten")
        XCTAssertEqual(try rulerValue(app, id: "edit-geometry-ruler"), 0)
        snapshot(app, "phase123-local-reverted-after-reopen")
        app.buttons["edit-cancel"].tap()
        XCTAssertTrue(app.buttons["edit-done"].waitForNonExistence(timeout: 10))
        closeViewer(app)
    }

    private func selectAdjustment(_ app: XCUIApplication, labels: [String]) throws {
        button(app, labels: ["调整", "Adjust"]).tap()
        let item = button(app, labels: labels)
        for _ in 0..<12 where !item.exists || !item.isHittable {
            let carousel = app.scrollViews.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.height <= 100 && $0.frame.midY > app.frame.height * 0.55
            }
            try XCTUnwrap(carousel, "Adjustment carousel").swipeLeft()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5)); XCTAssertTrue(item.isHittable)
        if !item.isSelected { item.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["edit-adjust-ruler"].firstMatch.waitForExistence(timeout: 5))
    }

    private func setAdjustment(_ app: XCUIApplication, labels: [String]) throws -> Double {
        try selectAdjustment(app, labels: labels)
        return try moveRuler(app, id: "edit-adjust-ruler")
    }
    private func assertAdjustment(_ app: XCUIApplication, labels: [String], equals value: Double) throws {
        try selectAdjustment(app, labels: labels)
        XCTAssertEqual(try rulerValue(app, id: "edit-adjust-ruler"), value, accuracy: 1)
    }
    private func rulerValue(_ app: XCUIApplication, id: String) throws -> Double {
        let ruler = app.descendants(matching: .any)[id].firstMatch
        return try XCTUnwrap(Double(ruler.value as? String ?? ""), "Ruler must expose its numeric value")
    }
    private func moveRuler(_ app: XCUIApplication, id: String) throws -> Double {
        let ruler = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 5)); XCTAssertTrue(ruler.isHittable)
        let before = try rulerValue(app, id: id)
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5)))
        waitUntil("Ruler changes a real adjustment", timeout: 5) {
            guard let value = try? self.rulerValue(app, id: id) else { return false }
            return value != before
        }
        let after = try rulerValue(app, id: id)
        XCTAssertNotEqual(after, before); XCTAssertNotEqual(after, 0)
        return after
    }
    private func waitForEditorReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["edit-more"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForHittable(app.buttons["edit-more"], timeout: 10))
    }
    private func saveEditor(_ app: XCUIApplication) {
        let done = app.buttons["edit-done"]
        waitUntil("Changed edit is ready to save", timeout: 5) { done.isEnabled }
        done.tap()
        waitUntil("PhotoKit save returns to viewer", timeout: 60) {
            self.dismissKnownPrompts(app)
            return !done.exists && app.navigationBars.buttons.matching(identifier: "viewer-close").firstMatch.isHittable
        }
    }
    private func revertEditor(_ app: XCUIApplication) {
        app.buttons["edit-more"].tap()
        let revert = button(app, labels: ["还原为原始版本", "Revert to Original"])
        XCTAssertTrue(revert.waitForExistence(timeout: 5)); XCTAssertTrue(revert.isEnabled); revert.tap()
        let confirm = button(app, labels: ["还原为原始版本", "Revert to Original"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        waitUntil("Revert produces a saveable change", timeout: 5) { app.buttons["edit-done"].isEnabled }
    }
    private func resetExistingSyntheticEdits(_ app: XCUIApplication) throws {
        app.buttons["edit-more"].tap()
        let revert = button(app, labels: ["还原为原始版本", "Revert to Original"])
        XCTAssertTrue(revert.waitForExistence(timeout: 5))
        if revert.isEnabled {
            revert.tap(); button(app, labels: ["还原为原始版本", "Revert to Original"]).tap()
            saveEditor(app); app.buttons.matching(identifier: "viewer-edit").firstMatch.tap()
            waitForEditorReady(app)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        }
    }

    func testUnbackedDeviceAppAlbumRequiresConsentAndCreatesOneServerMember() async throws {
        let api = try FixtureAPI(fixture: fixture())
        try await api.login()
        let filename = "Phase123_Mountain_Acceptance.jpg"
        guard try await api.assets(filename: filename).isEmpty else {
            throw XCTSkip("Reseed Phase123_Mountain_Acceptance.jpg as unbacked before repeating this explicit-backup acceptance case.")
        }
        let app = try launch()
        defer { finishOnCloud(app) }
        searchDevice(app, filename: filename); try openOnlyResult(app)
        openAppAlbumPicker(app)
        XCTAssertTrue(app.navigationBars["添加到应用相簿"].waitForExistence(timeout: 15))
        let name = "Phase123-UI-\(UUID().uuidString.prefix(8))"
        func chooseCreate() {
            tapID(app, "add-to-album-new")
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if field.value as? String != name { field.tap(); field.typeText(name) }
        }
        chooseCreate()
        let consent = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["备份并创建相簿", "Back Up and Create Album"])).firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        snapshot(app, "phase123-local-album-explicit-backup-consent")
        let beforeConsentAssets = try await api.assets(filename: filename)
        XCTAssertTrue(beforeConsentAssets.isEmpty, "Opening/choosing an App album must not silently upload")
        let beforeAlbums = try await api.albums()
        XCTAssertFalse(beforeAlbums.contains { $0["albumName"] as? String == name })
        app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch.tap()
        XCTAssertTrue(app.buttons["add-to-album-new"].waitForExistence(timeout: 5), "Cancel retains the picker and local selection")
        chooseCreate(); XCTAssertTrue(consent.waitForExistence(timeout: 5)); consent.tap()
        waitUntil("Explicit backup and album creation finishes", timeout: 150) {
            self.dismissKnownPrompts(app)
            return !app.navigationBars["添加到应用相簿"].exists && app.navigationBars.buttons.matching(identifier: "viewer-close").firstMatch.isHittable
        }
        var created: [String: Any]?
        for _ in 0..<30 {
            created = try await api.albums().first { $0["albumName"] as? String == name }
            if created != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let album = try XCTUnwrap(created), id = try XCTUnwrap(album["id"] as? String)
        XCTAssertEqual((album["assetCount"] as? NSNumber)?.intValue, 1)
        let members = try await api.assets(albumID: id)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?["originalFileName"] as? String, filename)
        snapshot(app, "phase123-local-album-created-and-dismissed")
        closeViewer(app); try openOnlyResult(app)
        openAppAlbumPicker(app)
        XCTAssertTrue(app.buttons["add-to-album-new"].waitForExistence(timeout: 15))
        // The just-created album is the newest item at the top. Avoid querying
        // the covered Library search field while the picker is presented.
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 10), "Reopening must show the committed App album")
        let cancellations = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
        let cancel = try XCTUnwrap(cancellations.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.minX < app.frame.width * 0.5
        }, "Picker cancellation action, distinct from Search Cancel")
        cancel.tap()
        XCTAssertTrue(app.navigationBars.buttons.matching(identifier: "viewer-close").firstMatch.waitForExistence(timeout: 8))
        closeViewer(app)
    }

    private func openAppAlbumPicker(_ app: XCUIApplication) {
        tapID(app, "viewer-menu")
        // Native menu rows do not preserve SwiftUI Button identifiers on this
        // runtime. Use the actual localized menu action shown to the user.
        let add = button(app, labels: ["添加到相册", "添加到相簿", "Add to Album"])
        XCTAssertTrue(waitForHittable(add, timeout: 5)); add.tap()
    }

    func testCollectionPreviewSizesPersistAcrossColdLaunches() async throws {
        let api = try FixtureAPI(fixture: fixture())
        try await api.login()
        let fixtureAlbums = try await api.albums().compactMap { $0["albumName"] as? String }
        let labels = ["个人收藏", "Favorites", "最近添加", "Recently Added"] + fixtureAlbums
        let app = try launch()
        defer { finishOnCloud(app) }
        tapID(app, "shell-albums")
        XCTAssertTrue(app.scrollViews["collections-home"].waitForExistence(timeout: 10))
        var collapsed: [String] = []
        for id in ["collections-collapse-pinned", "collections-collapse-albums"] {
            let header = app.buttons[id]
            if header.exists && (header.label.hasPrefix("展开") || header.label.hasPrefix("Expand")) {
                reveal(header, in: app); header.tap(); collapsed.append(id)
            }
        }
        openPreviewEditor(app)
        let segmented = app.segmentedControls["collections-preview-size"]
        let initial = try XCTUnwrap(segmented.buttons.allElementsBoundByIndex.first(where: \.isSelected)?.label)
        button(app, labels: ["完成", "Done"]).tap()
        var heights: [CGFloat] = []
        var previewLabel: String?
        for (index, label) in ["大", "小", "不显示"].enumerated() {
            openPreviewEditor(app)
            let choice = segmented.buttons[label]
            XCTAssertTrue(waitForHittable(choice, timeout: 5)); choice.tap()
            waitUntil("Preview size selection updates", timeout: 5) { choice.isSelected }
            button(app, labels: ["完成", "Done"]).tap()
            snapshot(app, "phase123-collections-preview-selection-\(index)")
            if previewLabel == nil {
                let candidates = app.descendants(matching: .any).matching(NSCompoundPredicate(orPredicateWithSubpredicates:
                    labels.map { NSPredicate(format: "label CONTAINS %@", $0) }))
                for _ in 0..<5 {
                    if let tile = candidates.allElementsBoundByIndex.first(where: {
                        $0.isHittable && $0.frame.height > 90 && $0.frame.height < 250 && $0.frame.width < 300
                    }) {
                        previewLabel = labels.first { tile.label.contains($0) }; break
                    }
                    let known = candidates.allElementsBoundByIndex.first
                    if let known, known.frame.midY < app.frame.midY { app.swipeDown() }
                    else { app.swipeUp() }
                    _ = waitForHittable(candidates.firstMatch, timeout: 1)
                }
            }
            let name = try XCTUnwrap(previewLabel, "Fixture must contain at least one pinned or App album preview")
            let preview = try previewElement(app, title: name); reveal(preview, in: app)
            heights.append(preview.frame.height)
            if index == 0 { XCTAssertGreaterThan(preview.frame.height, 100) }
            else { XCTAssertLessThan(preview.frame.height, heights[index - 1] - 15) }
            if index == 2 { XCTAssertGreaterThan(preview.frame.width, preview.frame.height * 2) }
            snapshot(app, "phase123-collections-preview-\(index)")
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["shell-albums"].waitForExistence(timeout: 20)); app.buttons["shell-albums"].tap()
            let restored = try previewElement(app, title: name); reveal(restored, in: app)
            XCTAssertEqual(restored.frame.height, heights[index], accuracy: 2)
            snapshot(app, "phase123-collections-preview-\(index)-relaunch")
            openPreviewEditor(app)
            XCTAssertTrue(segmented.buttons[label].isSelected, "Account preview preference must survive launch")
            button(app, labels: ["完成", "Done"]).tap()
        }
        openPreviewEditor(app); segmented.buttons[initial].tap(); button(app, labels: ["完成", "Done"]).tap()
        for id in collapsed {
            let header = app.buttons[id]; reveal(header, in: app)
            if !header.label.hasPrefix("展开") && !header.label.hasPrefix("Expand") { header.tap() }
        }
    }

    private func previewElement(_ app: XCUIApplication, title: String) throws -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title))
            .allElementsBoundByIndex.sorted { $0.frame.height > $1.frame.height }
        return try XCTUnwrap(matches.first(where: { $0.isHittable && $0.frame.height < 250 }) ?? matches.first,
                             "Preview with the visible title must remain accessible")
    }

    private func openPreviewEditor(_ app: XCUIApplication) {
        tapID(app, "collections-layout-menu")
        let customize = button(app, labels: ["自定精选集", "Customize Collections"])
        XCTAssertTrue(waitForHittable(customize, timeout: 5)); customize.tap()
        XCTAssertTrue(app.segmentedControls["collections-preview-size"].waitForExistence(timeout: 5))
    }

    @MainActor private final class FixtureAPI {
        private let fixture: Fixture
        private let session: URLSession
        private var token: String?
        init(fixture: Fixture) throws {
            guard fixture.apiURL == "http://127.0.0.1:33284/api", fixture.email.hasSuffix("@imora-phase4-fixture.invalid"),
                  UUID(uuidString: fixture.ownerID) != nil else {
                throw Failure.invalidFixtureResponse
            }
            self.fixture = fixture
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]; config.urlCredentialStorage = nil
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 20
            session = URLSession(configuration: config, delegate: Phase123NoRedirect(), delegateQueue: nil)
        }
        func login() async throws {
            let response = try await request("auth/login", method: "POST", body: ["email": fixture.email, "password": fixture.password])
            guard (response as? [String: Any])?["userId"] as? String == fixture.ownerID else { throw Failure.invalidFixtureResponse }
            token = try XCTUnwrap((response as? [String: Any])?["accessToken"] as? String)
        }
        func albums() async throws -> [[String: Any]] {
            let response = try await request("albums", method: "GET", body: nil)
            return try XCTUnwrap(response as? [[String: Any]])
        }
        func waitForMemories(_ enabled: Bool) async throws {
            for _ in 0..<30 {
                let response = try await request("users/me/preferences", method: "GET", body: nil)
                if ((response as? [String: Any])?["memories"] as? [String: Any])?["enabled"] as? Bool == enabled { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTFail("Synthetic server preference must confirm the UI change and initial restoration")
        }
        func assets(filename: String? = nil, albumID: String? = nil) async throws -> [[String: Any]] {
            var body: [String: Any] = ["size": 100, "page": 1, "withExif": true]
            if let filename { body["originalFileName"] = filename }
            if let albumID {
                guard UUID(uuidString: albumID) != nil else { throw Failure.invalidFixtureResponse }
                body["albumIds"] = [albumID]
            }
            let response = try await request("search/metadata", method: "POST", body: body)
            let items = try XCTUnwrap(((response as? [String: Any])?["assets"] as? [String: Any])?["items"] as? [[String: Any]])
            return filename.map { name in items.filter { $0["originalFileName"] as? String == name } } ?? items
        }
        private func request(_ path: String, method: String, body: [String: Any]?) async throws -> Any {
            guard !path.contains(".."), let base = URL(string: "http://127.0.0.1:33284/api/") else { throw Failure.invalidFixtureResponse }
            let url = base.appendingPathComponent(path)
            guard url.scheme == "http", url.host == "127.0.0.1", url.port == 33284, url.path.hasPrefix("/api/") else {
                throw Failure.invalidFixtureResponse
            }
            var request = URLRequest(url: url); request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "Phase123 synthetic HTTP status", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return try JSONSerialization.jsonObject(with: data)
        }
    }
}

private final class Phase123NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @Sendable @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
