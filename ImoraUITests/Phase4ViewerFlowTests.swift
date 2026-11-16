import Foundation
import XCTest

@MainActor
final class Phase4ViewerFlowTests: XCTestCase {
    private struct Fixture: Decodable {
        let apiURL: String; let email: String; let ownerID: String
        let stillID: String; let motionID: String; let controlStillID: String; let verifiedPair: Bool
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
        let path = root.appending(path: "live-ui-fixture.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == OwnedUIFixture.simulator,
              path.resolvingSymlinksInPath().path == path.path, permissions?.intValue == 0o600 else {
            throw NSError(domain: "Unsafe Live fixture device or path", code: 1)
        }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        guard OwnedUIFixture.allowed(apiURL: value.apiURL, email: value.email,
                  ownerID: value.ownerID, simulatorUDID: OwnedUIFixture.simulator),
              value.email == "live-ui@imora-phase4-fixture.invalid", value.verifiedPair,
              UUID(uuidString: value.stillID) != nil, UUID(uuidString: value.motionID) != nil,
              UUID(uuidString: value.controlStillID) != nil,
              Set([value.stillID, value.motionID, value.controlStillID]).count == 3 else { throw NSError(domain: "Unsafe Live fixture identity", code: 1) }
        for name in ["native-integration-fixture.json", "entry-ui-fixture.json", "ui-fixture.json", "legacy-ui-fixture.json"] {
            let other = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: name))) as? [String: Any]
            guard let owner = other?["ownerID"] as? String, UUID(uuidString: owner) != nil, owner != value.ownerID else {
                throw NSError(domain: "Live fixture owners must be distinct", code: 1)
            }
        }
        return value
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout), .completed, description)
    }

    func testHoldReleaseThenSwipe() throws {
        continueAfterFailure = false
        let fixture = try fixture(), app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["IMORA_PHASE4_OWNED_FIXTURE"] = "live"
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "0"
        app.launch()
        defer { app.terminate() }
        let source = app.buttons["photos-source-menu"]
        XCTAssertTrue(source.waitForExistence(timeout: 35)); source.tap()
        let cloud = app.buttons.matching(NSPredicate(format: "(label == %@ OR label BEGINSWITH %@) AND identifier != %@",
            "Cloud Photos", "Cloud Photos,", "photos-source-menu")).firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 5)); cloud.tap()
        let all = app.segmentedControls["photos-period-picker"].buttons["All"]
        if all.exists && all.isHittable { all.tap() }
        let tile = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "asset-tile", "Live Photo")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 25)); tile.tap()
        let viewer = app.descendants(matching: .any)["asset-viewer"].firstMatch
        wait("The paired still must own the viewer") { viewer.value as? String == fixture.stillID }
        let controls = app.descendants(matching: .any)["live-photo-controls"].firstMatch
        let play = app.buttons["live-photo-play-pause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        wait("Opening Live must remain still") { controls.value as? String == "Stopped" }
        XCTAssertGreaterThanOrEqual(play.frame.width, 44); XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        let photo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        photo.press(forDuration: 0.34)
        wait("A short press must not leave playback running") { controls.value as? String == "Stopped" }
        capture(app, "live-short-press-still")

        // Prime the real clip through the same named accessible action, then
        // exercise a prepared hold. Video capture verifies movement mid-hold.
        if !play.isHittable { photo.tap() }
        wait("Live controls must be reachable before loading the clip") { play.isHittable }
        play.tap()
        wait("The accessible play action must start the clip", timeout: 20) { controls.value as? String == "Playing" }
        capture(app, "live-accessible-playing")
        play.tap()
        wait("Stop must restore the poster") { controls.value as? String == "Stopped" }
        photo.press(forDuration: 1.5)
        wait("Release must stop held playback") { controls.value as? String == "Stopped" }
        capture(app, "live-hold-released")

        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
        right.press(forDuration: 0.5, thenDragTo: left)
        var usedLeft = true
        // The active still may be the last page, depending on capture order.
        // At an edge the opposite direction must reach the control photo.
        if viewer.value as? String == fixture.stillID {
            usedLeft = false
            left.press(forDuration: 0.5, thenDragTo: right)
        }
        wait("Moving a held photo must yield horizontal paging") { viewer.value as? String == fixture.controlStillID }
        capture(app, "live-hold-yields-paging")
        (usedLeft ? left : right).press(forDuration: 0.05, thenDragTo: usedLeft ? right : left)
        wait("Returning must retain the still and stop the previous hold") {
            viewer.value as? String == fixture.stillID && controls.value as? String == "Stopped"
        }

        let image = app.images.allElementsBoundByIndex.first { $0.frame.width > 300 && $0.frame.midY > 200 && $0.frame.midY < 600 }
        let photoImage = try XCTUnwrap(image)
        let restingWidth = photoImage.frame.width
        photoImage.pinch(withScale: 2, velocity: 1)
        wait("The real two-finger gesture must enlarge the image") { photoImage.frame.width > restingWidth * 1.4 }
        photo.press(forDuration: 0.6)
        wait("A zoomed image must remain still during a hold") { controls.value as? String == "Stopped" }
        capture(app, "live-zoomed-hold-remains-still")
        photo.doubleTap()
        wait("Double tap must restore the fitted image") { photoImage.frame.width <= restingWidth * 1.02 }
        photo.press(forDuration: 0.5, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)))
        wait("A downward drag must still dismiss the viewer") { !viewer.exists && source.isHittable }
        capture(app, "live-drag-dismissed")
    }
}
