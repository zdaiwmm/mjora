import CoreGraphics
import Foundation
import UIKit
import XCTest

/// Read-only reference capture. This opens Apple's Photos, never Imora, and
/// records AX bounds separately from the visible glass in the screenshot.
@MainActor
final class NativePhotosMetricsTests: XCTestCase {
    private let yearLabels = ["年", "年份", "Years"]
    private let monthLabels = ["月", "月份", "Months"]
    private let allLabels = ["全部", "全部照片", "所有照片", "All", "All Photos", "日", "天", "Days"]

    private struct DateRow {
        let segmented: XCUIElement?
        let year: XCUIElement
        let month: XCUIElement
        let all: XCUIElement
        var bounds: CGRect { year.frame.union(month.frame).union(all.frame) }
    }

    func testSystemPhotosLibraryDateRowReferenceMetrics() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Reference capture is limited to the task simulator.")
        #else
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        photos.launch()
        defer { photos.terminate() }
        dismissKnownPrompts(photos, springboard: springboard)
        capture(photos, stage: "native-photos-00-launched", row: nil)

        let library = libraryButton(photos)
        if waitForHittable(library, timeout: 5) {
            library.tap()
        } else {
            // A previous read-only reference visit may have left a viewer open.
            // Pop only when Edit is visible; never accept/save an editor draft.
            let edit = photos.buttons.matching(NSPredicate(format: "label IN %@", ["编辑", "Edit"])).firstMatch
            let back = photos.navigationBars.buttons.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minX < photos.frame.width * 0.25
            }
            if edit.exists && edit.isHittable, let back { back.tap() }
            dismissKnownPrompts(photos, springboard: springboard)
            XCTAssertTrue(waitForHittable(libraryButton(photos), timeout: 10),
                          "System Photos must expose its Library tab. Inspect the initial AX attachment if onboarding differs.")
            libraryButton(photos).tap()
        }
        dismissKnownPrompts(photos, springboard: springboard)
        capture(photos, stage: "native-photos-01-library", row: findDateRow(photos))

        var row = findDateRow(photos)
        // The newest edge shows Library/Collections navigation. A downward
        // finger drag moves toward older content in its chronological grid.
        for attempt in 1...6 where row == nil {
            dragGrid(photos, towardOlder: true)
            dismissKnownPrompts(photos, springboard: springboard)
            row = waitForDateRow(photos, timeout: 2)
            capture(photos, stage: "native-photos-older-\(attempt)", row: row)
        }
        // Retain evidence for the opposite initial scroll orientation as well.
        for attempt in 1...3 where row == nil {
            dragGrid(photos, towardOlder: false)
            row = waitForDateRow(photos, timeout: 2)
            capture(photos, stage: "native-photos-opposite-\(attempt)", row: row)
        }
        let measured = try XCTUnwrap(row,
            "No stable Years/Months/All row appeared. Three same-day photos may not scroll: import synthetic media with older EXIF capture dates, then rerun. No reference dimensions were fabricated.")
        XCTAssertTrue(measured.year.isHittable && measured.month.isHittable && measured.all.isHittable)
        capture(photos, stage: "native-photos-10-date-row-measured", row: measured)

        measured.year.tap()
        // Mode selection itself is read-only. Record the resulting state and
        // controls without assuming that a virtualized All Years header exists.
        let selected = NSPredicate { _, _ in
            measured.year.exists && (measured.year.isSelected || measured.year.value as? String == "1")
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 2)
        capture(photos, stage: "native-photos-11-years", row: findDateRow(photos))
        if let months = findDateRow(photos), months.month.isHittable {
            months.month.tap()
            capture(photos, stage: "native-photos-12-months", row: findDateRow(photos))
        }
        if let restore = findDateRow(photos), restore.all.isHittable {
            restore.all.tap()
            capture(photos, stage: "native-photos-13-all-restored", row: findDateRow(photos))
        }
        #endif
    }

    private func libraryButton(_ photos: XCUIApplication) -> XCUIElement {
        let id = photos.buttons["LibraryTab"]
        if id.exists { return id }
        let aliases = photos.buttons.matching(NSPredicate(format: "label IN %@", ["图库", "Library", "照片", "Photos"]))
        return aliases.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > photos.frame.height * 0.65
        } ?? id
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    private func dismissKnownPrompts(_ photos: XCUIApplication, springboard: XCUIApplication) {
        for app in [springboard, photos] {
            for alert in app.alerts.allElementsBoundByIndex where alert.exists {
                let text = alert.label + " " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
                guard ["通讯录", "Contacts", "通知", "Notifications", "notifications"].contains(where: text.contains) else { continue }
                let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["不允许", "Don’t Allow", "Don't Allow", "暂不", "Not Now"])).firstMatch
                if deny.exists && deny.isHittable { deny.tap() }
            }
        }
        // Photos' first-run welcome is not a permission grant or iCloud sign-in.
        let welcome = photos.staticTexts.matching(NSPredicate(format: "label IN %@", ["欢迎使用照片", "欢迎使用“照片”", "Welcome to Photos"])).firstMatch
        if welcome.exists {
            let next = photos.buttons.matching(NSPredicate(format: "label IN %@", ["继续", "Continue", "开始使用", "Get Started"])).firstMatch
            if next.exists && next.isHittable { next.tap() }
        }
    }

    private func dragGrid(_ photos: XCUIApplication, towardOlder: Bool) {
        let grids = photos.collectionViews.allElementsBoundByIndex + photos.scrollViews.allElementsBoundByIndex
        let surface = grids.filter {
            $0.exists && $0.isHittable && $0.frame.height > photos.frame.height * 0.35
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let start = surface?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardOlder ? 0.25 : 0.75))
            ?? photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardOlder ? 0.30 : 0.70))
        let end = surface?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardOlder ? 0.75 : 0.25))
            ?? photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardOlder ? 0.70 : 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func waitForDateRow(_ photos: XCUIApplication, timeout: TimeInterval) -> DateRow? {
        let predicate = NSPredicate { _, _ in self.findDateRow(photos) != nil }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed else { return nil }
        return findDateRow(photos)
    }

    private func findDateRow(_ photos: XCUIApplication) -> DateRow? {
        func matching(_ buttons: [XCUIElement], _ labels: [String]) -> [XCUIElement] {
            buttons.filter { labels.contains($0.label) && $0.exists && $0.isHittable && $0.frame.midY > photos.frame.height * 0.5 }
        }
        for segment in photos.segmentedControls.allElementsBoundByIndex {
            let buttons = segment.buttons.allElementsBoundByIndex
            if let year = matching(buttons, yearLabels).first,
               let month = matching(buttons, monthLabels).first,
               let all = matching(buttons, allLabels).first {
                return DateRow(segmented: segment, year: year, month: month, all: all)
            }
        }
        // Some Photos versions expose a custom button group rather than the
        // UISegmentedControl AX role. Require three same-band visible controls.
        let buttons = photos.buttons.allElementsBoundByIndex
        for year in matching(buttons, yearLabels) {
            guard let month = matching(buttons, monthLabels).first(where: { abs($0.frame.midY - year.frame.midY) < 5 }),
                  let all = matching(buttons, allLabels).first(where: { abs($0.frame.midY - year.frame.midY) < 5 }) else { continue }
            return DateRow(segmented: nil, year: year, month: month, all: all)
        }
        return nil
    }

    private func capture(_ photos: XCUIApplication, stage: String, row: DateRow?) {
        let screenshot = photos.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = stage; shot.lifetime = .keepAlways; add(shot)
        let hierarchy = XCTAttachment(string: photos.debugDescription)
        hierarchy.name = "\(stage)-full-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)

        let bottom = photos.buttons.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.intersects(photos.frame)
                && $0.frame.midY > photos.frame.height * 0.5
        }
        var metrics: [String: Any] = [
            "stage": stage,
            "coordinateSpace": "XCTest accessibility frames in screen points; visible glass extent requires screenshot inspection",
            "screen": rect(photos.frame),
            "screenshotPixels": ["width": screenshot.image.cgImage?.width ?? 0, "height": screenshot.image.cgImage?.height ?? 0],
            "runnerReducedMotion": UIAccessibility.isReduceMotionEnabled,
            "runnerInterfaceStyle": UITraitCollection.current.userInterfaceStyle.rawValue,
            "segmentedControls": photos.segmentedControls.allElementsBoundByIndex.map(element),
            "bottomButtons": bottom.map(element),
        ]
        if let row {
            let bounds = row.segmented?.frame ?? row.bounds
            metrics["dateRow"] = ["segmentContainer": row.segmented.map(element) ?? [:],
                                  "buttonUnion": rect(row.bounds), "year": element(row.year),
                                  "month": element(row.month), "all": element(row.all)]
            let adjacent = bottom.filter {
                abs($0.frame.midY - bounds.midY) <= max(bounds.height, $0.frame.height) * 0.6
                    && ($0.frame.maxX <= bounds.minX + 1 || $0.frame.minX >= bounds.maxX - 1)
            }
            metrics["adjacentLeft"] = adjacent.filter { $0.frame.maxX <= bounds.minX + 1 }
                .sorted { $0.frame.maxX > $1.frame.maxX }.map(element)
            metrics["adjacentRight"] = adjacent.filter { $0.frame.minX >= bounds.maxX - 1 }
                .sorted { $0.frame.minX < $1.frame.minX }.map(element)
        }
        if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: json)
            attachment.name = "\(stage)-frames.json"; attachment.lifetime = .keepAlways; add(attachment)
            print("NATIVE_PHOTOS_METRICS \(json)")
        }
    }

    private func rect(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height),
         "midX": Double(frame.midX), "midY": Double(frame.midY)]
    }
    private func element(_ value: XCUIElement) -> [String: Any] {
        ["identifier": value.identifier, "label": value.label, "value": value.value.map { String(describing: $0) } ?? "",
         "selected": value.isSelected, "hittable": value.isHittable, "frame": rect(value.frame)]
    }
}
