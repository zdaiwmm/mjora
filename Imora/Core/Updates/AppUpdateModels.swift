import Foundation

nonisolated struct AppUpdateRelease: Decodable, Equatable, Identifiable, Sendable {
    let releaseId: String
    let version: String
    let build: String
    let notes: String
    var id: String { releaseId }

    var isValid: Bool {
        Self.validIdentifier(releaseId) && AppUpdateVersion(version: version, build: build) != nil
            && notes.utf8.count <= 8_192
            && !notes.unicodeScalars.contains { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }
    }

    static func validIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 128,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

nonisolated struct AppUpdateInstallation: Decodable, Equatable, Sendable {
    nonisolated enum State: String, Decodable, Sendable { case idle, queued, installing, succeeded, failed }
    nonisolated enum MessageCode: String, Decodable, Sendable { case needsPhone, needsUnlock, signInRequired, invalidPackage, busy, failed }

    let state: State
    let releaseId: String?
    let messageCode: MessageCode?

    var isValid: Bool {
        if let releaseId, !AppUpdateRelease.validIdentifier(releaseId) { return false }
        return ![.queued, .installing, .succeeded].contains(state) || releaseId != nil
    }
}

nonisolated struct AppUpdateStatus: Decodable, Sendable {
    let schemaVersion: Int
    let hostId: String
    let latest: AppUpdateRelease?
    let installation: AppUpdateInstallation?

    static func decode(_ data: Data, expectedHostID: String) throws -> Self {
        guard data.count <= AppUpdateClient.maximumResponseBytes else { throw AppUpdateError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.hostId == expectedHostID,
              value.latest?.isValid ?? true, value.installation?.isValid ?? true else { throw AppUpdateError.invalidResponse }
        return value
    }
}

extension AppUpdateStatus {
    private nonisolated enum CodingKeys: String, CodingKey { case schemaVersion, hostId, latest, installation }

    nonisolated init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        hostId = try values.decode(String.self, forKey: .hostId)
        guard values.contains(.latest), values.contains(.installation) else { throw AppUpdateError.invalidResponse }
        latest = try values.decodeIfPresent(AppUpdateRelease.self, forKey: .latest)
        installation = try values.decodeIfPresent(AppUpdateInstallation.self, forKey: .installation)
    }
}

nonisolated enum AppUpdateError: Error {
    case invalidResponse
    case invalidRelease
    case unexpectedStatus
}
