import CoreGraphics
import Foundation
import XCTest

/// Actual UI acceptance for the dedicated seeded loopback library. Geometry
/// expectations are independent observations of the requested layout contract;
/// this target never imports or calls the production composition helper.
@MainActor
final class PhotosMonthCompositionFlowTests: XCTestCase {
    private struct Month {
        let id: String
        let count: Int
        var days: [String]? = nil
    }

    private func launchCloudCapture() throws -> XCUIApplication {
        continueAfterFailure = false
        let fixture = try OwnedUIFixture.load()
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
        wait(app, "Signed-in cloud navigation") {
            let later = self.labelButton(app, ["以后", "Not Now", "Later"])
            if later.exists && later.isHittable { later.tap() }
            let library = app.buttons["shell-photos"]
            if library.exists && library.isHittable && !app.buttons["photos-source-menu"].isHittable { library.tap() }
            return app.buttons["photos-source-menu"].exists && app.buttons["photos-source-menu"].isHittable
        }
        app.buttons["photos-source-menu"].tap()
        let cloud = labelButton(app, ["云端照片", "Cloud Photos"], excludingID: "photos-source-menu")
        XCTAssertTrue(cloud.waitForExistence(timeout: 5)); cloud.tap()
        wait(app, "Cloud source returns to All") { app.buttons["photos-sort-filter"].isHittable }
        chooseMenu(app, labels: ["拍摄日期", "Date Captured"])
        chooseMenu(app, labels: ["所有项目", "All Items"])
        wait(app, "Actual cloud asset tiles") { app.buttons.matching(identifier: "asset-tile").count > 0 }
        return app
    }

    private func enter(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        field.tap(); field.typeText(text)
    }

    private func labelButton(_ app: XCUIApplication, _ labels: [String], excludingID: String = "") -> XCUIElement {
        let labelled = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
        // Native palette menu actions have no identifier. Exclude a known
        // underlying control only when the caller actually supplied its ID.
        let query = excludingID.isEmpty ? labelled : labelled.matching(NSPredicate(format: "identifier != %@", excludingID))
        return query.allElementsBoundByIndex.first(where: \.isHittable) ?? query.firstMatch
    }

    private func wait(_ app: XCUIApplication, _ reason: String, timeout: TimeInterval = 20,
                      _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { capture(app, "month-failure-\(reason)") }
        XCTAssertEqual(result, .completed, reason)
    }

