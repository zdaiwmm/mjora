import Foundation
import CryptoKit
import Synchronization

/// last known account snapshot. a relaunch paints the signed-in ui from this
/// on the very first frame instead of holding a spinner until the server
/// confirms what we already knew; the real values land a moment later.
nonisolated enum SessionCache {
    private static let key = "imora.sessionSnapshot"
    private static let userKey = "imora.userId"
    private static let mediaBindingsKey = "imora.verifiedMediaBindings.v1"
    private static let mediaBindingsRevision = Mutex<UInt64>(0)

    static var mediaScopeRevision: UInt64 { mediaBindingsRevision.withLock { $0 } }

    /// A host snapshot is display metadata, not evidence that a token belongs to its user.
    static func verifiedMediaScope(credential: String) -> StableMediaScope? {
        guard let data = UserDefaults.standard.dictionary(forKey: mediaBindingsKey)?[credential] as? Data,
              let scope = try? JSONDecoder().decode(StableMediaScope.self, from: data),
              scope.accountID?.isEmpty == false, scope.credentialScope == nil else { return nil }
        return scope
    }

    static func bindMediaScope(_ scope: StableMediaScope, credential: String) {
        guard scope.accountID?.isEmpty == false, scope.credentialScope == nil,
              let data = try? JSONEncoder().encode(scope) else { return }
        mediaBindingsRevision.withLock { revision in
            var bindings = UserDefaults.standard.dictionary(forKey: mediaBindingsKey) ?? [:]
            bindings[credential] = data
            UserDefaults.standard.set(bindings, forKey: mediaBindingsKey)
            revision &+= 1
        }
    }

    struct Snapshot: Codable {
        var host: String
        var user: CurrentUser?
        var features: ServerFeatures?
        var serverVersion: ServerVersion?
        var serverProduct: ServerProduct?
        /// imora's feature list, see `ServerIdentity`.
        var serverFeatures: [String]?
        /// the whole identity. the two fields above stay for snapshots written before it.
        var serverIdentity: ServerIdentity?
        var preferences: UserPreferences?
    }

    /// identifies the signed-in account for anything else caching per account.
    /// the id is stored the moment a login returns rather than read back out of
    /// the snapshot, so the key never changes shape mid-session and invalidates
    /// what an earlier launch wrote.
    static func accountKey(apiURL: URL, accessToken: String) -> String? {
        guard apiURL.host() != nil else { return nil }
        let credential = Data(SHA256.hash(data: Data(accessToken.utf8))).base64EncodedString()
        return "\(ServerTrustPolicy(apiURL: apiURL).canonicalRoot)|\(credential)"
    }

    static func noteUserId(_ id: String) {
        UserDefaults.standard.set(id, forKey: userKey)
    }

    static var lastKnownUserId: String? { UserDefaults.standard.string(forKey: userKey) }

    static func load(host: String) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.host == host
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
