import Foundation

/// A configured API root is the credential boundary. LAN roots must be
/// explicitly supplied by the account's routing configuration.
nonisolated struct ServerTrustPolicy: Sendable, Equatable {
    let apiURL: URL

    var canonicalRoot: String {
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else { return apiURL.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? apiURL.absoluteString
    }

    static func validServerURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { return false }
        return safePath(components.percentEncodedPath)
    }

    func contains(_ url: URL) -> Bool {
        guard Self.validServerURL(apiURL),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.user == nil, target.password == nil,
              target.port.map({ (1...65535).contains($0) }) ?? true,
              Self.sameOrigin(apiURL, url), Self.safePath(target.percentEncodedPath)
        else { return false }
        let root = apiURL.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.path()
        return root.isEmpty || path == "/" + root || path.hasPrefix("/" + root + "/")
    }

    func authorize(_ request: URLRequest, token: String) throws -> URLRequest {
        guard let url = request.url, contains(url) else { throw ServerTrustError.untrustedTarget }
        var request = request
        // URL fragments identify queued media's session but never go on wire.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        request.url = components.url
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              let scheme = a.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return false }
        return scheme == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (scheme == "https" ? 443 : 80)) == (b.port ?? (scheme == "https" ? 443 : 80))
    }

    private static func safePath(_ encoded: String) -> Bool {
        // Reject ambiguous separators and traversal before a proxy decodes them.
        for segment in encoded.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("%"),
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { return false }
        }
        return true
    }
}

nonisolated enum ServerTrustError: Error, LocalizedError {
    case untrustedTarget
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .untrustedTarget: String(localized: "The request target is outside the configured server.")
        case .sessionExpired: String(localized: "The account changed. Try again in the current account.")
        }
    }
}

nonisolated struct RedirectPolicy: Sendable {
    let policy: ServerTrustPolicy

    func permits(original: URLRequest, response: HTTPURLResponse, proposed: URLRequest, redirects: Int) -> Bool {
        guard redirects < 5,
              ["GET", "HEAD"].contains(original.httpMethod ?? "GET"),
              ["GET", "HEAD"].contains(proposed.httpMethod ?? "GET"),
              original.httpBody == nil, original.httpBodyStream == nil,
              let initialURL = original.url, let target = proposed.url,
              policy.contains(initialURL), policy.contains(response.url!), policy.contains(target),
              ServerTrustPolicy.sameOrigin(initialURL, target)
        else { return false }
        return true
    }
}
