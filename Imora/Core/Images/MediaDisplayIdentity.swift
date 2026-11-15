import Foundation
import CryptoKit

/// Content identity is deliberately independent of permission to read it.
nonisolated struct StableMediaScope: Codable, Hashable, Sendable {
    let serverIdentity: String
    let accountID: String?
    let credentialScope: String?

    static func verified(server: String, accountID: String) -> Self {
        Self(serverIdentity: server, accountID: accountID, credentialScope: nil)
    }

    static func credential(_ credential: String, server: String) -> Self {
        Self(serverIdentity: server, accountID: nil, credentialScope: credential)
    }
}

nonisolated struct MediaAccessGeneration: Hashable, Sendable {
    let session: UUID
    let permission: Int
}

/// An accessible PhotoKit final image can be smaller than a tile because the
/// actual source is small. Never infer this from a thumbnail's own dimensions.
nonisolated struct NativeImageResolution: Codable, Equatable, Sendable {
    let sourceRevision: String
    let pixelWidth: Int
    let pixelHeight: Int

    func accepts(width: Int, height: Int, key: MediaDisplayKeyV1) -> Bool {
        guard case .localAsset = key.subject, !sourceRevision.isEmpty,
              sourceRevision == key.sourceRevision, pixelWidth > 0, pixelHeight > 0 else { return false }
        return Double(min(width, height)) >= Double(min(pixelWidth, pixelHeight)) * 0.95
            && Double(max(width, height)) >= Double(max(pixelWidth, pixelHeight)) * 0.95
    }
}

nonisolated struct MediaDisplayKeyV1: Codable, Hashable, Sendable {
    enum Subject: Codable, Hashable, Sendable {
        case remoteAsset(String)
        case localAsset(installationID: String, localIdentifier: String)
        case artwork(kind: String, objectID: String, contentRevision: String)
    }
    enum Variant: String, Codable, Sendable {
        case grid, cover, avatar, artwork, viewerPreview, original, livePoster, motionFrame
    }
    let scope: StableMediaScope
    let subject: Subject
    let sourceRevision: String
    let presentationRevision: String
    let variant: Variant
    let pixelBucket: Int
    let fitMode: String
    let orientationRevision: String
    let colorProfile: String

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest((try? encoder.encode(self)) ?? Data())
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
