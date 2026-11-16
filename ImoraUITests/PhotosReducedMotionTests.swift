import CoreGraphics
import Foundation
import Darwin
import UIKit
import XCTest

/// Actual system-setting acceptance. No launch flag substitutes for Reduce Motion.
@MainActor
// XCTest's teardown closure is Sendable; all test state and cleanup are
// confined to MainActor, including the explicit MainActor.run below.
final class PhotosReducedMotionTests: XCTestCase, @unchecked Sendable {
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
        let controller = try SystemReduceMotionControl()
        systemMotion = controller
        // XCTest teardown also executes after an assertion stops the test.
        addTeardownBlock { [self] in
            try await MainActor.run { try self.restoreSystemAndSource() }
        }
        try controller.setEnabled(true)
        XCTAssertEqual(try controller.readEnabled(), true, "The actual global Reduce Motion preference must be on")
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
        // Restore the global preference before any UI operation can fail.
        if let controller = systemMotion {
            try controller.restoreOriginal()
            if let app = imora { capture(app, "reduce-motion-system-restored") }
        }
        if let app = imora, let device = originalDeviceSource {
            app.activate()
            let library = app.buttons["shell-photos"]
            if library.exists && library.isHittable && !app.buttons["photos-source-menu"].isHittable { library.tap() }
            if waitForHittable(app.buttons["photos-source-menu"], timeout: 8) { selectSource(app, device: device) }
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
        let state = XCTAttachment(string: "UIKit Reduce Motion=\(UIAccessibility.isReduceMotionEnabled). Global OS preference=\((try? systemMotion?.readEnabled()).map(String.init) ?? "unavailable"). Original system preference=\(systemMotion?.originalEnabled.map(String.init) ?? "not read"). Set through simulator libAccessibility _AXSSetReduceMotionEnabled; no app launch flag or environment override.")
        state.name = "\(name)-system-state"; state.lifetime = .keepAlways; add(state)
    }
}

/// Simulator-only acceptance utility. This runtime does not expose Accessibility
/// in Settings, so change the actual OS preference through libAccessibility.
/// Both exports are verified in the installed SDK's libAccessibility.tbd.
/// No private API or test accessibility override is linked into the app target.
@MainActor
final class SystemReduceMotionControl {
    private typealias Getter = @convention(c) () -> Bool
    private typealias Setter = @convention(c) (Bool) -> Void
    // Keep the library loaded for the lifetime of the UI-test process.
    private let library: UnsafeMutableRawPointer
    private let getter: Getter
    private let setter: Setter
    private(set) var originalEnabled: Bool?

    init() throws {
        #if targetEnvironment(simulator)
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getSymbol = dlsym(library, "_AXSReduceMotionEnabledGlobal"),
              let setSymbol = dlsym(library, "_AXSSetReduceMotionEnabled") else {
            throw NSError(domain: "Real system Reduce Motion acceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required simulator OS accessibility exports unavailable"])
        }
        self.library = library
        getter = unsafeBitCast(getSymbol, to: Getter.self)
        setter = unsafeBitCast(setSymbol, to: Setter.self)
        #else
        throw NSError(domain: "Real system Reduce Motion acceptance", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "This OS preference utility is restricted to the task simulator"])
        #endif
    }

    func setEnabled(_ enabled: Bool) throws {
        if originalEnabled == nil { originalEnabled = getter() }
        setter(enabled)
        let signal = NSPredicate { _, _ in
            self.getter() == enabled && UIAccessibility.isReduceMotionEnabled == enabled
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: signal, object: nil)], timeout: 10) == .completed else {
            throw NSError(domain: "Real system Reduce Motion acceptance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "OS preference and UIKit Reduce Motion signal did not both reach the requested state"])
        }
    }

    func readEnabled() throws -> Bool { getter() }
    func restoreOriginal() throws {
        guard let originalEnabled else { return }
        try setEnabled(originalEnabled)
        guard getter() == originalEnabled, UIAccessibility.isReduceMotionEnabled == originalEnabled else {
            throw NSError(domain: "Real system Reduce Motion acceptance", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Original real OS Reduce Motion state was not restored"])
        }
    }
}
