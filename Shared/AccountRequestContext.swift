import Foundation
import Synchronization

/// Tokens and media queue identities never change during a context's lifetime.
/// A new login gets a new context even when the server and user are unchanged.
nonisolated final class AccountRequestContext: Sendable {
    let id = UUID()
    let apiURL: URL
    private let token: String
    private let active = Mutex(true)

    init(apiURL: URL, token: String) {
        self.apiURL = apiURL
        self.token = token
    }

    var isActive: Bool { active.withLock { $0 } }
    func invalidate() { active.withLock { $0 = false } }
    func startWhileActive(_ operation: () throws -> Void) throws {
        try active.withLock { value in
            guard value else { throw ServerTrustError.sessionExpired }
            try operation()
        }
    }

    func mediaURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = "imora-session=\(id.uuidString)"
        return components.url!
    }

    func policy(for url: URL, localAPIURL: URL? = nil) -> ServerTrustPolicy? {
        guard isActive else { return nil }
        if let fragment = url.fragment, fragment != "imora-session=\(id.uuidString)" { return nil }
        let external = ServerTrustPolicy(apiURL: apiURL)
        if external.contains(url) { return external }
        if let localAPIURL {
            let local = ServerTrustPolicy(apiURL: localAPIURL)
            if local.contains(url) { return local }
        }
        return nil
    }

    func authorize(_ request: URLRequest, localAPIURL: URL? = nil) throws -> URLRequest {
        guard isActive else { throw ServerTrustError.sessionExpired }
        guard let url = request.url, let policy = policy(for: url, localAPIURL: localAPIURL) else {
            throw ServerTrustError.untrustedTarget
        }
        return try policy.authorize(request, token: token)
    }
}
