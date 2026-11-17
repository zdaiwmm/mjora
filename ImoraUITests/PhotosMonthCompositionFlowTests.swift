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
        app.launchEnvironment["IMORA_FRAME_TRACE"] = "1"
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
        let cloud = labelButton(app, ["云端", "Cloud"], excludingID: "photos-source-menu")
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
            let cloud = labelButton(app, ["云端", "Cloud"], excludingID: "photos-source-menu")
            if cloud.waitForExistence(timeout: 4), cloud.isHittable { cloud.tap() }
        }
    }

    func testLibraryCountNavigationExpansionAndLatestRowClearance() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        let source = app.buttons["photos-source-menu"]
        let count = try XCTUnwrap(source.value as? String)
        XCTAssertFalse(count.contains("…"))
        XCTAssertFalse(count.contains("..."))
        XCTAssertTrue(count.contains("项目") || count.contains("items"))
        capture(app, "gallery-full-item-count")
        for _ in 0..<4 where !app.buttons["photos-show-navigation"].isHittable { drag(app, by: 250) }
        let expand = app.buttons["photos-show-navigation"]
        wait(app, "Collapsed navigation") { expand.isHittable }
        let visible = app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex
            .first { $0.isHittable && $0.frame.midY > 180 && $0.frame.midY < 600 }
        let label = try XCTUnwrap(visible?.label)
        let originalY = try XCTUnwrap(visible?.frame.midY)
        expand.tap()
        let library = app.buttons["shell-photos"]
        wait(app, "First tap expands Library and Collections") { library.isHittable && app.buttons["shell-albums"].isHittable }
        let retained = app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.first { $0.label == label }
        XCTAssertEqual(try XCTUnwrap(retained?.frame.midY), originalY, accuracy: 3)
        capture(app, "gallery-navigation-expanded-without-jump")
        library.tap()
        wait(app, "Animated return reaches the latest row") {
            !app.buttons["photos-show-navigation"].isHittable && library.isHittable
        }
        // Wait for the programmatic scroll animation to settle before measuring.
        let settled = Date().addingTimeInterval(1)
        wait(app, "Return animation settles", timeout: 3) { Date() >= settled }
        let lastY = try XCTUnwrap(app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.midY > 150 && $0.frame.minY < library.frame.minY }
            .map { $0.frame.maxY }.max())
        let gap = library.frame.minY - lastY
        XCTAssertGreaterThanOrEqual(gap, 4)
        XCTAssertLessThanOrEqual(gap, 20)
        capture(app, "gallery-latest-row-clearance", frames: "lastPhotoBottom=\(lastY) navigationTop=\(library.frame.minY) gap=\(gap)")
        enterMonths(app)
        let picker = app.segmentedControls["photos-period-picker"]
        for labels in [["年", "Years"], ["月", "Months"], ["全部", "All"], ["月", "Months"]] {
            let mode = picker.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            XCTAssertTrue(mode.isHittable); mode.tap()
            if labels[0] == "全部" { wait(app, "All grid") { app.buttons["photos-sort-filter"].isHittable } }
            else { wait(app, "Period content") { app.scrollViews["photos-periods"].exists } }
        }
        capture(app, "gallery-period-switching")
        app.buttons["photos-show-navigation"].tap()
        app.buttons["shell-albums"].tap()
        wait(app, "Collections profile") { app.buttons["profile-avatar"].isHittable }
        capture(app, "collections-larger-profile-avatar")
    }

    func testVideoShowsTransportImmediatelyAndAutoplays() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        let menu = app.buttons["photos-sort-filter"]
        menu.tap()
        let media = labelButton(app, ["媒体类型", "Media Types"])
        wait(app, "Media filter") { media.isHittable }; media.tap()
        let videos = labelButton(app, ["视频", "Videos"])
        wait(app, "Video filter") { videos.isHittable }; videos.tap()
        wait(app, "Filtered video tiles") { app.buttons.matching(identifier: "asset-tile").count > 0 && menu.isHittable }
        let tile = try XCTUnwrap(app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.first { $0.isHittable })
        tile.tap()
        let controls = app.otherElements["video-controls"]
        let scrubber = app.descendants(matching: .any).matching(identifier: "video-scrubber").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 2))
        capture(app, "gallery-video-opening-progress")
        wait(app, "Video advances automatically", timeout: 8) {
            guard let value = scrubber.value as? String else { return false }
            return !value.hasPrefix("0:00 / ") && !value.hasPrefix("0:00, ")
        }
        capture(app, "gallery-video-playing")
        let play = app.buttons["video-play-pause"]
        let mute = app.buttons["video-mute"]
        // The synthetic clip is only three seconds long and may have ended
        // while XCTest captured its playing frame and accessibility tree.
        if ["播放", "Play"].contains(play.label) {
            play.tap()
            wait(app, "Playback can restart") { ["暂停", "Pause"].contains(play.label) }
        }
        let restingFrame = controls.frame
        play.tap()
        wait(app, "Tapping pauses the video") { ["播放", "Play"].contains(play.label) }
        let originalMute = mute.label
        mute.tap()
        wait(app, "Sound button changes the mute state") { mute.label != originalMute }
        mute.tap()
        wait(app, "Sound can be muted again") { mute.label == originalMute }
        let oldProgress = scrubber.value as? String
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        wait(app, "Dragging seeks the paused video") { scrubber.value as? String != oldProgress }
        XCTAssertTrue(["播放", "Play"].contains(play.label), "Seeking a paused clip must keep it paused")
        capture(app, "gallery-video-controls-interactive")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        let mediaPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        mediaPoint.tap()
        wait(app, "Hidden transport controls stop receiving input") { !play.isHittable && !mute.isHittable }
        mediaPoint.tap()
        wait(app, "Transport remains interactive after showing") { play.isHittable && mute.isHittable }
        XCTAssertEqual(controls.frame.minY, restingFrame.minY, accuracy: 1)
        play.tap()
        wait(app, "Playback resumes after showing the controls") { ["暂停", "Pause"].contains(play.label) }
        capture(app, "gallery-video-controls-restored")
    }

    func testForegroundAndSourceSwitchKeepTheCloudLibraryVisible() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        for pass in 0..<3 {
            app.buttons["photos-source-menu"].tap()
            let local = labelButton(app, ["本机", "On Device"], excludingID: "photos-source-menu")
            XCTAssertTrue(local.waitForExistence(timeout: 5)); local.tap()
            wait(app, "Device navigation is ready") { app.buttons["photos-source-menu"].isHittable }
            capture(app, "gallery-device-source-\(pass)")
            app.buttons["photos-source-menu"].tap()
            let cloud = labelButton(app, ["云端", "Cloud"], excludingID: "photos-source-menu")
            XCTAssertTrue(cloud.waitForExistence(timeout: 5)); cloud.tap()
            wait(app, "Cloud tiles survive the source switch") { app.buttons.matching(identifier: "asset-tile").count > 0 }
            XCUIDevice.shared.press(.home)
            app.activate()
            wait(app, "Cloud navigation and photos return after backgrounding") {
                app.buttons["photos-source-menu"].isHittable && app.buttons.matching(identifier: "asset-tile").count > 0
            }
            capture(app, "gallery-cloud-foreground-\(pass)")
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

    func testUnifiedNativeSourcesAndQuietBackupGlyphs() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        var observations: [String] = []
        func count() -> Int { Int((app.buttons["photos-source-menu"].value as? String ?? "").filter(\.isNumber)) ?? 0 }
        let cloudCount = count()
        for labels in [["全部", "All Sources"], ["本机", "On Device"], ["云端", "Cloud"], ["全部", "All Sources"]] {
            let source = app.buttons["photos-source-menu"]
            wait(app, "Source control is ready") { source.isHittable }
            source.tap()
            XCTAssertFalse(labelButton(app, ["备份与同步", "Backup & Sync"]).exists)
            let item = labelButton(app, labels, excludingID: "photos-source-menu")
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            capture(app, "unified-native-source-menu")
            let began = ProcessInfo.processInfo.systemUptime
            item.tap()
            wait(app, "Source returns a usable grid", timeout: 8) {
                guard source.isHittable else { return false }
                if labels[0] == "全部" { return count() > cloudCount }
                if labels[0] == "云端" { return count() == cloudCount }
                // Several identical device originals may share one verified
                // cloud copy, so the device count can exceed the union count.
                return ["本机", "On Device"].contains(source.label) && count() > 0
            }
            observations.append("\(labels[0]): automation-to-ready=\(ProcessInfo.processInfo.systemUptime - began), count=\(String(describing: source.value))")
            capture(app, "unified-source-\(labels[0])")
        }
        let attachment = XCTAttachment(string: observations.joined(separator: "\n"))
        attachment.name = "unified-source-switch-observations"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testUnifiedGalleryScrollHitches() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        app.buttons["photos-source-menu"].tap()
        let all = labelButton(app, ["全部", "All Sources"], excludingID: "photos-source-menu")
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        wait(app, "Combined grid is visible") { app.buttons.matching(identifier: "asset-tile").count > 0 }
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
        capture(app, "unified-scroll-performance")
    }

    func testUnifiedPhotoOpenAndReturnHitches() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        app.buttons["photos-source-menu"].tap()
        let all = labelButton(app, ["全部", "All Sources"], excludingID: "photos-source-menu")
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app), XCTClockMetric()], options: options) {
            let tiles = app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex
            guard let tile = tiles.first(where: { $0.isHittable && $0.frame.midY > 190 && $0.frame.midY < 600 }) else {
                XCTFail("No visible photo to open"); return
            }
            tile.tap()
            let close = app.buttons["viewer-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 6))
            close.tap()
            XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 6))
        }
        capture(app, "unified-open-return-performance")
    }
    func testUnifiedRecordedFailureShowsRecoveryAndCanRetry() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        app.buttons["photos-source-menu"].tap()
        let review = labelButton(app, ["查看失败的项目", "Review Failed Items"])
        guard review.waitForExistence(timeout: 5) else {
            throw XCTSkip("The owned fixture has no recorded backup failure")
        }
        review.tap()
        let guide = labelButton(app, ["查看解决方法", "How to Fix"])
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        capture(app, "unified-backup-failure-list")
        guide.tap()
        XCTAssertTrue(app.staticTexts["backup-failure-recovery"].waitForExistence(timeout: 5))
        capture(app, "unified-backup-failure-recovery")
        let retry = app.buttons["backup-retry-failed"]
        XCTAssertTrue(retry.isHittable); retry.tap()
        wait(app, "The recovery retry completes", timeout: 40) {
            retry.isEnabled && !retry.label.contains("Retrying") && !retry.label.contains("重试中")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(app, "Verified retry removes the recorded failure", timeout: 20) {
            app.staticTexts.matching(NSPredicate(format: "label IN %@", ["没有备份失败的项目", "No Failed Backups"])).firstMatch.exists
        }
        capture(app, "unified-backup-failure-resolved")
    }

    func testUnifiedSinglePhotoBackupUpdatesTheOpenViewer() throws {
        let app = try launchCloudCapture()
        defer { finishCloud(app) }
        app.buttons["photos-source-menu"].tap()
        let all = labelButton(app, ["全部", "All Sources"], excludingID: "photos-source-menu")
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        wait(app, "Unbacked device photo is present") {
            app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.contains {
                $0.isHittable && ($0.label.contains("未备份") || $0.label.contains("Not backed up"))
            }
        }
        let tile = try XCTUnwrap(app.buttons.matching(identifier: "asset-tile").allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > 190 && ($0.label.contains("未备份") || $0.label.contains("Not backed up"))
        })
        tile.tap()
        let backup = app.buttons["viewer-back-up"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        capture(app, "unified-viewer-before-backup")
        backup.tap()
        let complete = app.buttons.matching(NSPredicate(format: "label IN %@", ["已备份", "Backed up"])).firstMatch
        wait(app, "Verified backup reaches the open viewer", timeout: 40) { complete.exists }
        capture(app, "unified-viewer-after-backup")
        XCTAssertFalse(app.buttons["viewer-back-up"].exists)
        app.buttons["viewer-close"].tap()
        wait(app, "Combined grid remains usable after backup") { app.buttons["photos-source-menu"].isHittable }
        capture(app, "unified-grid-after-single-backup")
    }

}
