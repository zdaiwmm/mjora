import Foundation
import Security

// Shared app/extension queue and credential contract.

/// Legacy ticket used only to retire old transfer sessions.
nonisolated struct ShareTicket: Codable, Sendable {
    let bodyPath: String
    let filename: String
    var identity: ShareCredentialIdentity? = nil
}

/// Protected handoff records let the app resume work after the extension exits.
/// Transfers run only while their owning process receives execution time.
nonisolated enum ShareTransfer {
    /// the group id is stamped into both info plists from one build setting, so
    /// the two targets cannot drift apart.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAAppGroup") as? String
    }

    static var container: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// multipart bodies live in the app group so they outlive the extension
    /// and stay readable when the app resumes the queue.
    static var bodyDirectory: URL? { container?.appending(path: "share-bodies") }

    /// one marker file per extension session, so the app knows which ids to
    /// reattach. files rather than a defaults array: creates and deletes from
    /// two processes can never lose each other's writes.
    static var sessionDirectory: URL? { container?.appending(path: "share-sessions") }

    static let sessionPrefix = "app.imora.share."

    /// The continued-processing task is registered and submitted by this
    /// extension because iOS delivers it back to the submitting process.
    static var uploadTaskIdentifierPattern: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAShareTaskID") as? String
    }

    static func makeUploadTaskIdentifier() -> String? {
        guard let pattern = uploadTaskIdentifierPattern else { return nil }
        let prefix = pattern.hasSuffix(".*") ? String(pattern.dropLast(2)) : pattern
        return prefix + "." + UUID().uuidString
    }

    // MARK: - credentials

    struct Credentials: Sendable {
        let identity: ShareCredentialIdentity
        let token: String
        let deviceId: String
        var apiURL: URL { identity.apiURL }
    }

    /// Nil until the app has signed in and mirrored the session into the app
    /// group so the extension can upload directly.
    static func credentials() -> Credentials? {
        guard let store = credentialStore, let identity = try? store.load(),
              let token = readToken(), identity.matchesToken(token) else { return nil }
        return Credentials(identity: identity, token: token,
            deviceId: defaults?.string(forKey: deviceIdKey) ?? "imora-share")
    }

    static var credentialStore: ShareCredentialStore? { container.map { ShareCredentialStore(directory: $0.appending(path: "share-authority")) } }
    static var queueStore: ShareQueueStore? {
        guard let container, let bodyDirectory else { return nil }
        return ShareQueueStore(directory: container.appending(path: "share-queue"), bodyDirectory: bodyDirectory)
    }

    static func withCurrent<T>(_ credentials: Credentials, _ operation: () throws -> T) throws -> T {
        guard let store = credentialStore else { throw ServerTrustError.sessionExpired }
        return try store.withCurrent(credentials.identity) {
            guard let token = readToken(), credentials.identity.matchesToken(token) else { throw ServerTrustError.sessionExpired }
            return try operation()
        }
    }

    static func mirror(apiURL: URL, token: String, deviceID: String, renew: Bool) {
        guard let store = credentialStore else { return }
        let old = try? store.load()
        let same = old?.apiURL == URL(string: ServerTrustPolicy(apiURL: apiURL).canonicalRoot) && old?.matchesToken(token) == true
        let generation = !renew && same ? (old?.generation ?? UUID()) : UUID()
        let identity = ShareCredentialIdentity(apiURL: apiURL, token: token, generation: generation)
        defaults?.set(apiURL.absoluteString, forKey: serverURLKey)
        defaults?.set(deviceID, forKey: deviceIdKey)
        try? store.save(identity)
    }

    static func revoke() { try? credentialStore?.save(nil) }

    /// the app writes the token into the app group access group; a group-less
    /// query searches every group this process can see and finds it there.
    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// app-to-extension mirror of the signed-in session. the token itself is
    /// in the keychain, written into the app group access group under the
    /// service and account below.
    static var defaults: UserDefaults? {
        guard let appGroup else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    static let serverURLKey = "imora.share.serverURL"
    static let deviceIdKey = "imora.share.deviceId"
    static let tokenService = "app.imora.credentials"
    static let tokenAccount = "accessToken"

    static func markSession(_ identifier: String) {
        guard let sessionDirectory else { return }
        try? ProtectedTemporaryFiles.prepareDirectory(sessionDirectory)
        try? Data().write(to: sessionDirectory.appending(path: identifier), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func unmarkSession(_ identifier: String) {
        guard let sessionDirectory else { return }
        try? FileManager.default.removeItem(at: sessionDirectory.appending(path: identifier))
    }

    static func encode(_ ticket: ShareTicket) -> String? {
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ description: String?) -> ShareTicket? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(ShareTicket.self, from: Data(description.utf8))
    }
}
