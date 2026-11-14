import Foundation
import CryptoKit

/// last known account snapshot. a relaunch paints the signed-in ui from this
/// on the very first frame instead of holding a spinner until the server
/// confirms what we already knew; the real values land a moment later.
nonisolated enum SessionCache {
    private static let key = "imora.sessionSnapshot"
    private static let userKey = "imora.userId"

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
