import CryptoKit
import Foundation

/// Optional private build resource, enrolled through an authenticated channel.
/// Public CA data grants trust only to the account and local roots named here.
nonisolated struct LocalServerIdentityProvisioning: Codable, Equatable, Sendable {
    let externalAPIURL: URL
    let previousLocalAPIURL: URL
    let identity: LocalServerIdentity

    private static let appliedKey = "imora.localServerIdentity.appliedDigests"

    static func bundledData() -> Data? {
        guard let url = Bundle.main.url(forResource: "LocalServerIdentity", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 131_072 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Apply once, without replacing an unrelated address or enabling a local
    /// preference the person turned off. Canonical encoding makes whitespace
    /// and JSON key order irrelevant to this enrollment's identity.
    func applying(to config: LocalServerConfig?, activeExternal: URL, defaults: UserDefaults) -> LocalServerConfig? {
        guard let config, config.server == activeExternal, externalAPIURL == activeExternal,
              config.isEnabled, config.apiURL == previousLocalAPIURL,
              ServerTrustPolicy.validServerURL(externalAPIURL),
              ServerTrustPolicy.validServerURL(previousLocalAPIURL), identity.isValid
        else { return config }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(self) else { return config }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        var applied = defaults.stringArray(forKey: Self.appliedKey) ?? []
        guard !applied.contains(digest) else { return config }
        var updated = config
        updated.apiURL = identity.apiURL
        updated.identity = identity
        updated.automaticallyUseVerifiedLocal = true
        guard let stored = try? JSONEncoder().encode(updated) else { return config }
        defaults.set(stored, forKey: "imora.localServer")
        applied.append(digest)
        defaults.set(applied, forKey: Self.appliedKey)
        return updated
    }
}
