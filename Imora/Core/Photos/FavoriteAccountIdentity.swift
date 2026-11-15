import Foundation

nonisolated enum FavoriteAccountIdentity {
    /// Account identity survives token refresh. Unknown accounts keep a
    /// credential-isolated queue until the server confirms their user ID.
    static func key(server: String, userID: String?, credentialScope: String?) -> String? {
        if let userID, !userID.isEmpty { return "\(server)|user:\(userID)" }
        return credentialScope.map { "credential:\($0)" }
    }
}
