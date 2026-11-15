import CoreGraphics
import Foundation
import UIKit
import XCTest

/// Actual system-setting acceptance. No launch flag substitutes for Reduce Motion.
@MainActor
final class PhotosReducedMotionTests: XCTestCase {
    private struct Fixture: Decodable { let apiURL: String; let email: String; let password: String }
    private var systemMotion: SystemReduceMotionControl?
    private var imora: XCUIApplication?
    private var originalDeviceSource: Bool?

    func testRealSystemReduceMotionAndLibraryPeriodSwitching() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This settings/reference flow is limited to the task simulator.")
        #else
        continueAfterFailure = false
        let fixture = try loadFixture()
        let controller = SystemReduceMotionControl()
        systemMotion = controller
        // XCTest teardown also executes after an assertion stops the test.
        addTeardownBlock { [self] in
            try await MainActor.run { try self.restoreSystemAndSource() }
        }
        try controller.setEnabled(true)
        capture(controller.settings, "reduce-motion-system-enabled")
        XCTAssertEqual(try controller.readEnabled(), true, "The actual Reduce Motion switch must be on")
        let signal = NSPredicate { _, _ in UIAccessibility.isReduceMotionEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: signal, object: nil)], timeout: 8), .completed,
                       "UIKit's real system accessibility signal must become true; a test launch argument is not enough")

        let app = try launchImora(fixture)
        imora = app
        let heading = app.buttons["photos-source-menu"]
        originalDeviceSource = heading.label.contains("本机") || heading.label.contains("On Device")
        selectSource(app, device: false) // Existing dated synthetic cloud library exposes the period row.
        let picker = app.segmentedControls["photos-period-picker"]
        for _ in 0..<5 where !picker.exists || !picker.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)))
            _ = waitForHittable(picker, timeout: 2)
        }
        XCTAssertTrue(waitForHittable(picker, timeout: 5), "A dated fixture library is required for year/month/all acceptance")
        capture(app, "reduce-motion-library-period-row")
        let years = picker.buttons.matching(NSPredicate(format: "label IN %@", ["年", "Years"])).firstMatch
        XCTAssertTrue(waitForHittable(years, timeout: 5)); years.tap()
        waitForPeriodCard(app, months: false)
        capture(app, "reduce-motion-library-years")
        let months = picker.buttons.matching(NSPredicate(format: "label IN %@", ["月", "Months"])).firstMatch
        XCTAssertTrue(waitForHittable(months, timeout: 5)); months.tap()
        waitForPeriodCard(app, months: true)
        capture(app, "reduce-motion-library-months")
        let all = picker.buttons.matching(NSPredicate(format: "label IN %@", ["全部", "All"])).firstMatch
        XCTAssertTrue(waitForHittable(all, timeout: 5)); all.tap()
        let gridReady = NSPredicate { _, _ in
            app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.contains {
                $0.isHittable && $0.frame.midY > 150 && $0.frame.midY < app.frame.height - 120
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gridReady, object: nil)], timeout: 20), .completed,
                       "All must restore an actually hittable grid photo")
        if all.exists { XCTAssertTrue(all.isSelected) }
        else { XCTAssertTrue(app.buttons["shell-photos"].isHittable, "Newest-edge Library navigation replaces the date row") }
        XCTAssertFalse(app.scrollViews["photos-periods"].exists, "All must remove the year/month overview")
        XCTAssertTrue(UIAccessibility.isReduceMotionEnabled)
        capture(app, "reduce-motion-library-all-grid")
        #endif
    }

    private func waitForPeriodCard(_ app: XCUIApplication, months: Bool) {
        let pattern = months ? "photos-period-[0-9]{4}-[0-9]{2}" : "photos-period-[0-9]{4}"
        let cards = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", pattern))
        let visible = NSPredicate { _, _ in cards.allElementsBoundByIndex.contains(where: \.isHittable) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 15), .completed,
                       "The selected period must expose a real hittable card, not an offscreen All Years header")
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: "/private/tmp/imora-341-ios-fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the dedicated synthetic fixture first.") }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard value.apiURL == "http://127.0.0.1:32283/api", value.email.hasSuffix("@imora-fixture.invalid") else {
            throw NSError(domain: "Unsafe fixture destination", code: 1)
        }
        return value
    }

    private func launchImora(_ fixture: Fixture) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.textFields["auth-server"].waitForExistence(timeout: 4) {
            app.textFields["auth-server"].tap(); app.textFields["auth-server"].typeText(fixture.apiURL)
            app.buttons["auth-continue"].tap()
            XCTAssertTrue(app.textFields["auth-email"].waitForExistence(timeout: 20))
            app.textFields["auth-email"].tap(); app.textFields["auth-email"].typeText(fixture.email)
            app.secureTextFields["auth-password"].tap(); app.secureTextFields["auth-password"].typeText(fixture.password)
            app.buttons["auth-sign-in"].tap()
        }
        let ready = NSPredicate { _, _ in
            let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Later"])).firstMatch
            if later.exists && later.isHittable { later.tap() }
            let library = app.buttons["shell-photos"]
            if library.exists && library.isHittable && !app.buttons["photos-source-menu"].isHittable { library.tap() }
            return app.buttons["photos-source-menu"].exists && app.buttons["photos-source-menu"].isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 25), .completed)
        return app
    }

    private func selectSource(_ app: XCUIApplication, device: Bool) {
        let heading = app.buttons["photos-source-menu"]
        XCTAssertTrue(waitForHittable(heading, timeout: 10)); heading.tap()
        let labels = device ? ["本机", "On Device"] : ["云端照片", "Cloud Photos"]
        let choices = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
        let choice = choices.allElementsBoundByIndex.first(where: \.isHittable) ?? choices.firstMatch
        XCTAssertTrue(waitForHittable(choice, timeout: 5)); choice.tap()
    }

    private func restoreSystemAndSource() throws {
        if let app = imora, let device = originalDeviceSource {
            app.activate()
            let library = app.buttons["shell-photos"]
            if library.exists && library.isHittable && !app.buttons["photos-source-menu"].isHittable { library.tap() }
            if waitForHittable(app.buttons["photos-source-menu"], timeout: 8) { selectSource(app, device: device) }
        }
        if let controller = systemMotion {
            try controller.restoreOriginal()
            capture(controller.settings, "reduce-motion-system-restored")
        }
        imora?.activate()
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "\(name)-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let state = XCTAttachment(string: "UIKit Reduce Motion=\(UIAccessibility.isReduceMotionEnabled). Original system switch=\(systemMotion?.originalEnabled.map(String.init) ?? "not read").")
        state.name = "\(name)-system-state"; state.lifetime = .keepAlways; add(state)
    }
}

