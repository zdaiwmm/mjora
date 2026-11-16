#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Simulator-only UI fixture credentials stay in the owned 0600 manifest.
nonisolated struct Phase4OwnedFixture: Decodable, Sendable {
    struct Asset: Decodable, Sendable { let id: String }
    let apiURL: String
    let email: String
    let password: String
    let ownerID: String
    let assets: [Asset]?

    static let placeholderEmail = "phase4-ui-placeholder@example.invalid"
    static let placeholderPassword = "phase4-ui-placeholder"

    /// Only account preparation and deliberate UI calibration use this mode.
    static var automaticPreparationName: String? {
        let name = ProcessInfo.processInfo.environment["IMORA_PHASE4_OWNED_FIXTURE"]
        return name == "entry" || name == "benchmark" ? name : nil
    }

    static func load(_ name: String) throws -> Phase4OwnedFixture {
        let file: String
        let simulator: String
        switch name {
        case "legacy": (file, simulator) = ("legacy-ui-fixture.json", "14BCD43F-2B3B-4D5C-A515-DCEF05889845")
        case "entry": (file, simulator) = ("entry-ui-fixture.json", "E30E1970-2CBA-44E4-BDAC-6B8EFD9F2558")
        case "benchmark": (file, simulator) = ("ui-fixture.json", "E30E1970-2CBA-44E4-BDAC-6B8EFD9F2558")
        default: throw ServerTrustError.untrustedTarget
        }
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == simulator else { throw ServerTrustError.untrustedTarget }
        let root = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4", isDirectory: true)
        let url = root.appending(path: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        guard url.resolvingSymlinksInPath().path == url.path, permissions?.intValue == 0o600 else { throw ServerTrustError.untrustedTarget }
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard fixture.apiURL == "http://127.0.0.1:33284/api", fixture.email.hasSuffix("@imora-phase4-fixture.invalid"),
              UUID(uuidString: fixture.ownerID) != nil else { throw ServerTrustError.untrustedTarget }
        for other in ["ui-fixture.json", "entry-ui-fixture.json", "legacy-ui-fixture.json", "native-integration-fixture.json"] where other != file {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: other))) as? [String: Any]
            guard let owner = object?["ownerID"] as? String, UUID(uuidString: owner) != nil, owner != fixture.ownerID else {
                throw ServerTrustError.untrustedTarget
            }
        }
        return fixture
    }
}
#endif
