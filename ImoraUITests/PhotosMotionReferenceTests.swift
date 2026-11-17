import Foundation
import XCTest

/// Read-only capture against the synthetic library on the reference simulator.
@MainActor
final class PhotosMotionReferenceTests: XCTestCase {
    func testSystemPhotosMotionReference() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "68256905-2D6A-427A-A3F7-E7525F6A17CE" else {
            throw XCTSkip("Requires the dedicated system Photos reference simulator")
        }
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        capture(photos, "start")
        let select = photos.buttons.matching(NSPredicate(format: "label IN %@", ["Select", "选择"])).firstMatch
        if select.exists && select.isHittable {
            mark("selection-open"); select.tap(); capture(photos, "selection")
            let done = photos.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "Cancel", "取消"])).firstMatch
            if done.exists && done.isHittable { mark("selection-close"); done.tap() }
        }
        let library = photos.buttons["LibraryTab"]
        if library.exists && library.isHittable { library.tap() }
        let cells = photos.images.matching(identifier: "PXGGridLayout-Info")
        let cell = cells.allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY > 180 && $0.frame.midY < photos.frame.height - 180 }
        mark("viewer-open")
        if let cell { cell.tap() }
        else { photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        capture(photos, "viewer")
        let info = photos.buttons.matching(NSPredicate(format: "label IN %@", ["Info", "信息", "简介"])).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        if info.exists && info.isHittable {
            mark("info-open"); info.tap(); capture(photos, "info")
            mark("info-close"); info.tap()
        }
        mark("chrome-hide"); photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap(); capture(photos, "chrome-hidden")
        mark("chrome-show"); photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap(); capture(photos, "chrome-shown")
        let edit = photos.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "编辑"])).firstMatch
        if edit.exists && edit.isHittable {
            mark("editor-open"); edit.tap(); capture(photos, "editor")
            let crop = photos.buttons["edit.tool.crop"]
            XCTAssertTrue(crop.waitForExistence(timeout: 5))
            if crop.exists, crop.frame.intersects(photos.frame) {
                mark("editor-crop")
                let frame = crop.frame
                photos.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                capture(photos, "crop")
            }
            let cancel = photos.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            if cancel.exists && cancel.isHittable { mark("editor-close"); cancel.tap() }
        }
        mark("viewer-close")
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.05,
            thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        capture(photos, "grid-return")
        for _ in 0..<3 {
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05,
                thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        for labels in [["Years", "年"], ["Months", "月"], ["All", "全部", "All Photos"]] {
            let control = photos.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.first {
                $0.frame.midY > photos.frame.height * 0.6
            }
            if let control {
                mark("period-\(labels[0])")
                photos.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: control.frame.midX, dy: control.frame.midY)).tap()
                capture(photos, "period-\(labels[0])")
            }
        }

        capture(photos, "end")
    }

    private func mark(_ stage: String) { print("MOTION_STAGE \(Date().timeIntervalSince1970) \(stage)") }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "\(name)-AX"; ax.lifetime = .keepAlways; add(ax)
    }
}
