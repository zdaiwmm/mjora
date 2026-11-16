import Foundation
import XCTest

/// Only the separately allocated Phase 4 legacy account and simulator.
struct OwnedUIFixture: Decodable {
    let apiURL: String
    let email: String
    let password: String
    let ownerID: String
    let simulatorUDID: String

    static let placeholderEmail = "phase4-ui-placeholder@example.invalid"
    static let placeholderPassword = "phase4-ui-placeholder"
    static let simulator = "14BCD43F-2B3B-4D5C-A515-DCEF05889845"

    static func allowed(apiURL: String, email: String, ownerID: String, simulatorUDID: String) -> Bool {
        apiURL == "http://127.0.0.1:33284/api" && email.hasSuffix("@imora-phase4-fixture.invalid")
            && UUID(uuidString: ownerID) != nil && simulatorUDID == simulator
    }

    static func load() throws -> OwnedUIFixture {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == simulator else { throw NSError(domain: "Unsafe simulator", code: 1) }
        let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
        let path = root.appending(path: "legacy-ui-fixture.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        guard path.resolvingSymlinksInPath().path == path.path, permissions?.intValue == 0o600 else {
            throw NSError(domain: "Unsafe fixture path", code: 1)
        }
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard allowed(apiURL: fixture.apiURL, email: fixture.email, ownerID: fixture.ownerID,
                      simulatorUDID: fixture.simulatorUDID) else {
            throw NSError(domain: "Unsafe fixture destination", code: 1)
        }
        for name in ["native-integration-fixture.json", "entry-ui-fixture.json", "ui-fixture.json"] {
            let other = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: name))) as? [String: Any]
            guard let owner = other?["ownerID"] as? String, UUID(uuidString: owner) != nil, owner != fixture.ownerID else {
                throw NSError(domain: "Unsafe fixture owner", code: 1)
            }
        }
        return fixture
    }

    @MainActor static func configure(_ app: XCUIApplication) {
        app.launchEnvironment["IMORA_PHASE4_OWNED_FIXTURE"] = "legacy"
    }
}

@MainActor
final class OwnedUIFixtureGuardTests: XCTestCase {
    func testOwnedFixtureRejectsOtherPortDomainAndSimulator() throws {
        let fixture = try OwnedUIFixture.load()
        XCTAssertTrue(OwnedUIFixture.allowed(apiURL: fixture.apiURL, email: fixture.email,
            ownerID: fixture.ownerID, simulatorUDID: fixture.simulatorUDID))
        XCTAssertFalse(OwnedUIFixture.allowed(apiURL: "http://127.0.0.1:32283/api", email: fixture.email,
            ownerID: fixture.ownerID, simulatorUDID: fixture.simulatorUDID))
        XCTAssertFalse(OwnedUIFixture.allowed(apiURL: fixture.apiURL, email: "unrelated@example.invalid",
            ownerID: fixture.ownerID, simulatorUDID: fixture.simulatorUDID))
        XCTAssertFalse(OwnedUIFixture.allowed(apiURL: fixture.apiURL, email: fixture.email,
            ownerID: fixture.ownerID, simulatorUDID: "00000000-0000-0000-0000-000000000000"))
    }

    func testOwnedFixtureSignsInWithoutExposingCredentials() throws {
        continueAfterFailure = false
        let fixture = try OwnedUIFixture.load(), app = XCUIApplication()
        OwnedUIFixture.configure(app)
        app.launchEnvironment["IMORA_LAUNCH_TRACE"] = "1"
        app.launch()
        let server = app.textFields["auth-server"]
        if server.waitForExistence(timeout: 5) {
            server.tap(); server.typeText(fixture.apiURL); app.buttons["auth-continue"].tap()
            let email = app.textFields["auth-email"]
            XCTAssertTrue(email.waitForExistence(timeout: 20))
            email.tap(); email.typeText(OwnedUIFixture.placeholderEmail)
            let password = app.secureTextFields["auth-password"]
            password.tap(); password.typeText(OwnedUIFixture.placeholderPassword)
            app.buttons["auth-sign-in"].tap()
        }
        XCTAssertTrue(app.buttons["photos-source-menu"].waitForExistence(timeout: 30))
        let probe = app.scrollViews["phase4-launch-grid-probe"]
        let deadline = Date().addingTimeInterval(30)
        var matched = false
        while Date() < deadline {
            if let text = probe.value as? String, let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let latest = value["latest"] as? [String: Any],
               latest["accountID"] as? String == fixture.ownerID,
               latest["serverIdentity"] as? String == fixture.apiURL { matched = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(matched, "The real authenticated gallery must identify the owned fixture account")
    }
}
