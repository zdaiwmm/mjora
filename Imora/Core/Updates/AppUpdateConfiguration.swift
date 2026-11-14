import Foundation

/// Optional private build resource. This is completely separate from photo
/// account configuration and never enrolls trust outside the update session.
nonisolated struct AppUpdateConfiguration: Decodable, Sendable {
    let schemaVersion: Int
    let apiURL: URL
    let caCertificateDERBase64: String
    let accessToken: String
    let hostId: String

    var identity: LocalServerIdentity {
        LocalServerIdentity(apiURL: apiURL, rootCertificateDER: Data(base64Encoded: caCertificateDERBase64) ?? Data())
    }

    static func bundledData(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "AppUpdateHost", withExtension: "json"),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 131_073)
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 131_072,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1,
              value.apiURL.path == "/v1", value.identity.isValid,
              !value.accessToken.isEmpty, value.accessToken.utf8.count <= 4_096,
              value.accessToken.utf8.allSatisfy({ (33...126).contains($0) }),
              AppUpdateRelease.validIdentifier(value.hostId) else { return nil }
        return value
    }
}
