import Foundation
import UIKit
import XCTest

/// Actual framebuffer controls for the separate 96-image Phase 4 owner.
@MainActor
final class Phase4ImagePresentationFlowTests: XCTestCase {
    private struct Marker: Decodable { let id: String; let markerID: Int }
    private struct Fixture: Decodable {
        let apiURL: String; let email: String; let ownerID: String; let assetCount: Int; let assets: [Marker]
    }
    private struct Tile: Decodable {
        let assetID: String; let rect: [Double]; let realBitmap: Bool; let adequatePixels: Bool
    }
    private struct Frame: Decodable {
        let tiles: [Tile]; let serverIdentity: String?; let accountID: String?; let reportedItemCount: Int
    }
    private struct Probe: Decodable { let latest: Frame }
    private struct Crop: Encodable { let assetID: String; let markerID: Int; let rectPx: [Int] }
    private struct Capture: Encodable { let name: String; let kind: String; let image: String; let crops: [Crop] }
    private struct Manifest: Encodable { let captures: [Capture] }

    private let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
    private let simulator = "E30E1970-2CBA-44E4-BDAC-6B8EFD9F2558"
    private let captureDirectory = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4/validation", isDirectory: true)
        .appending(path: "task18-rendered-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func fixture() throws -> Fixture {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == simulator else { throw failure("Wrong simulator") }
        let path = root.appending(path: "entry-ui-fixture.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        guard path.resolvingSymlinksInPath().path == path.path, permissions?.intValue == 0o600 else { throw failure("Unsafe fixture path") }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        guard value.apiURL == "http://127.0.0.1:33284/api", value.email.hasSuffix("@imora-phase4-fixture.invalid"),
              UUID(uuidString: value.ownerID) != nil, value.assetCount == 96, value.assets.count == 96,
              Set(value.assets.map { $0.id.lowercased() }).count == 96,
              Set(value.assets.map(\.markerID)) == Set(1...96), value.assets.allSatisfy({ UUID(uuidString: $0.id) != nil })
        else { throw failure("Unsafe entry fixture") }
        for name in ["ui-fixture.json", "legacy-ui-fixture.json", "native-integration-fixture.json"] {
            let other = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: name))) as? [String: Any]
            guard let owner = other?["ownerID"] as? String, UUID(uuidString: owner) != nil, owner != value.ownerID else {
                throw failure("Fixture owners must be distinct")
            }
        }
        return value
    }

    private func failure(_ text: String) -> NSError { NSError(domain: text, code: 1) }

    private func launch(kind: String? = nil, target: String? = nil, wrong: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "1"
        app.launchEnvironment["IMORA_PHASE4_OWNED_FIXTURE"] = "entry"
        if let kind, let target {
            app.launchEnvironment["IMORA_PHASE4_FAULT_KIND"] = kind
            app.launchEnvironment["IMORA_PHASE4_FAULT_ASSET_ID"] = target
            if let wrong { app.launchEnvironment["IMORA_PHASE4_FAULT_WRONG_ID"] = wrong }
        }
        app.launch()
        let source = app.buttons["photos-source-menu"]
        XCTAssertTrue(source.waitForExistence(timeout: 45)); source.tap()
        let options = app.buttons.matching(NSPredicate(format: "(label == %@ OR label BEGINSWITH %@) AND identifier != %@",
            "Cloud Photos", "Cloud Photos,", "photos-source-menu"))
        let cloud = options.allElementsBoundByIndex.first(where: \.isHittable) ?? options.firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 8)); cloud.tap()
        return app
    }

    private func observation(_ app: XCUIApplication, fixture: Fixture, condition: (Frame) -> Bool) throws -> Frame {
        let deadline = Date().addingTimeInterval(55), grid = app.scrollViews["phase4-launch-grid-probe"]
        while Date() < deadline {
            if let value = grid.value as? String, let bytes = value.data(using: .utf8),
               let frame = try? JSONDecoder().decode(Probe.self, from: bytes).latest,
               frame.serverIdentity == fixture.apiURL, frame.accountID == fixture.ownerID,
               frame.reportedItemCount == 96, condition(frame) { return frame }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "phase4-marker-timeout"; screenshot.lifetime = .keepAlways; add(screenshot)
        throw failure("Current entry-owner grid was not observed")
    }

    private func fullyVisible(_ tile: Tile, in app: XCUIApplication) -> Bool {
        guard tile.rect.count == 4 else { return false }
        let r = tile.rect
        return r[0] >= 0 && r[1] >= 150 && r[2] > 40 && abs(r[2] - r[3]) < 2
            && r[0] + r[2] <= app.frame.width && r[1] + r[3] <= app.frame.height - 150
    }

    private func capture(_ app: XCUIApplication, kind: String, tiles: [Tile], fixtures: [String: Marker]) throws -> Capture {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = "phase4-rendered-\(kind)"; attachment.lifetime = .keepAlways; add(attachment)
        guard let image = shot.image.cgImage else { throw failure("No screenshot bitmap") }
        let sx = Double(image.width) / app.frame.width, sy = Double(image.height) / app.frame.height
        guard abs(sx - sy) < 0.05 else { throw failure("Unexpected screenshot scale") }
        let crops: [Crop] = try tiles.map { tile in
            guard fullyVisible(tile, in: app), let marker = fixtures[tile.assetID.lowercased()] else { throw failure("Missing expected fixture marker or complete media rect") }
            let r = tile.rect
            return Crop(assetID: marker.id, markerID: marker.markerID,
                rectPx: [Int((r[0] * sx).rounded()), Int((r[1] * sy).rounded()), Int((r[2] * sx).rounded()), Int((r[3] * sy).rounded())])
        }
        guard !crops.isEmpty else { throw failure("No complete image crop") }
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let path = captureDirectory.appending(path: "\(kind).png")
        try shot.pngRepresentation.write(to: path, options: .withoutOverwriting)
        return Capture(name: "actual-\(kind)", kind: kind, image: path.path, crops: crops)
    }

    func testRenderedSubjectOracleRejectsDeliberateFailures() throws {
        continueAfterFailure = false
        let fixture = try fixture(), markers = Dictionary(uniqueKeysWithValues: fixture.assets.map { ($0.id.lowercased(), $0) })
        var app = try launch()
        let positive = try observation(app, fixture: fixture) { frame in
            let visible = frame.tiles.filter { self.fullyVisible($0, in: app) }
            return !visible.isEmpty && visible.allSatisfy { $0.realBitmap && $0.adequatePixels }
        }
        let visible = positive.tiles.filter { fullyVisible($0, in: app) }
        let targetTile = try XCTUnwrap(visible.first), target = try XCTUnwrap(markers[targetTile.assetID.lowercased()])
        let wrong = try XCTUnwrap(fixture.assets.first { $0.id.lowercased() != target.id.lowercased() })
        var captures = [try capture(app, kind: "positive", tiles: visible, fixtures: markers)]
        app.terminate()
        for kind in ["missing", "black", "wrong-subject"] {
            app = try launch(kind: kind, target: target.id, wrong: wrong.id)
            let signal = app.buttons.matching(NSPredicate(format: "identifier == %@ AND value == %@", "asset-tile", "phase4-oracle-\(kind)")).firstMatch
            XCTAssertTrue(signal.waitForExistence(timeout: 40), "Fault must be applied to an actually mounted tile")
            let frame = try observation(app, fixture: fixture) { $0.tiles.contains { $0.assetID.lowercased() == target.id.lowercased() && self.fullyVisible($0, in: app) } }
            let tile = try XCTUnwrap(frame.tiles.first { $0.assetID.lowercased() == target.id.lowercased() })
            captures.append(try capture(app, kind: kind, tiles: [tile], fixtures: markers))
            app.terminate()
        }
        let data = try JSONEncoder().encode(Manifest(captures: captures))
        let info = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); info.name = "phase4-rendered-capture-manifest"; info.lifetime = .keepAlways; add(info)
        try data.write(to: captureDirectory.appending(path: "captures.json"), options: .withoutOverwriting)
    }
}