/// Reusable exact-control helper for other fixture UI flows. It never queries
/// firstMatch across all switches or visits Display & Text Size/Transparency.
@MainActor
final class SystemReduceMotionControl {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private(set) var originalEnabled: Bool?
    private let switchLabels = ["减弱动态效果", "Reduce Motion"]

    func setEnabled(_ enabled: Bool) throws {
        let toggle = try locateSwitch()
        let initial = try value(of: toggle)
        if originalEnabled == nil { originalEnabled = initial }
        if initial != enabled { toggle.tap() }
        let predicate = NSPredicate { _, _ in
            toggle.exists && toggle.isHittable && (toggle.value as? String) == (enabled ? "1" : "0")
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10) == .completed else {
            throw failure("Actual Reduce Motion switch did not reach the requested state")
        }
        guard try value(of: toggle) == enabled else { throw failure("Actual Reduce Motion value disagrees after setting") }
    }

    func readEnabled() throws -> Bool { try value(of: locateSwitch()) }
    func restoreOriginal() throws {
        guard let originalEnabled else { return } // No setting was changed before a failed navigation.
        try setEnabled(originalEnabled)
        guard try readEnabled() == originalEnabled else { throw failure("Original Reduce Motion state was not restored") }
    }

    private func locateSwitch() throws -> XCUIElement {
        if settings.state == .notRunning {
            settings.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            settings.launch()
        } else { settings.activate() }
        for _ in 0..<6 {
            let exact = settings.switches.matching(NSPredicate(format: "label IN %@", switchLabels)).firstMatch
            if exact.exists && exact.isHittable { return exact }
            if let motion = visibleRow(["动态效果", "Motion"]) { motion.tap(); continue }
            if let accessibility = visibleRow(["辅助功能", "Accessibility"]) { accessibility.tap(); continue }
            if ["设置", "Settings"].contains(where: {
                let bar = settings.navigationBars[$0]
                return bar.exists && bar.isHittable
            }) { break }
            let back = settings.navigationBars.buttons.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minX < settings.frame.width * 0.4
                    && !["搜索", "Search", "编辑", "Edit", "取消", "Cancel"].contains($0.label)
            }
            guard let back else { break }
            back.tap()
        }
        try tapRow(["辅助功能", "Accessibility"])
        try tapRow(["动态效果", "Motion"])
        let toggle = settings.switches.matching(NSPredicate(format: "label IN %@", switchLabels)).firstMatch
        let predicate = NSPredicate { _, _ in toggle.exists && toggle.isHittable }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8) == .completed else {
            throw failure("Expected Accessibility → Motion → Reduce Motion exact switch; inspect Settings AX. Reduce Transparency is not an acceptable substitute")
        }
        return toggle
    }

    private func visibleRow(_ labels: [String]) -> XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@", labels)
        let navigationBottom = settings.navigationBars.allElementsBoundByIndex.filter(\.exists).map { $0.frame.maxY }.max() ?? 0
        return (settings.cells.matching(predicate).allElementsBoundByIndex
                + settings.buttons.matching(predicate).allElementsBoundByIndex
                + settings.staticTexts.matching(predicate).allElementsBoundByIndex).first {
            $0.isHittable && $0.frame.midY > navigationBottom + 1
        }
    }
    private func tapRow(_ labels: [String]) throws {
        for _ in 0..<8 {
            if let row = visibleRow(labels) { row.tap(); return }
            let candidate = settings.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if candidate.exists && candidate.frame.midY < settings.frame.midY { settings.swipeDown() }
            else { settings.swipeUp() }
            let ready = NSPredicate { _, _ in self.visibleRow(labels) != nil }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 1)
        }
        throw failure("Settings row not reachable: \(labels.joined(separator: " / "))")
    }
    private func value(of toggle: XCUIElement) throws -> Bool {
        guard switchLabels.contains(toggle.label), let raw = toggle.value as? String, ["0", "1"].contains(raw) else {
            throw failure("Reduce Motion must expose an exact labeled switch with binary AX state")
        }
        return raw == "1"
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "Real system Reduce Motion acceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