    private func capture(_ app: XCUIApplication, _ name: String, frames: String? = nil) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = "\(name)-AX"; ax.lifetime = .keepAlways; add(ax)
        if let frames {
            let geometry = XCTAttachment(string: frames)
            geometry.name = "\(name)-frames"; geometry.lifetime = .keepAlways; add(geometry)
        }
    }

    private func chooseMenu(_ app: XCUIApplication, labels: [String]) {
        let menu = app.buttons["photos-sort-filter"]
        wait(app, "Sort/filter control is ready") { menu.exists && menu.isHittable }
        menu.tap()
        let choice = labelButton(app, labels)
        wait(app, "Menu choice \(labels[0])") { choice.exists && choice.isHittable }
        choice.tap()
        // A palette selection can leave the native context menu open,
        // especially when choosing its already-selected sort option.
        if choice.exists && choice.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.65)).tap()
        }
        wait(app, "Menu dismisses after \(labels[0])") { menu.isHittable }
    }

    /// Low-velocity movement plus an explicit end hold stops kinetic scrolling.
    /// Positive distance moves chronological content down to older months.
    private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        let dy = min(max(distance, -300), 300)
        guard abs(dy) >= 1 else { return }
        let base = app.coordinate(withNormalizedOffset: .zero)
        let startY: CGFloat = dy > 0 ? 260 : 590
        // The month margin has no card action to accidentally tap when a
        // small alignment drag is below the platform's pan threshold.
        let start = base.withOffset(CGVector(dx: 10, dy: startY))
        let end = base.withOffset(CGVector(dx: 10, dy: startY + dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.35)
    }

    private func enterMonths(_ app: XCUIApplication) {
        let picker = app.segmentedControls["photos-period-picker"]
        for _ in 0..<4 where !picker.exists || !picker.isHittable { drag(app, by: 200) }
        wait(app, "Period picker") { picker.exists && picker.isHittable }
        let months = picker.buttons.matching(NSPredicate(format: "label IN %@", ["月", "Months"])).firstMatch
        XCTAssertTrue(months.isHittable); months.tap()
        wait(app, "Month overview") { app.scrollViews["photos-periods"].exists }
    }

    private func dayPhotos(_ app: XCUIApplication, month: String) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "^photos-period-photo-\(month)-[0-9]{2}$"))
            .allElementsBoundByIndex.sorted { $0.identifier < $1.identifier }
    }

    /// Older months can align at130pt. The latest month is bottom-clamped;
    /// accept its natural Y only when every photo and its heading are visible.
    private func position(_ app: XCUIApplication, month: Month) -> (CGRect, CGRect, [XCUIElement]) {
        let heading = app.descendants(matching: .any).matching(identifier: "photos-period-heading-\(month.id)").firstMatch
        let group = app.descendants(matching: .any).matching(identifier: "photos-period-photo-\(month.id)").firstMatch
        for _ in 0..<16 {
            if !heading.exists { drag(app, by: 250); continue }
            // Bring a lazy heading into the viewport before waiting on its
            // task to load. Final alignment happens after all true days exist.
            if heading.frame.minY < 100 || heading.frame.minY > 700 {
                drag(app, by: 130 - heading.frame.minY); continue
            }
            wait(app, "Complete \(month.id) has exactly \(month.count) true days") {
                self.dayPhotos(app, month: month.id).count == month.count && group.exists && group.frame.height > 0
            }
            let targetY: CGFloat = 130
            let delta = targetY - heading.frame.minY
            let fullyVisible = heading.frame.minY > 100 && group.frame.maxY < app.frame.height - 85
            if abs(delta) <= 4 || (month.id == "2026-11" && fullyVisible) {
                var last = group.frame
                var stableSince = Date()
                wait(app, "\(month.id) layout stops moving", timeout: 8) {
                    let next = group.frame
                    if abs(next.minY - last.minY) > 0.5 || abs(next.height - last.height) > 0.5 {
                        last = next; stableSince = Date(); return false
                    }
                    return Date().timeIntervalSince(stableSince) > 0.2
                }
                let photos = dayPhotos(app, month: month.id)
                let report = (["heading=\(heading.frame)", "composition=\(group.frame)"]
                    + photos.map { "\($0.identifier)=\($0.frame); label=\($0.label)" }).joined(separator: "\n")
                capture(app, "month-composition-\(month.id)-\(month.count)-days", frames: report)
                XCTAssertEqual(photos.count, month.count)
                if month.id != "2026-11" { XCTAssertEqual(heading.frame.minY, 130, accuracy: 4) }
                return (heading.frame, group.frame, photos)
            }
            if abs(delta) < 20 {
                let away: CGFloat = delta > 0 ? -40 : 40
                drag(app, by: away)
                drag(app, by: delta - away)
            } else {
                drag(app, by: delta)
            }
        }
        capture(app, "month-position-failed-\(month.id)")
        XCTFail("Unable to expose the entire \(month.id) month without hiding or dropping day cards")
        return (heading.frame, group.frame, dayPhotos(app, month: month.id))
    }

    private func verify(_ app: XCUIApplication, month: Month) {
        let (heading, group, photos) = position(app, month: month)
        let frames = photos.map(\.frame)
        XCTAssertEqual(frames.count, month.count)
        if let days = month.days {
            XCTAssertEqual(photos.map(\.identifier), days.map { "photos-period-photo-\(month.id)-\($0)" })
        }
        XCTAssertEqual(heading.minX, 20, accuracy: 1)
        // StaticText reports its intrinsic glyph bounds, while the enclosing
        // title row and the composition span the available width.
        XCTAssertGreaterThan(heading.width, 80)
        XCTAssertLessThanOrEqual(heading.maxX, group.maxX + 1)
        XCTAssertEqual(group.minX, 20, accuracy: 1)
        XCTAssertEqual(group.maxX, app.frame.width - 20, accuracy: 1)
        XCTAssertEqual(group.minY - heading.maxY, 10, accuracy: 1)
        XCTAssertGreaterThan(heading.height, 20)
        XCTAssertLessThan(heading.height, 35)
        XCTAssertGreaterThanOrEqual(heading.minY, 100)
        XCTAssertLessThan(group.maxY, app.frame.height - 85)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThan(frame.width, 20); XCTAssertGreaterThan(frame.height, 20)
            XCTAssertGreaterThanOrEqual(frame.minX, group.minX - 1)
            XCTAssertGreaterThanOrEqual(frame.minY, group.minY - 1)
            XCTAssertLessThanOrEqual(frame.maxX, group.maxX + 1)
            XCTAssertLessThanOrEqual(frame.maxY, group.maxY + 1)
            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other), "Distinct day photos overlap") }
        }
        switch month.count {
        case 2:
            XCTAssertEqual(group.height, group.width * 2 / 3, accuracy: 1)
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
            XCTAssertEqual(frames[0].height, group.height, accuracy: 1)
            XCTAssertEqual(frames[0].size.width, frames[1].size.width, accuracy: 1)
            XCTAssertEqual(frames[1].minX - frames[0].maxX, 4, accuracy: 1)
        case 3:
            XCTAssertEqual(group.height, group.width * 2 / 3, accuracy: 1)
            verifyThree(frames[0], frames[1], frames[2])
        case 4:
            XCTAssertEqual(group.height, group.width * 2 / 3, accuracy: 1)
            for frame in frames {
                XCTAssertEqual(frame.width, frames[0].width, accuracy: 1)
                XCTAssertEqual(frame.height, frames[0].height, accuracy: 1)
            }
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
            XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1)
            XCTAssertEqual(frames[1].minX - frames[0].maxX, 4, accuracy: 1)
            XCTAssertEqual(frames[3].minX - frames[2].maxX, 4, accuracy: 1)
            XCTAssertEqual(frames[2].minY - frames[0].maxY, 4, accuracy: 1)
        case 5:
            XCTAssertEqual(group.height, group.width * 4 / 3 + 4, accuracy: 1)
            verifyThree(frames[0], frames[1], frames[2])
            XCTAssertEqual(frames[3].minY - frames[0].maxY, 4, accuracy: 1)
            XCTAssertEqual(frames[3].minY, frames[4].minY, accuracy: 1)
            XCTAssertEqual(frames[3].height, frames[0].height, accuracy: 1)
            XCTAssertEqual(frames[3].width, frames[4].width, accuracy: 1)
            XCTAssertEqual(frames[4].minX - frames[3].maxX, 4, accuracy: 1)
        default: XCTFail("This fixture must expose the specified2/3/4/5-day examples")
        }
    }

    private func verifyThree(_ large: CGRect, _ upper: CGRect, _ lower: CGRect) {
        XCTAssertEqual(large.width / upper.width, 2, accuracy: 0.03)
        XCTAssertEqual(large.minY, upper.minY, accuracy: 1)
        XCTAssertEqual(upper.minX - large.maxX, 4, accuracy: 1)
        XCTAssertEqual(upper.minX, lower.minX, accuracy: 1)
        XCTAssertEqual(upper.width, lower.width, accuracy: 1)
        XCTAssertEqual(upper.height, lower.height, accuracy: 1)
        XCTAssertEqual(lower.minY - upper.maxY, 4, accuracy: 1)
        XCTAssertEqual(lower.maxY, large.maxY, accuracy: 1)
    }

    private func finishCloud(_ app: XCUIApplication) {
        // Reopen a known root even after a failing sheet/menu assertion.
        app.terminate(); app.launch()
        let library = app.buttons["shell-photos"]
        if library.waitForExistence(timeout: 10), library.isHittable { library.tap() }
        let source = app.buttons["photos-source-menu"]
        if source.waitForExistence(timeout: 15), source.isHittable {
            source.tap()
            let cloud = labelButton(app, ["云端照片", "Cloud Photos"], excludingID: "photos-source-menu")
            if cloud.waitForExistence(timeout: 4), cloud.isHittable { cloud.tap() }
        }
    }

    func testCloudMonthsExposeEveryDayWithDistinctAdaptiveGeometry() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        enterMonths(app)
        for month in [Month(id: "2026-11", count: 2),
                      Month(id: "2026-10", count: 5, days: ["01", "07", "13", "19", "25"]),
                      Month(id: "2026-09", count: 4, days: ["02", "08", "17", "26"]),
                      Month(id: "2026-08", count: 3)] {
            verify(app, month: month)
        }
    }

    func testDateAddedAllKeepsItsSortAndRevealsTheExactNonfirstCaptureDay() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        chooseMenu(app, labels: ["添加日期", "Date Added"])
        enterMonths(app)
        _ = position(app, month: Month(id: "2026-10", count: 5, days: ["01", "07", "13", "19", "25"]))
        let day = app.buttons["photos-period-day-2026-10-19"]
        wait(app, "Nonfirst October19 card is actionable") { day.exists && day.isHittable }
        let summary = day.label
        XCTAssertTrue(summary.contains("2026年10月19日"), "The month uses capture dates while All remains Added-sorted")
        let separator = try XCTUnwrap(summary.range(of: ", ", options: .backwards))
        let exactCaptureDateTime = String(summary[..<separator.lowerBound])
        day.tap()
        let tiles = app.buttons.matching(identifier: "asset-tile")
        wait(app, "All reveals the displayed day's exact photographer date/time") {
            tiles.allElementsBoundByIndex.contains {
                $0.frame.midY > 120 && $0.frame.midY < app.frame.height - 100 && $0.isHittable
                    && $0.label.contains(exactCaptureDateTime)
            }
        }
        XCTAssertFalse(app.scrollViews["photos-periods"].exists)
        capture(app, "month-added-nonfirst-day-revealed", frames: "Tapped capture date/time: \(exactCaptureDateTime)\nVisible grid:\n"
                + tiles.allElementsBoundByIndex.filter(\.isHittable).map { "\($0.frame): \($0.label)" }.joined(separator: "\n"))
        let menu = app.buttons["photos-sort-filter"]
        wait(app, "All sort control") { menu.exists && menu.isHittable }; menu.tap()
        let added = labelButton(app, ["添加日期", "Date Added"])
        wait(app, "Added option remains present") { added.exists && added.isHittable }
        capture(app, "month-added-sort-preserved", frames: "Added isSelected=\(added.isSelected); value=\(String(describing: added.value))")
        XCTAssertTrue(added.isSelected || (added.value as? String) == "1", "Returning from a capture-month card must preserve All's actual Added selection")
    }
}
