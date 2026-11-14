import CryptoKit
import Darwin
import Foundation

nonisolated struct ShareCredentialIdentity: Codable, Equatable, Sendable {
    let apiURL: URL
    let credentialDigest: String
    let generation: UUID

    init(apiURL: URL, token: String, generation: UUID) {
        self.apiURL = URL(string: ServerTrustPolicy(apiURL: apiURL).canonicalRoot) ?? apiURL
        credentialDigest = Self.digest(token)
        self.generation = generation
    }

    private static func digest(_ token: String) -> String { Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString() }
    func matchesToken(_ token: String) -> Bool { !token.isEmpty && credentialDigest == Self.digest(token) }

    func permits(_ request: URLRequest, current: ShareCredentialIdentity?) -> Bool {
        guard self == current, let url = request.url, ServerTrustPolicy(apiURL: apiURL).contains(url),
              let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer ") else { return false }
        return matchesToken(String(authorization.dropFirst(7)))
    }
}

/// The authority file has no token. A separate stable lock file serializes
/// revocation against task.resume across the app and extension processes.
nonisolated final class ShareCredentialStore: Sendable {
    private let directory: URL
    private var identityURL: URL { directory.appending(path: "authority.json") }
    init(directory: URL) { self.directory = directory }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let lockURL = directory.appending(path: "authority.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        try ProtectedTemporaryFiles.protect(lockURL)
        guard imora_transfer_lock(descriptor, 0) == 0 else { throw POSIXError(.EIO) }
        defer { _ = imora_transfer_unlock(descriptor) }
        return try operation()
    }

    private func readUnlocked() throws -> ShareCredentialIdentity? {
        let data: Data
        do { data = try Data(contentsOf: identityURL) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let identity = try JSONDecoder().decode(ShareCredentialIdentity.self, from: data)
        guard ServerTrustPolicy.validServerURL(identity.apiURL), Data(base64Encoded: identity.credentialDigest)?.count == 32 else { throw ServerTrustError.untrustedTarget }
        return identity
    }

    func load() throws -> ShareCredentialIdentity? { try withLock { try readUnlocked() } }
    func save(_ identity: ShareCredentialIdentity?) throws {
        try withLock {
            if let identity {
                guard ServerTrustPolicy.validServerURL(identity.apiURL) else { throw ServerTrustError.untrustedTarget }
                try JSONEncoder().encode(identity).write(to: identityURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try ProtectedTemporaryFiles.protect(identityURL)
            } else {
                do { try FileManager.default.removeItem(at: identityURL) }
                catch CocoaError.fileNoSuchFile {}
            }
        }
    }
    func withCurrent<T>(_ identity: ShareCredentialIdentity, _ operation: () throws -> T) throws -> T {
        try withLock {
            guard try readUnlocked() == identity else { throw ServerTrustError.sessionExpired }
            return try operation()
        }
    }
}
