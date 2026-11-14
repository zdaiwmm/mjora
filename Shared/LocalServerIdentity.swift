import CryptoKit
import Foundation
import Security

/// Public CA material enrolled through a separately authenticated channel.
/// It grants trust only inside this app, for this exact HTTPS API root.
nonisolated struct LocalServerIdentity: Codable, Equatable, Sendable {
    let apiURL: URL
    let rootCertificateDER: Data

    var isValid: Bool {
        apiURL.scheme?.lowercased() == "https" && ServerTrustPolicy.validServerURL(apiURL)
            && !rootCertificateDER.isEmpty && rootCertificateDER.count <= 65_536
            && SecCertificateCreateWithData(nil, rootCertificateDER as CFData) != nil
    }

    var fingerprint: String {
        SHA256.hash(data: rootCertificateDER).map { String(format: "%02x", $0) }.joined()
    }

    var sessionKey: String { ServerTrustPolicy(apiURL: apiURL).canonicalRoot + "|" + fingerprint }

    func validates(_ trust: SecTrust, for url: URL) -> Bool {
        guard isValid, ServerTrustPolicy(apiURL: apiURL).contains(url), let host = apiURL.host,
              let anchor = SecCertificateCreateWithData(nil, rootCertificateDER as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// A pin failure always cancels. Ordinary external HTTPS retains system
    /// trust; a configured private identity never falls back to it.
    static func answer(_ challenge: URLAuthenticationChallenge, requestURL: URL?, identity: LocalServerIdentity?,
                       completion: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let identity else { completion(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completion(.performDefaultHandling, nil); return
        }
        guard let requestURL, var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        // URLSession uses WSS for a WebSocket over the same HTTPS TLS origin.
        if components.scheme == "wss" { components.scheme = "https" }
        guard let url = components.url,
              challenge.protectionSpace.host.lowercased() == identity.apiURL.host?.lowercased(),
              challenge.protectionSpace.port == (identity.apiURL.port ?? 443),
              let trust = challenge.protectionSpace.serverTrust,
              identity.validates(trust, for: url) else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        completion(.useCredential, URLCredential(trust: trust))
    }
}
