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

    /// Activation migrates the legacy address once. Explicit setup also installs
    /// trust for the exact enrolled HTTPS address, including after sign-out,
    /// without changing the person's automatic-selection preference.
    /// Canonical encoding makes JSON formatting irrelevant to migration history.
    func applying(to config: LocalServerConfig?, activeExternal: URL, defaults: UserDefaults,
                  explicitSetup: Bool = false) -> LocalServerConfig? {
        guard let config, config.server == activeExternal, externalAPIURL == activeExternal,
              config.isEnabled,
              config.apiURL == previousLocalAPIURL || (explicitSetup && config.apiURL == identity.apiURL),
              !explicitSetup || config.identity == nil,
              ServerTrustPolicy.validServerURL(externalAPIURL),
              ServerTrustPolicy.validServerURL(previousLocalAPIURL), identity.isValid
        else { return config }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(self) else { return config }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        var applied = defaults.stringArray(forKey: Self.appliedKey) ?? []
        let wasApplied = applied.contains(digest)
        // A deliberate HTTP revert is never migrated again. Saving the exact
        // enrolled HTTPS address can restore its pin after local state is reset.
        guard !wasApplied || (explicitSetup && config.apiURL == identity.apiURL) else { return config }
        var updated = config
        updated.apiURL = identity.apiURL
        updated.identity = identity
        if !explicitSetup { updated.automaticallyUseVerifiedLocal = true }
        guard let stored = try? JSONEncoder().encode(updated) else { return config }
        defaults.set(stored, forKey: "imora.localServer")
        if !wasApplied {
            applied.append(digest)
            defaults.set(applied, forKey: Self.appliedKey)
        }
        return updated
    }
}
