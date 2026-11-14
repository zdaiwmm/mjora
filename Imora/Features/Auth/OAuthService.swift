import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// pkce values for one oauth attempt.
nonisolated struct PKCE {
    let state: String
    let verifier: String
    let challenge: String

    init() {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        state = String((0..<32).map { _ in alphabet.randomElement()! })
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncoded()
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

nonisolated extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// a web sign in that came back without a code.
nonisolated enum AppLoginError: LocalizedError {
    case mismatchedState
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .mismatchedState: String(localized: "the sign in response did not match this request. try again.")
        case .refused(let error): String(localized: "the server refused the sign in: \(error).")
        }
    }
}

/// drives the system web auth sheet, the immich oauth endpoints and imora's
/// web sign in.
final class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthService()

    /// immich and gallery only apply the mobile redirect override to
    /// `app.immich`, and their mobile redirect page always bounces there, so
    /// the official app's uri is the one idp clients already allow. imora
    /// overrides any scheme but bounces to its own.
    private static func callbackScheme(isImora: Bool) -> String {
        isImora ? "app.imora" : "app.immich"
    }

    private static func redirectUri(isImora: Bool) -> String {
        "\(callbackScheme(isImora: isImora)):///oauth-callback"
    }

    private var activeSession: ASWebAuthenticationSession?

    /// runs the full flow and returns the logged-in credentials.
    /// returns nil when the user cancels the sheet.
    func logIn(apiURL: URL, isImora: Bool) async throws -> LoginResponse? {
        guard let (callback, pkce) = try await authorize(apiURL: apiURL, isImora: isImora) else { return nil }
        return try await ImoraClient.oauthCallback(
            apiURL: apiURL,
            callbackURL: callback,
            state: pkce.state,
            codeVerifier: pkce.verifier
        )
    }

    /// links the signed-in account to the provider. false when cancelled.
    func link(client: ImoraClient) async throws -> Bool {
        let isImora = await client.serverIdentity()?.product == .imora
        guard let (callback, pkce) = try await authorize(apiURL: client.apiURL, isImora: isImora) else { return false }
        try await client.linkOAuth(callbackURL: callback, state: pkce.state, codeVerifier: pkce.verifier)
        return true
    }

    /// signs in through imora's web login, where the browser's session and
    /// saved passkeys work. nil when the sheet is cancelled or the request denied.
    func appLogIn(apiURL: URL) async throws -> LoginResponse? {
        do {
            return try await appLogInAttempt(apiURL: apiURL)
        } catch ImoraError.http(400, let message) where Self.isStaleCode(message) {
            // a code is spent by any exchange, so the retry needs a new one.
            return try await appLogInAttempt(apiURL: apiURL)
        }
    }

    /// opens a page of the web app in the shared browser session. returns
    /// when the user closes the sheet.
    func browse(_ url: URL) async throws {
        do {
            _ = try await authenticate(url: url, scheme: Self.callbackScheme(isImora: true))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        }
    }

    private func appLogInAttempt(apiURL: URL) async throws -> LoginResponse? {
        let pkce = PKCE()
        let redirectUri = Self.redirectUri(isImora: true)
        let page = ImoraClient.webURL(apiURL: apiURL).appending(path: "auth/app").appending(queryItems: [
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])

        let callback: URL
        do {
            callback = try await authenticate(url: page, scheme: Self.callbackScheme(isImora: true))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == pkce.state else { throw AppLoginError.mismatchedState }
        if let error = value("error") {
            if error == "access_denied" { return nil }
            throw AppLoginError.refused(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw AppLoginError.mismatchedState }
        return try await ImoraClient.appLoginToken(
            apiURL: apiURL,
            code: code,
            codeVerifier: pkce.verifier,
            redirectUri: redirectUri
        )
    }

    /// the token exchange's 400s that a fresh code fixes.
    private static func isStaleCode(_ message: String) -> Bool {
        ["invalid or expired code", "redirect uri does not match", "code verifier does not match"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// the provider's redirect back to the app, nil when the sheet is cancelled.
    private func authorize(apiURL: URL, isImora: Bool) async throws -> (callback: String, pkce: PKCE)? {
        let pkce = PKCE()
        let scheme = Self.callbackScheme(isImora: isImora)
        let authorizeURL = try await ImoraClient.oauthAuthorize(
            apiURL: apiURL,
            redirectUri: Self.redirectUri(isImora: isImora),
            state: pkce.state,
            codeChallenge: pkce.challenge
        )

        let callback: URL
        do {
            callback = try await authenticate(url: authorizeURL, scheme: scheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }

        // some idps collapse the triple slash; normalize like the official app.
        var callbackString = callback.absoluteString
        let collapsed = "\(scheme):/oauth-callback"
        if callbackString.hasPrefix(collapsed) {
            callbackString = callbackString.replacingOccurrences(
                of: collapsed,
                with: Self.redirectUri(isImora: isImora)
            )
        }
        return (callbackString, pkce)
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        // the session cancels itself when presented before a window exists,
        // which happens on auto-launch right after startup.
        for _ in 0..<20 {
            let hasWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .contains { !$0.bounds.isEmpty }
            if hasWindow { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ImoraError.unreachable)
                }
            }
            session.presentationContextProvider = self
            // the browser's cookies and passkeys, so a signed in web session carries over.
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: ImoraError.unreachable)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
            return window
        }
        if let scene = scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        // the sheet is only started from on screen ui, so a scene always exists.
        preconditionFailure("no window scene available for oauth presentation")
    }
}
