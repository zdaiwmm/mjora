import Foundation
import Synchronization

nonisolated enum ImoraError: LocalizedError {
    case invalidURL
    case unreachable
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "the server address is not a valid url.")
        case .unreachable: String(localized: "could not reach the server. check the address and your connection.")
        case .http(let code, let message):
            switch code {
            case 401: String(localized: "wrong email or password.")
            case 403: String(localized: "access denied.")
            default: message.isEmpty ? String(localized: "server error \(code).") : message
            }
        case .decoding(let detail): String(localized: "unexpected server response: \(detail)")
        }
    }
}

/// thin async client over the immich http api.
nonisolated final class ImoraClient: Sendable {
    /// resolved api base, e.g. https://photos.example.com/api
    let apiURL: URL
    let accessToken: String
    let context: AccountRequestContext
    private let sessions = Mutex<[String: URLSession]>([:])
    private let mediaStore = ControlledMediaStore()
    /// `apiURL` with a trailing slash, so media urls are plain concatenation.
    private let mediaBase: String
    /// what `URL.appending(queryItems:)` actually escapes in a value. matched
    /// exactly, because the thumbnail url is the image cache key.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&="))

    init(apiURL: URL, accessToken: String) {
        self.apiURL = apiURL
        self.accessToken = accessToken
        let context = AccountRequestContext(apiURL: apiURL, token: accessToken, requestAllowed: {
            ServerRoute.permitsRequest(to: $0, for: apiURL)
        })
        self.context = context
        var base = apiURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        mediaBase = base
    }

    deinit { sessions.withLock { $0.values.forEach { $0.invalidateAndCancel() } } }

    /// Each pin has its own immutable delegate and TLS connection pool. A
    /// changed certificate can never reuse a previously trusted connection.
    func transportSession(for request: URLRequest, redirectsAllowed: Bool = true) throws -> URLSession {
        _ = try authorize(request)
        let identity = try localIdentity(for: request)
        let key = (identity?.sessionKey ?? "system-trust") + (redirectsAllowed ? "|read" : "|no-redirect")
        return try sessions.withLock { values in
            guard context.isActive else { throw ServerTrustError.sessionExpired }
            if let session = values[key] { return session }
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["Accept": "application/json"]
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 20
            let context = context, apiURL = apiURL
            let policy: (@Sendable (URLRequest) -> ServerTrustPolicy?)?
            if redirectsAllowed {
                policy = { request in
                    guard let url = request.url else { return nil }
                    return context.policy(for: url, localAPIURL: ServerRoute.configuredLocal(for: apiURL))
                }
            } else { policy = nil }
            let delegate = SafeRedirectDelegate(identity: identity, policyForRequest: policy)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            values[key] = session
            return session
        }
    }

    func localIdentity(for request: URLRequest) throws -> LocalServerIdentity? {
        guard let url = request.url else { throw ServerTrustError.untrustedTarget }
        return try ServerRoute.transportIdentity(to: url, for: apiURL)
    }

    /// Nuke retains its caching/decoding pipeline; authenticated image bytes
    /// use the same fixed-identity connection selection as the API.
    func imageData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let request = try authorize(request)
        let result = try await transportSession(for: request).data(for: request)
        try Task.checkCancellation()
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        guard let response = result.1 as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ImoraError.http((result.1 as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        return result
    }


    var serverKey: String { ServerTrustPolicy(apiURL: apiURL).canonicalRoot }

    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset { try await get("assets/\(id)") }

    func repairLivePhoto(stillID: String, videoID: String) async throws {
        try await mutate("assets/\(stillID)", method: "PUT", body: ["livePhotoVideoId": videoID])
    }

    func authorizedRequest(url: URL, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: ServerRoute.resolve(url))
        request.httpMethod = method
        return try authorize(request)
    }

    private func authorize(_ request: URLRequest) throws -> URLRequest {
        try context.authorize(request, localAPIURL: ServerRoute.configuredLocal(for: apiURL))
    }

    func invalidate() {
        context.invalidate()
        sessions.withLock { values in values.values.forEach { $0.invalidateAndCancel() }; values.removeAll() }
        Task { await mediaStore.removeAll() }
    }

    func readbackOriginal(assetID: String, expected: ResourceDigest) async throws -> ResourceDigest {
        let request = try authorizedRequest(url: originalURL(assetID: assetID))
        return try await OriginalReadbackVerifier.verify(request: request, expected: expected, context: context,
            session: transportSession(for: request, redirectsAllowed: false))
    }

    func invalidateMediaCache() async { await mediaStore.invalidateCachedFiles() }

    func localMediaFile(_ url: URL) async throws -> ControlledMediaFile {
        let request = try authorizedRequest(url: url)
        return try await mediaStore.file(request: request, session: transportSession(for: request), context: context)
    }

    // MARK: - server resolution

    /// normalizes user input and finds the api endpoint, honoring /.well-known/imora.
    static func resolveAPIURL(from input: String) async throws -> URL {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ImoraError.invalidURL }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var url = URL(string: raw), url.host() != nil else { throw ImoraError.invalidURL }
        guard supportsTransport(to: url) else { throw ImoraError.invalidURL }

        let probe = ControlledSession.noRedirect
        // if the user already pointed at /api, trust it after a ping.
        if url.path().hasSuffix("/api") {
            if await ping(url, session: probe) { return url }
            throw ImoraError.unreachable
        }

        // well-known lookup lets admins host the api elsewhere.
        if let wellKnown = try? await fetchWellKnown(base: url, session: probe) {
            guard !(url.scheme?.lowercased() == "https" && wellKnown.scheme?.lowercased() == "http") else { throw ServerTrustError.untrustedTarget }
            url = wellKnown
        } else {
            url = url.appending(path: "api")
        }
        guard supportsTransport(to: url) else { throw ImoraError.invalidURL }
        guard await ping(url, session: probe) else { throw ImoraError.unreachable }
        return url
    }

    static func supportsTransport(to url: URL) -> Bool {
        ServerTrustPolicy.validServerURL(url)
    }

    private static func fetchWellKnown(base: URL, session: URLSession) async throws -> URL? {
        var request = URLRequest(url: base.appending(path: ".well-known/imora"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parsed = try JSONDecoder().decode(WellKnownImora.self, from: data)
        let endpoint = parsed.api.endpoint
        if endpoint.hasPrefix("http") { return URL(string: endpoint) }
        return base.appending(path: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func ping(_ apiURL: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: apiURL.appending(path: "server/ping"))
        request.timeoutInterval = 8
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - auth

    static func login(apiURL: URL, email: String, password: String) async throws -> LoginResponse {
        var request = URLRequest(url: apiURL.appending(path: "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOS", forHTTPHeaderField: "deviceType")
        request.setValue(deviceModel(), forHTTPHeaderField: "deviceModel")
        request.httpBody = try JSONEncoder().encode(LoginCredentials(email: email, password: password))
        guard ServerTrustPolicy.validServerURL(apiURL) else { throw ImoraError.invalidURL }
        let (data, response) = try await ControlledSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard http.statusCode == 201 || http.statusCode == 200 else {
            throw ImoraError.http(http.statusCode, Self.serverMessage(from: data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    func logout() async throws {
        _ = try await send(path: "auth/logout", method: "POST") as Data
    }

    // MARK: - account security

    /// signing out everywhere else keeps this device's session.
    func changePassword(current: String, new: String, signOutOtherDevices: Bool) async throws {
        try await mutate("auth/change-password", method: "POST", body: [
            "password": AnyEncodable(current),
            "newPassword": AnyEncodable(new),
            "invalidateSessions": AnyEncodable(signOutOtherDevices),
        ])
    }

    func sessions() async throws -> [ServerSession] { try await get("sessions") }

    func deleteSession(id: String) async throws {
        try await mutate("sessions/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// every session but this one.
    func deleteOtherSessions() async throws {
        try await mutate("sessions", method: "DELETE", body: Optional<Int>.none)
    }

    func apiKeys() async throws -> [APIKey] { try await get("api-keys") }

    /// `all` grants what the user can do, like the web's default.
    func createAPIKey(name: String) async throws -> APIKeyCreated {
        try await request("api-keys", method: "POST", body: [
            "name": AnyEncodable(name),
            "permissions": AnyEncodable(["all"]),
        ])
    }

    func renameAPIKey(id: String, name: String) async throws {
        try await mutate("api-keys/\(id)", method: "PUT", body: ["name": name])
    }

    func deleteAPIKey(id: String) async throws {
        try await mutate("api-keys/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    func passkeys() async throws -> [Passkey] { try await get("passkeys") }

    /// nil clears the name, the server refuses an empty one.
    func renamePasskey(id: String, name: String?) async throws {
        try await mutate("passkeys/\(id)", method: "PATCH", body: ["name": name])
    }

    func deletePasskey(id: String) async throws {
        try await mutate("passkeys/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// finishes an authorize flow started for this account, see `OAuthService.link`.
    func linkOAuth(callbackURL: String, state: String, codeVerifier: String) async throws {
        try await mutate("oauth/link", method: "POST", body: [
            "url": callbackURL,
            "state": state,
            "codeVerifier": codeVerifier,
        ])
    }

    func unlinkOAuth() async throws {
        try await mutate("oauth/unlink", method: "POST", body: Optional<Int>.none)
    }

    // MARK: - locked folder session

    func authStatus() async throws -> AuthStatus { try await get("auth/status") }

    /// elevates this session; a wrong pin comes back as a 4xx.
    func unlockSession(pinCode: String) async throws {
        try await mutate("auth/session/unlock", method: "POST", body: ["pinCode": pinCode])
    }

    func lockSession() async throws {
        try await mutate("auth/session/lock", method: "POST", body: Optional<Int>.none)
    }

    func setupPinCode(_ pinCode: String) async throws {
        try await mutate("auth/pin-code", method: "POST", body: ["pinCode": pinCode])
    }

    func changePinCode(current: String, new: String) async throws {
        try await mutate("auth/pin-code", method: "PUT", body: ["pinCode": current, "newPinCode": new])
    }

    /// the reset needs the account password, the pin being what was forgotten.
    func resetPinCode(password: String) async throws {
        try await mutate("auth/pin-code", method: "DELETE", body: ["password": password])
    }

    // MARK: - oauth

    /// unauthenticated fetch used by the login screen to pick the sign-in
    /// method. 3.2 serves it from /public/config; older servers only know the
    /// endpoints it deprecated.
    static func loginOptions(apiURL: URL) async -> LoginOptions? {
        // an unknown version still tries the new endpoint; a 3.1 server
        // answers it with a 404 and the legacy pair below takes over.
        let report: ServerVersionReport? = try? await publicGet(apiURL.appending(path: "server/version"))
        let identity = report?.product == "imora"
            ? ServerIdentity(product: .imora, features: Set(report?.features ?? []))
            : nil
        let appLogin = ServerCapabilities(identity: identity).supportsAppLogin
        if report?.version.supportsConfigEndpoints != false,
           let config: PublicConfigResponse = try? await publicGet(apiURL.appending(path: "public/config")) {
            var options = config.loginOptions
            options.appLogin = appLogin
            options.isImora = identity != nil
            return options
        }
        async let featuresTask: ServerFeatures? = try? publicGet(apiURL.appending(path: "server/features"))
        async let configTask: ServerConfig? = try? publicGet(apiURL.appending(path: "server/config"))
        guard let features = await featuresTask else { return nil }
        let config = await configTask
        return LoginOptions(
            passwordLogin: features.passwordLogin,
            oauth: features.oauth,
            oauthAutoLaunch: features.oauthAutoLaunch,
            oauthButtonText: config?.oauthButtonText,
            loginPageMessage: config?.loginPageMessage,
            appLogin: appLogin,
            isImora: identity != nil
        )
    }

    static func oauthAuthorize(apiURL: URL, redirectUri: String, state: String, codeChallenge: String) async throws -> URL {
        var request = URLRequest(url: apiURL.appending(path: "oauth/authorize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "redirectUri": redirectUri,
            "state": state,
            "codeChallenge": codeChallenge,
        ])
        guard ServerTrustPolicy.validServerURL(apiURL) else { throw ImoraError.invalidURL }
        let (data, response) = try await ControlledSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImoraError.http(http.statusCode, serverMessage(from: data))
        }
        let parsed = try JSONDecoder().decode(OAuthAuthorizeResponse.self, from: data)
        guard let url = URL(string: parsed.url) else { throw ImoraError.decoding(String(localized: "bad authorize url")) }
        return url
    }

    static func oauthCallback(apiURL: URL, callbackURL: String, state: String, codeVerifier: String) async throws -> LoginResponse {
        var request = URLRequest(url: apiURL.appending(path: "oauth/callback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOS", forHTTPHeaderField: "deviceType")
        request.setValue(deviceModel(), forHTTPHeaderField: "deviceModel")
        request.httpBody = try JSONEncoder().encode([
            "url": callbackURL,
            "state": state,
            "codeVerifier": codeVerifier,
        ])
        guard ServerTrustPolicy.validServerURL(apiURL) else { throw ImoraError.invalidURL }
        let (data, response) = try await ControlledSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImoraError.http(http.statusCode, serverMessage(from: data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    /// trades the one time code of imora's web sign in for a session, made like a password login.
    static func appLoginToken(apiURL: URL, code: String, codeVerifier: String, redirectUri: String) async throws -> LoginResponse {
        var request = URLRequest(url: apiURL.appending(path: "auth/app/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOS", forHTTPHeaderField: "deviceType")
        request.setValue(deviceModel(), forHTTPHeaderField: "deviceModel")
        request.httpBody = try JSONEncoder().encode([
            "code": code,
            "codeVerifier": codeVerifier,
            "redirectUri": redirectUri,
        ])
        guard ServerTrustPolicy.validServerURL(apiURL) else { throw ImoraError.invalidURL }
        let (data, response) = try await ControlledSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImoraError.http(http.statusCode, serverMessage(from: data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    /// the web app next to the api, the api url without its /api suffix.
    static func webURL(apiURL: URL) -> URL {
        apiURL.lastPathComponent == "api" ? apiURL.deletingLastPathComponent() : apiURL
    }

    private static func publicGet<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await ControlledSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImoraError.unreachable
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - core requests

    static func serverMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let messages = object["message"] as? [String] { return messages.joined(separator: "\n") }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// concurrent, like every decode below it. default actor isolation is
    /// MainActor here and approachable concurrency keeps a plain nonisolated
    /// async body on the caller's actor, so without this a timeline bucket -
    /// thousands of assets of columnar json - would be parsed on the main
    /// thread, in the middle of the scroll that asked for it.
    @concurrent
    private func send(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        var components = URLComponents(url: apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = try authorizedRequest(url: ServerRoute.resolve(components.url!), method: method)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            request = try authorize(request)
            (data, response) = try await transportSession(for: request).data(for: request)
        } catch where ServerRoute.fallBack(from: request.url, after: error, method: method) {
            request.url = components.url
            request = try authorize(request)
            (data, response) = try await transportSession(for: request).data(for: request)
        }
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImoraError.http(http.statusCode, Self.serverMessage(from: data))
        }
        return data
    }

    @concurrent
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    @concurrent
    private func request<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ path: String,
        method: String,
        body: B
    ) async throws -> T {
        let data = try await send(path: path, method: method, body: JSONEncoder().encode(body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    @discardableResult
    private func mutate<B: Encodable>(_ path: String, method: String, body: B?) async throws -> Data {
        try await send(path: path, method: method, body: body.map { try JSONEncoder().encode($0) })
    }

    // MARK: - users and server

    func currentUser() async throws -> CurrentUser { try await get("users/me") }
    func preferences() async throws -> UserPreferences { try await get("users/me/preferences") }

    func updatePreference(section: String, enabled: Bool) async throws -> UserPreferences {
        try await request("users/me/preferences", method: "PUT", body: [section: ["enabled": enabled]])
    }

    func updateEmailNotifications(_ preferences: EmailNotificationPreferences) async throws -> UserPreferences {
        try await request("users/me/preferences", method: "PUT", body: ["emailNotifications": preferences])
    }

    func updatePeopleUpdateStrategy(_ strategy: PersonUpdateStrategy) async throws -> UserPreferences {
        try await request("users/me/preferences", method: "PUT", body: ["people": ["updateStrategy": strategy.rawValue]])
    }
    func serverAbout() async throws -> ServerAbout { try await get("server/about") }

    /// what the server reports next to what the app gates on. they differ on
    /// gallery, which stamps its own release where immich puts its version.
    private struct VersionState: Sendable {
        var reported: ServerVersion?
        var api: ServerVersion?
        var probe: Task<ServerVersion?, Never>?
    }

    private let versionState = Mutex(VersionState())

    /// the immich api level every request shape is chosen by. on immich that
    /// is the reported version; gallery's level is read from what it serves.
    /// the session probes it at launch and concurrent callers share that one
    /// probe; a failed probe is retried on the next call rather than pinned,
    /// and callers fall back to the shapes every 3.x server accepts meanwhile.
    func serverVersion() async -> ServerVersion? {
        enum Step { case known(ServerVersion), waiting(Task<ServerVersion?, Never>) }
        let step: Step = versionState.withLock { state in
            if let version = state.api { return .known(version) }
            if let probe = state.probe { return .waiting(probe) }
            let probe = Task<ServerVersion?, Never> { await self.probeAPIVersion() }
            state.probe = probe
            return .waiting(probe)
        }
        switch step {
        case .known(let version):
            return version
        case .waiting(let probe):
            let fetched = await probe.value
            return versionState.withLock { state in
                state.probe = nil
                if state.api == nil { state.api = fetched }
                return state.api
            }
        }
    }

    /// an unknown product gives no level at all: a gallery release number read
    /// as an immich one would pick shapes the server never had.
    private func probeAPIVersion() async -> ServerVersion? {
        // the identity probe reads /server/version and keeps what it reported.
        let identity = await serverIdentity()
        let reported = versionState.withLock { $0.reported }
        switch identity?.product {
        case .immich: return reported
        case .gallery: return await galleryAPIVersion()
        // imora serves every route of gallery 5.7.0, its 3.2.1 rebase included.
        case .imora: return .v3_2_1
        case nil: return nil
        }
    }

    /// levels only ever name the immich release a request shape arrived in.
    /// /public/config came with the 3.2.1 rebase, gallery 5.7, together with
    /// POST /people/merge. the 3.1 date-only memory query landed in
    /// a 3.0 based gallery, so memories learn their format by trying instead.
    private func galleryAPIVersion() async -> ServerVersion? {
        do {
            _ = try await send(path: "public/config")
            return .v3_2_1
        } catch ImoraError.http(404, _) {
            return .v3_0
        } catch {
            return nil
        }
    }

    /// the websocket announces the reported version on every connect, which
    /// also catches an upgrade, a downgrade or a switch between immich and
    /// gallery while the app runs. returns the version it replaced.
    @discardableResult
    func noteServerVersion(_ version: ServerVersion) -> ServerVersion? {
        let isImmich = productState.withLock { $0.identity?.product == .immich }
        return versionState.withLock { state in
            defer {
                state.reported = version
                if isImmich { state.api = version }
            }
            return state.reported
        }
    }

    /// drops everything derived from the server after it changed underneath,
    /// an immich install may have been switched to gallery on the same
    /// address or back.
    func forgetServerDetection() {
        productState.withLock { $0 = ProductState() }
        versionState.withLock { state in
            state.api = nil
            state.probe = nil
        }
        memoryQueryDateOnly.withLock { $0 = nil }
        galleryStructuredSearch.withLock { $0 = nil }
    }

    private struct ProductState: Sendable {
        var identity: ServerIdentity?
        var probe: Task<ServerIdentity?, Never>?
    }

    private let productState = Mutex(ProductState())

    /// immich, gallery or imora, probed once and shared like the version. a
    /// failed probe stays unknown and the next call tries again.
    func serverIdentity() async -> ServerIdentity? {
        enum Step { case known(ServerIdentity), waiting(Task<ServerIdentity?, Never>) }
        let step: Step = productState.withLock { state in
            if let identity = state.identity { return .known(identity) }
            if let probe = state.probe { return .waiting(probe) }
            let probe = Task<ServerIdentity?, Never> { await self.detectIdentity() }
            state.probe = probe
            return .waiting(probe)
        }
        switch step {
        case .known(let identity):
            return identity
        case .waiting(let probe):
            let fetched = await probe.value
            return productState.withLock { state in
                state.probe = nil
                if state.identity == nil { state.identity = fetched }
                return state.identity
            }
        }
    }

    /// imora names itself in /server/version, which every server answers, so
    /// it is known from that one request. a failed request leaves the product
    /// unknown, so a flaky network cannot pass imora off as the gallery it
    /// imitates. /server/features is kept for every product, its flags gate
    /// what older servers lack.
    private func detectIdentity() async -> ServerIdentity? {
        guard let report: ServerVersionReport = try? await get("server/version") else { return nil }
        versionState.withLock { state in
            if state.reported == nil { state.reported = report.version }
        }
        let features = await serverFeaturesFingerprint()
        var identity: ServerIdentity
        if report.product == "imora" {
            identity = ServerIdentity(product: .imora, features: Set(report.features ?? []))
        } else {
            guard let product = await detectProduct(features) else { return nil }
            identity = ServerIdentity(product: product)
        }
        identity.featureLevel = report.featureLevel
        identity.serverFeatures = features.fingerprint
        identity.reportedVersion = report.version
        if identity.product == .gallery {
            async let cleanup = probeGalleryCleanup()
            async let adjustAndTrim = probeGalleryAdjustAndTrim()
            identity.hasCleanup = await cleanup
            identity.hasAdjustAndTrim = await adjustAndTrim
        }
        return identity
    }

    private enum FeaturesAnswer {
        case found(ServerFeaturesFingerprint)
        case missing
        case failed

        var fingerprint: ServerFeaturesFingerprint? {
            if case .found(let fingerprint) = self { return fingerprint }
            return nil
        }
    }

    /// public on every immich 3.x, gallery 5.x and imora server.
    private func serverFeaturesFingerprint() async -> FeaturesAnswer {
        do {
            return .found(try await get("server/features"))
        } catch ImoraError.http(404, _) {
            return .missing
        } catch {
            return .failed
        }
    }

    /// should a release drop /server/features, spaces are gallery's own route.
    private func detectProduct(_ features: FeaturesAnswer) async -> ServerProduct? {
        switch features {
        case .found(let fingerprint):
            return fingerprint.product
        case .failed:
            return nil
        case .missing:
            do {
                _ = try await send(path: "shared-spaces")
                return .gallery
            } catch ImoraError.http(404, _) {
                return .immich
            } catch {
                return nil
            }
        }
    }

    /// gallery's app asks the calendar once: 404 is a server without cleanup
    /// and 403 a user without the permission. anything else stays unknown.
    private func probeGalleryCleanup() async -> Bool? {
        do {
            _ = try await send(path: "cleanup/calendar", query: [
                URLQueryItem(name: "tz", value: TimeZone.current.identifier),
            ])
            return true
        } catch ImoraError.http(let code, _) where code == 404 || code == 403 {
            return false
        } catch {
            return nil
        }
    }

    /// gallery 5.9 added adjust and trim together with no flag. the adjust
    /// route answers an unknown asset with its access check, a 400, where an
    /// older release has no route and answers 404.
    private func probeGalleryAdjustAndTrim() async -> Bool? {
        do {
            _ = try await send(path: "assets/00000000-0000-0000-0000-000000000000/adjust")
            return true
        } catch ImoraError.http(404, _) {
            return false
        } catch ImoraError.http(let code, _) where (400..<500).contains(code) {
            return true
        } catch {
            return nil
        }
    }

    private func capabilities() async -> ServerCapabilities {
        async let identity = serverIdentity()
        let version = await serverVersion()
        return ServerCapabilities(identity: await identity, version: version)
    }

    private enum StructuredSearch { case flat, structured, trial }

    /// whether gallery took search v2, once a structured request told.
    private let galleryStructuredSearch = Mutex<Bool?>(nil)

    /// search v2 on immich 3.2 and later, see `ServerCapabilities.supportsStructuredSearch`.
    /// gallery 5.7 took the same rebase but refuses it, later releases accept
    /// it, so a gallery with that rebase tries it until it answers. imora
    /// stays flat.
    private func structuredSearch(_ capabilities: ServerCapabilities) -> StructuredSearch {
        if capabilities.supportsStructuredSearch { return .structured }
        guard capabilities.isGallery, capabilities.version.map({ $0 >= .v3_2 }) == true else { return .flat }
        switch galleryStructuredSearch.withLock({ $0 }) {
        case true?: return .structured
        case false?: return .flat
        case nil: return .trial
        }
    }

    private func noteGalleryStructuredSearch(_ accepted: Bool) {
        galleryStructuredSearch.withLock { $0 = accepted }
    }

    /// gallery's "structured search ... is not supported on this server" 400.
    private static func refusesStructuredSearch(_ error: any Error) -> Bool {
        guard case ImoraError.http(400, let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("structured search")
            && message.localizedCaseInsensitiveContains("not supported")
    }

    func serverFeatures() async throws -> ServerFeatures {
        if await serverVersion()?.supportsConfigEndpoints == true {
            let config: UserConfigResponse = try await get("config")
            return config.features
        }
        return try await get("server/features")
    }

    func serverConfig() async throws -> ServerConfig {
        if await serverVersion()?.supportsConfigEndpoints == true {
            let config: UserConfigResponse = try await get("config")
            return config.config
        }
        return try await get("server/config")
    }

    /// whether the server can send mail, for the welcome email toggle. 3.2
    /// dropped it from the features, so /config answers when it carries smtp
    /// and admins read the admin config otherwise.
    func canSendEmail(features: ServerFeatures?) async -> Bool {
        if let email = features?.email { return email }
        guard await serverVersion()?.supportsConfigEndpoints == true,
              let config: AdminNotificationConfig = try? await get("admin/config")
        else { return false }
        return config.smtpEnabled
    }
    func serverStorage() async throws -> ServerStorage { try await get("server/storage") }

    /// admins only.
    func serverStatistics() async throws -> ServerStatistics { try await get("server/statistics") }

    // MARK: - timeline

    func timeBuckets(_ filter: TimelineFilter) async throws -> [TimeBucket] {
        try await get("timeline/buckets", query: filter.queryItems)
    }

    /// concurrent so the columnar expansion - one asset struct and one parsed
    /// date per photo in the month - is unpacked off the main thread too,
    /// alongside the decode that produced it. the raw payload comes back with
    /// it so the offline store can keep the bytes instead of re-encoding them.
    @concurrent
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> (assets: [Asset], payload: Data) {
        var query = filter.queryItems
        query.append(URLQueryItem(name: "timeBucket", value: bucket))
        let data = try await send(path: "timeline/bucket", query: query)
        let columnar: TimeBucketAssets
        do {
            columnar = try JSONDecoder().decode(TimeBucketAssets.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
        return (columnar.assets(), data)
    }

    // MARK: - assets

    func assetDetail(id: String) async throws -> AssetDetail { try await get("assets/\(id)") }

    /// the spatial scene depth map, a grey png where white is nearest.
    func depthMap(assetID: String) async throws -> Data { try await send(path: "assets/\(assetID)/depth") }

    /// the text the ocr job read, needs ocr on in the server's machine learning.
    func recognizedText(assetID: String) async throws -> [AssetTextLine] { try await get("assets/\(assetID)/ocr") }

    /// partial update of one asset. only provided fields are sent, so a nil
    /// leaves the server value untouched.
    @discardableResult
    func updateAsset(
        id: String,
        description: String? = nil,
        dateTimeOriginal: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rating: Int? = nil
    ) async throws -> AssetDetail {
        var body: [String: AnyEncodable] = [:]
        if let description { body["description"] = AnyEncodable(description) }
        if let dateTimeOriginal { body["dateTimeOriginal"] = AnyEncodable(dateTimeOriginal) }
        if let latitude { body["latitude"] = AnyEncodable(latitude) }
        if let longitude { body["longitude"] = AnyEncodable(longitude) }
        if let rating { body["rating"] = AnyEncodable(rating) }
        return try await request("assets/\(id)", method: "PUT", body: body)
    }

    /// per-user favorites go through their own route, which only needs read
    /// access. elsewhere the favorite is the owner's, on the asset itself.
    func setFavorite(ids: [String], _ value: Bool) async throws {
        let body = ["ids": AnyEncodable(ids), "isFavorite": AnyEncodable(value)]
        if await capabilities().supportsPerUserFavorites {
            try await mutate("assets/favorites", method: "PUT", body: body)
        } else {
            try await mutate("assets", method: "PUT", body: body)
        }
    }

    /// the first id becomes the stack's primary. a stack whose primary is
    /// among the ids is merged into the new one rather than left behind.
    func createStack(assetIDs: [String]) async throws {
        try await mutate("stacks", method: "POST", body: ["assetIds": assetIDs])
    }

    func stack(id: String) async throws -> AssetStack { try await get("stacks/\(id)") }

    func setStackPrimary(stackID: String, assetID: String) async throws {
        try await mutate("stacks/\(stackID)", method: "PUT", body: ["primaryAssetId": assetID])
    }

    /// the photo goes back to the timeline on its own. a stack left with one
    /// photo is removed by the server.
    func removeFromStack(stackID: String, assetID: String) async throws {
        try await mutate("stacks/\(stackID)/assets/\(assetID)", method: "DELETE", body: Optional<Int>.none)
    }

    /// unstacks: every photo stays, side by side again.
    func deleteStack(id: String) async throws {
        try await mutate("stacks/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    // MARK: - asset edits, server-side non-destructive since v2.6

    @concurrent
    func assetEdits(id: String) async throws -> [AssetEdit] {
        struct Envelope: Decodable { let edits: [AssetEdit] }
        let data = try await send(path: "assets/\(id)/edits")
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).edits
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    /// replaces the asset's whole edit list; the server re-renders derivatives.
    func applyEdits(id: String, edits: [AssetEdit]) async throws {
        try await mutate("assets/\(id)/edits", method: "PUT", body: ["edits": edits])
    }

    /// Enhanced save has one complete mutation, followed by authoritative readback
    /// when the response is lost. No second write is guessed after a timeout.
    func savePhotoEdits(id: String, edits: [AssetEdit]) async throws {
        guard await capabilities().supportsPhotoEditsV1 else {
            throw ImoraError.http(400, String(localized: "This server doesn't support unified photo editing."))
        }
        try await PhotoEditPersistence.saveAtomic(intent: edits, write: { intent in
            if intent.isEmpty { try await self.clearEdits(id: id) }
            else { try await self.applyEdits(id: id, edits: intent) }
        }, read: { try await self.assetEdits(id: id) })
    }

    func clearEdits(id: String) async throws {
        try await mutate("assets/\(id)/edits", method: "DELETE", body: Optional<Int>.none)
    }

    /// neutral when the photo has none.
    func imageAdjust(id: String) async throws -> ImageAdjust {
        do {
            return try await get("assets/\(id)/adjust")
        } catch ImoraError.http(404, _) {
            return .neutral
        }
    }

    func setImageAdjust(id: String, _ adjust: ImageAdjust) async throws {
        try await mutate("assets/\(id)/adjust", method: "PUT", body: adjust)
    }

    func removeImageAdjust(id: String) async throws {
        try await mutate("assets/\(id)/adjust", method: "DELETE", body: Optional<Int>.none)
    }

    /// nil when the video is not trimmed, which the server answers with a 404.
    func videoTrim(id: String) async throws -> VideoTrim? {
        do {
            return try await get("assets/\(id)/trim")
        } catch ImoraError.http(404, _) {
            return nil
        }
    }

    func setVideoTrim(id: String, start: Double, end: Double) async throws {
        try await mutate("assets/\(id)/trim", method: "PUT", body: VideoTrim(startTime: start, endTime: end))
        await invalidateMediaCache()
    }

    func removeVideoTrim(id: String) async throws {
        try await mutate("assets/\(id)/trim", method: "DELETE", body: Optional<Int>.none)
        await invalidateMediaCache()
    }

    func setVisibility(ids: [String], _ value: AssetVisibility) async throws {
        try await mutate("assets", method: "PUT", body: ["ids": AnyEncodable(ids), "visibility": AnyEncodable(value.rawValue)])
    }

    func trashAssets(ids: [String], force: Bool = false) async throws {
        try await mutate("assets", method: "DELETE", body: ["ids": AnyEncodable(ids), "force": AnyEncodable(force)])
    }

    func restoreAssets(ids: [String]) async throws {
        try await mutate("trash/restore/assets", method: "POST", body: ["ids": ids])
    }

    func emptyTrash() async throws { try await mutate("trash/empty", method: "POST", body: Optional<Int>.none) }
    func restoreTrash() async throws { try await mutate("trash/restore", method: "POST", body: Optional<Int>.none) }

    // MARK: - media urls

    /// edited defaults to true so renders reflect server-side edits; pass
    /// false to fetch the untouched picture, e.g. inside the editor.
    /// cacheKey is the thumbhash, the official cache-buster: it changes when
    /// derivatives are re-rendered, so edits invalidate stale cached thumbs.
    /// assembled by hand rather than through urlcomponents: a fling asks for a
    /// hundred of these a frame and `appending(queryItems:)` reparses the whole
    /// url every call. the output is byte for byte what foundation produced, so
    /// thumbnails already on disk still hit.
    func thumbnailURL(assetID: String, size: String = "thumbnail", edited: Bool = true, cacheKey: String? = nil) -> URL {
        var string = mediaBase
        string += "assets/"
        string += assetID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetID
        string += "/thumbnail?size="
        string += size
        string += edited ? "&edited=true" : "&edited=false"
        if let cacheKey, !cacheKey.isEmpty {
            string += "&c="
            string += cacheKey.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? cacheKey
        }
        return context.mediaURL(URL(string: string) ?? apiURL)
    }

    /// raw original bytes. no edited param: backup dedup and download both
    /// verify checksums computed over these exact bytes.
    func originalURL(assetID: String) -> URL {
        context.mediaURL(ServerRoute.resolve(apiURL.appending(path: "assets/\(assetID)/original").appending(queryItems: [URLQueryItem(name: "edited", value: "false")])))
    }

    /// original with server-side edits applied when there are any; the right
    /// choice for share and open-style features.
    func editedOriginalURL(assetID: String) -> URL {
        context.mediaURL(ServerRoute.resolve(apiURL.appending(path: "assets/\(assetID)/original").appending(queryItems: [
            URLQueryItem(name: "edited", value: "true"),
        ])))
    }

    func playbackURL(assetID: String) -> URL {
        context.mediaURL(ServerRoute.resolve(apiURL.appending(path: "assets/\(assetID)/video/playback")))
    }

    /// cacheKey busts the portrait a featured-photo change re-rendered; the
    /// url is otherwise stable for the person's whole life.
    func personThumbnailURL(personID: String, cacheKey: String? = nil) -> URL {
        let url = apiURL.appending(path: "people/\(personID)/thumbnail")
        guard let cacheKey, !cacheKey.isEmpty else { return context.mediaURL(url) }
        return context.mediaURL(url.appending(queryItems: [URLQueryItem(name: "c", value: cacheKey)]))
    }

    func profileImageURL(userID: String) -> URL {
        context.mediaURL(apiURL.appending(path: "users/\(userID)/profile-image"))
    }

    // MARK: - albums

    func albums(isShared: Bool? = nil, isOwned: Bool? = nil, assetID: String? = nil) async throws -> [Album] {
        var query: [URLQueryItem] = []
        if let isShared { query.append(URLQueryItem(name: "isShared", value: isShared ? "true" : "false")) }
        if let isOwned { query.append(URLQueryItem(name: "isOwned", value: isOwned ? "true" : "false")) }
        if let assetID { query.append(URLQueryItem(name: "assetId", value: assetID)) }
        return try await get("albums", query: query)
    }

    func album(id: String) async throws -> Album { try await get("albums/\(id)") }

    /// ids of everything already in the album. AlbumResponseDto carries no
    /// asset list - verified against v3.1 - and walking the album's time
    /// buckets costs one request per month, which is how the web client pays
    /// for it lazily. a metadata search scoped to the album answers a thousand
    /// at a time instead, and only the ids are decoded.
    /// onPage streams each page's ids as it lands, so a huge album's picker
    /// can lock members progressively instead of waiting out every round trip.
    @discardableResult
    func albumAssetIDs(id: String, onPage: ((Set<String>) -> Void)? = nil) async throws -> Set<String> {
        let mode = structuredSearch(await capabilities())
        do {
            let ids = try await albumAssetIDs(id: id, structured: mode != .flat, onPage: onPage)
            if mode == .trial { noteGalleryStructuredSearch(true) }
            return ids
        } catch where mode == .trial && Self.refusesStructuredSearch(error) {
            noteGalleryStructuredSearch(false)
            return try await albumAssetIDs(id: id, structured: false, onPage: onPage)
        }
    }

    private func albumAssetIDs(
        id: String,
        structured supportsV2: Bool,
        onPage: ((Set<String>) -> Void)?
    ) async throws -> Set<String> {
        struct Page: Decodable {
            struct Assets: Decodable {
                struct Item: Decodable { let id: String }
                let items: [Item]
                let nextPage: String?
                let nextCursor: String?
            }
            let assets: Assets
        }

        var ids: Set<String> = []
        var page = 1
        var cursor: String?
        // 3.2 rejects the flat fields next to a cursor, and search v2 counts
        // trash in unless told otherwise.
        while true {
            try Task.checkCancellation()
            var body: [String: AnyEncodable] = ["size": AnyEncodable(1_000)]
            if supportsV2 {
                body["filter"] = AnyEncodable(SearchJSON.object([
                    "albumIds": .object(["any": .strings([id])]),
                    "trashedAt": .eq(.null),
                ]))
                if let cursor { body["cursor"] = AnyEncodable(cursor) }
            } else {
                body["albumIds"] = AnyEncodable([id])
                body["page"] = AnyEncodable(page)
            }
            let result: Page = try await request("search/metadata", method: "POST", body: body)
            let pageIDs = Set(result.assets.items.map(\.id))
            ids.formUnion(pageIDs)
            onPage?(pageIDs)
            if supportsV2 {
                guard let next = result.assets.nextCursor, !pageIDs.isEmpty else { return ids }
                cursor = next
            } else {
                guard result.assets.nextPage != nil else { return ids }
                page += 1
            }
        }
    }

    func createAlbum(name: String, description: String = "", assetIds: [String] = []) async throws -> Album {
        try await request("albums", method: "POST", body: [
            "albumName": AnyEncodable(name),
            "description": AnyEncodable(description),
            "assetIds": AnyEncodable(assetIds),
        ])
    }

    @discardableResult
    func addAssets(albumID: String, ids: [String]) async throws -> [BulkIdResult] {
        try await request("albums/\(albumID)/assets", method: "PUT", body: ["ids": ids])
    }

    @discardableResult
    func removeAssets(albumID: String, ids: [String]) async throws -> [BulkIdResult] {
        try await request("albums/\(albumID)/assets", method: "DELETE", body: ["ids": ids])
    }

    func deleteAlbum(id: String) async throws {
        try await mutate("albums/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    func updateAlbum(
        id: String,
        name: String? = nil,
        description: String? = nil,
        thumbnailAssetId: String? = nil,
        isActivityEnabled: Bool? = nil,
        order: String? = nil
    ) async throws {
        var body: [String: AnyEncodable] = [:]
        if let name { body["albumName"] = AnyEncodable(name) }
        if let description { body["description"] = AnyEncodable(description) }
        if let thumbnailAssetId { body["albumThumbnailAssetId"] = AnyEncodable(thumbnailAssetId) }
        if let isActivityEnabled { body["isActivityEnabled"] = AnyEncodable(isActivityEnabled) }
        if let order { body["order"] = AnyEncodable(order) }
        try await mutate("albums/\(id)", method: "PATCH", body: body)
    }

    /// invites users; the server defaults their role to editor, same as the
    /// official mobile client.
    func addAlbumUsers(albumID: String, userIDs: [String]) async throws {
        let users = userIDs.map { ["userId": $0] }
        try await mutate("albums/\(albumID)/users", method: "PUT", body: ["albumUsers": users])
    }

    func updateAlbumUserRole(albumID: String, userID: String, role: String) async throws {
        try await mutate("albums/\(albumID)/user/\(userID)", method: "PUT", body: ["role": role])
    }

    /// removes a shared user; passing your own id leaves the album.
    func removeAlbumUser(albumID: String, userID: String) async throws {
        try await mutate("albums/\(albumID)/user/\(userID)", method: "DELETE", body: Optional<Int>.none)
    }

    /// every visible server user, used by the invite picker.
    func allUsers() async throws -> [User] { try await get("users") }

    /// uploads a new profile image for the current user.
    func setProfileImage(data: Data, filename: String, mimeType: String) async throws {
        let boundary = "imora-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try authorizedRequest(url: ServerRoute.resolve(apiURL.appending(path: "users/profile-image")), method: "POST")
        request.httpMethod = "POST"
        request.setValue(MultipartBody.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await transportSession(for: request).upload(for: request, from: body)
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImoraError.http(http.statusCode, Self.serverMessage(from: respData))
        }
    }


    // MARK: - album activity

    /// comments and likes of a shared album, oldest first. an asset id scopes
    /// them to that photo, a like type and user id find one like.
    func activities(
        albumID: String,
        assetID: String? = nil,
        type: AlbumActivity.Kind? = nil,
        userID: String? = nil
    ) async throws -> [AlbumActivity] {
        var query = [URLQueryItem(name: "albumId", value: albumID)]
        if let assetID { query.append(URLQueryItem(name: "assetId", value: assetID)) }
        if let type { query.append(URLQueryItem(name: "type", value: type.rawValue)) }
        if let userID { query.append(URLQueryItem(name: "userId", value: userID)) }
        return try await get("activities", query: query)
    }

    func activityStatistics(albumID: String, assetID: String? = nil) async throws -> ActivityStatistics {
        var query = [URLQueryItem(name: "albumId", value: albumID)]
        if let assetID { query.append(URLQueryItem(name: "assetId", value: assetID)) }
        return try await get("activities/statistics", query: query)
    }

    /// a like when comment is nil. liking twice answers the existing like.
    func createActivity(albumID: String, assetID: String? = nil, comment: String? = nil) async throws -> AlbumActivity {
        var body: [String: AnyEncodable] = [
            "albumId": AnyEncodable(albumID),
            "type": AnyEncodable(comment == nil ? "like" : "comment"),
        ]
        if let assetID { body["assetId"] = AnyEncodable(assetID) }
        if let comment { body["comment"] = AnyEncodable(comment) }
        return try await request("activities", method: "POST", body: body)
    }

    func deleteActivity(id: String) async throws {
        try await mutate("activities/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    // MARK: - shared links

    func sharedLinks(albumID: String? = nil) async throws -> [SharedLink] {
        var query: [URLQueryItem] = []
        if let albumID { query.append(URLQueryItem(name: "albumId", value: albumID)) }
        return try await get("shared-links", query: query)
    }

    func createSharedLink(albumID: String, options: SharedLinkOptions) async throws -> SharedLink {
        var body = options.bodyFields(explicitNulls: false)
        body["type"] = AnyEncodable("ALBUM")
        body["albumId"] = AnyEncodable(albumID)
        return try await request("shared-links", method: "POST", body: body)
    }

    /// public link for a hand-picked set of assets, type INDIVIDUAL.
    func createSharedLink(assetIDs: [String], options: SharedLinkOptions) async throws -> SharedLink {
        var body = options.bodyFields(explicitNulls: false)
        body["type"] = AnyEncodable("INDIVIDUAL")
        body["assetIds"] = AnyEncodable(assetIDs)
        return try await request("shared-links", method: "POST", body: body)
    }

    func updateSharedLink(id: String, options: SharedLinkOptions) async throws -> SharedLink {
        try await request("shared-links/\(id)", method: "PATCH", body: options.bodyFields(explicitNulls: true))
    }

    func deleteSharedLink(id: String) async throws {
        try await mutate("shared-links/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// base for public share urls: the external domain when the admin set one,
    /// else the api url with its /api suffix stripped. immutable per server,
    /// so one successful lookup serves the whole session - callers await this
    /// before showing share ui, and a fresh round trip each time doubled
    /// their time to content.
    func serverWebURL() async -> URL {
        if let cached = cachedWebURL.withLock({ $0 }) { return cached }
        let fallback = Self.webURL(apiURL: apiURL)
        guard let config = try? await serverConfig() else {
            // a failed probe is not worth pinning; retry next time.
            return fallback
        }
        let resolved: URL
        if let domain = config.externalDomain, !domain.isEmpty,
           let url = URL(string: domain), url.host() != nil {
            resolved = url
        } else {
            resolved = fallback
        }
        cachedWebURL.withLock { $0 = resolved }
        return resolved
    }

    private let cachedWebURL = Mutex<URL?>(nil)

    /// account tag for offline caches, nil when the url has no host.
    var offlineAccountKey: String? {
        SessionCache.accountKey(apiURL: apiURL, accessToken: accessToken)
    }

    // MARK: - search

    /// routes to /search/smart when a context query is set, /search/metadata
    /// otherwise, mirroring the official mobile client. the body shape follows
    /// the server version, see SearchRequest.
    func search(_ filter: SearchFilter, token: SearchPageToken?) async throws -> (SearchResponse, SearchPageToken?) {
        let capabilities = await capabilities()
        let mode = structuredSearch(capabilities)
        let localTakenRange = capabilities.supportsLocalTakenRange
        let body = SearchRequest(
            filter: filter,
            token: token,
            supportsV2: mode != .flat,
            localTakenRange: localTakenRange
        )
        // only a body that went out structured tells anything.
        let isTrial = mode == .trial && {
            if case .v2 = body.shape { true } else { false }
        }()
        do {
            let response: SearchResponse = try await request(body.path, method: "POST", body: body)
            if isTrial { noteGalleryStructuredSearch(true) }
            return (response, body.nextToken(in: response.assets))
        } catch where isTrial && Self.refusesStructuredSearch(error) {
            noteGalleryStructuredSearch(false)
            let flat = SearchRequest(filter: filter, token: nil, supportsV2: false, localTakenRange: localTakenRange)
            let response: SearchResponse = try await request(flat.path, method: "POST", body: flat)
            return (response, flat.nextToken(in: response.assets))
        }
    }

    /// how many assets each filter option leaves, gallery and imora with `searchOptions`.
    func searchOptions(_ body: SearchOptionsRequest) async throws -> SearchOptionsResponse {
        try await request("search/options", method: "POST", body: body)
    }

    func searchMetadata(filters: [String: AnyEncodable]) async throws -> SearchResponse {
        try await request("search/metadata", method: "POST", body: filters)
    }

    /// distinct exif values for the filter pickers. types: country, state,
    /// city, camera-make, camera-model, camera-lens-model. narrowing params
    /// cascade the way the pickers do, and an unknown parent narrows nothing.
    /// includeNull surfaces assets with no value as the unknown facet.
    func searchSuggestions(
        type: String,
        country: SearchFilter.Facet? = nil,
        state: SearchFilter.Facet? = nil,
        make: SearchFilter.Facet? = nil,
        model: SearchFilter.Facet? = nil
    ) async throws -> [SearchFilter.Facet] {
        var query = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "includeNull", value: "true"),
        ]
        let narrowing = [("country", country), ("state", state), ("make", make), ("model", model)]
        for (name, facet) in narrowing {
            if let value = facet?.wireValue { query.append(URLQueryItem(name: name, value: value)) }
        }
        let values: [String?] = try await get("search/suggestions", query: query)
        var facets: [SearchFilter.Facet] = []
        var hasUnknown = false
        for value in values {
            if let value, !value.isEmpty {
                facets.append(.value(value))
            } else {
                hasUnknown = true
            }
        }
        facets.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        if hasUnknown { facets.append(.unknown) }
        return facets
    }

    func tags() async throws -> [Tag] { try await get("tags") }

    /// closestPersonID asks the server to order by facial similarity to that
    /// person, which the merge picker uses. pages are 1-based. the shared
    /// filters keep people one user gave another, on people sharing servers.
    func people(
        withHidden: Bool = false,
        page: Int? = nil,
        closestPersonID: String? = nil,
        sharedByID: String? = nil,
        sharedWithID: String? = nil
    ) async throws -> PeopleResponse {
        var query = [URLQueryItem(name: "withHidden", value: withHidden ? "true" : "false")]
        if let page { query.append(URLQueryItem(name: "page", value: String(page))) }
        if let closestPersonID { query.append(URLQueryItem(name: "closestPersonId", value: closestPersonID)) }
        if let sharedByID { query.append(URLQueryItem(name: "sharedById", value: sharedByID)) }
        if let sharedWithID { query.append(URLQueryItem(name: "sharedWithId", value: sharedWithID)) }
        return try await get("people", query: query)
    }

    func person(id: String) async throws -> Person { try await get("people/\(id)") }

    func explorePlaces() async throws -> [ExploreResponse] {
        try await get("search/explore")
    }

    /// one representative asset per city, alphabetical.
    func cities() async throws -> [AssetDetail] {
        try await get("search/cities")
    }

    /// birthDate is date-only "yyyy-MM-dd"; pass .some(nil) to clear it on
    /// the server, omit to leave it untouched. featureFaceAssetID names the
    /// asset whose face becomes the portrait - the server then re-renders the
    /// thumbnail in a job and announces it over the socket. userID keeps a
    /// shared person's edit to that user's own row.
    func updatePerson(
        id: String,
        name: String? = nil,
        birthDate: String?? = nil,
        isHidden: Bool? = nil,
        isFavorite: Bool? = nil,
        featureFaceAssetID: String? = nil,
        userID: String? = nil
    ) async throws {
        var body: [String: AnyEncodable] = [:]
        if let userID { body["userId"] = AnyEncodable(userID) }
        if let name { body["name"] = AnyEncodable(name) }
        if let birthDate { body["birthDate"] = AnyEncodable(birthDate) }
        if let isHidden { body["isHidden"] = AnyEncodable(isHidden) }
        if let isFavorite { body["isFavorite"] = AnyEncodable(isFavorite) }
        if let featureFaceAssetID { body["featureFaceAssetId"] = AnyEncodable(featureFaceAssetID) }
        try await mutate("people/\(id)", method: "PUT", body: body)
    }

    /// folds the given people into the target person. their assets move over
    /// and the merged people disappear from the server. since 3.2.1 the target
    /// leads the id list, and people of the same faces owned by other members
    /// of a cluster group are merged too, so results can name ids beyond ours.
    func mergePerson(targetID: String, ids: [String]) async throws -> [BulkIdResult] {
        if await serverVersion()?.supportsPeopleMerge == true {
            return try await request("people/merge", method: "POST", body: ["ids": [targetID] + ids])
        }
        return try await request("people/\(targetID)/merge", method: "POST", body: ["ids": ids])
    }

    func personStatistics(id: String) async throws -> PersonStatistics {
        try await get("people/\(id)/statistics")
    }

    func createPerson(name: String) async throws -> Person {
        try await request("people", method: "POST", body: ["name": name])
    }

    // MARK: - people sharing, immich 3.3 and imora

    /// the shares the user gave or was given, of one person when set.
    func personUsers(personID: String? = nil) async throws -> [PersonUserShare] {
        var query: [URLQueryItem] = []
        if let personID { query.append(URLQueryItem(name: "personId", value: personID)) }
        return try await get("people/users", query: query)
    }

    /// shares the people, or every person of the user when nil, with members
    /// of their cluster group. a share that exists takes the new role.
    func sharePeople(personIDs: [String]?, with userIDs: [String], role: PersonShareRole) async throws {
        var body: [String: AnyEncodable] = [
            "sharedWithIds": AnyEncodable(userIDs),
            "role": AnyEncodable(role.rawValue),
        ]
        if let personIDs {
            body["personIds"] = AnyEncodable(personIDs)
        } else {
            body["type"] = AnyEncodable("everyone")
        }
        try await mutate("people/users", method: "PUT", body: body)
    }

    /// stops sharing the person with the user. only the caller's own shares go.
    func unsharePerson(id personID: String, with userID: String) async throws {
        try await mutate("people/users", method: "DELETE", body: [["personId": personID, "sharedWithId": userID]])
    }

    // MARK: - face suggestions, gallery 5.4 and imora

    func faceSuggestions(personID: String, page: Int = 1, size: Int = 50) async throws -> FaceSuggestionPage {
        try await get("people/\(personID)/face-suggestions", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    /// assigns the face to the person.
    func confirmFaceSuggestion(personID: String, faceID: String) async throws {
        try await mutate("people/\(personID)/face-suggestions/\(faceID)/confirm", method: "POST", body: Optional<Int>.none)
    }

    /// not this person. the face stays unassigned and is not suggested again.
    func rejectFaceSuggestion(personID: String, faceID: String) async throws {
        try await mutate("people/\(personID)/face-suggestions/\(faceID)/reject", method: "POST", body: Optional<Int>.none)
    }

    // MARK: - faces

    /// every face on one asset, assigned or not. the query param is named id
    /// but the server reads it as the asset id.
    func assetFaces(assetID: String) async throws -> [AssetFace] {
        try await get("faces", query: [URLQueryItem(name: "id", value: assetID)])
    }

    /// manual person tag. the server normalizes the box against the given
    /// frame, so a whole-image box is valid when no face region is known.
    func createFace(
        assetID: String,
        personID: String,
        imageWidth: Int,
        imageHeight: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) async throws {
        try await mutate("faces", method: "POST", body: [
            "assetId": AnyEncodable(assetID),
            "personId": AnyEncodable(personID),
            "imageWidth": AnyEncodable(imageWidth),
            "imageHeight": AnyEncodable(imageHeight),
            "x": AnyEncodable(x),
            "y": AnyEncodable(y),
            "width": AnyEncodable(width),
            "height": AnyEncodable(height)
        ])
    }

    /// deletes one face row, which untags that person occurrence on the asset.
    func deleteFace(id: String, force: Bool = false) async throws {
        try await mutate("faces/\(id)", method: "DELETE", body: ["force": force])
    }

    // MARK: - map

    /// every geotagged asset the filter allows, one point each. the server has
    /// no bounds parameter here - official clients fetch the whole set once and
    /// cluster it client side.
    func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] {
        try await get("map/markers", query: options.queryItems)
    }

    // MARK: - notifications

    /// the whole inbox, newest first. immich has no push transport, so this and
    /// the on_notification socket event are the only ways an entry surfaces.
    func notifications(unreadOnly: Bool = false) async throws -> [ServerNotification] {
        var query: [URLQueryItem] = []
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "true")) }
        let items: [ServerNotification] = try await get("notifications", query: query)
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func markNotificationRead(id: String, at date: Date = Date()) async throws {
        try await mutate("notifications/\(id)", method: "PUT", body: ["readAt": APIDate.string(from: date)])
    }

    func markNotificationsRead(ids: [String], at date: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        try await mutate("notifications", method: "PUT", body: [
            "ids": AnyEncodable(ids),
            "readAt": AnyEncodable(APIDate.string(from: date)),
        ])
    }

    func deleteNotifications(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await mutate("notifications", method: "DELETE", body: ["ids": ids])
    }

    // MARK: - cluster groups

    /// pending invites to join another user's face recognition group.
    func clusterGroupRequests() async throws -> [ClusterGroupRequest] {
        try await get("cluster-groups/requests")
    }

    /// joining moves the account's people into the group's clustering.
    func acceptClusterGroupRequest(id: String) async throws {
        try await mutate("cluster-groups/requests/\(id)/accept", method: "POST", body: Optional<Int>.none)
    }

    /// declines a received invite, or takes back one the user's group sent.
    func declineClusterGroupRequest(id: String) async throws {
        try await mutate("cluster-groups/requests/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// the members, the user first.
    func clusterGroupUsers(id: String) async throws -> [User] {
        try await get("cluster-groups/\(id)/users")
    }

    /// invites the group sent that are still waiting.
    func clusterGroupSentRequests(id: String) async throws -> [ClusterGroupRequest] {
        try await get("cluster-groups/\(id)/requests")
    }

    func inviteToClusterGroup(id: String, userID: String) async throws {
        try await mutate("cluster-groups/\(id)/requests", method: "PUT", body: ["userId": userID])
    }

    /// moves the user into a group of their own. refused while nobody else is in it.
    func leaveClusterGroup(id: String) async throws {
        try await mutate("cluster-groups/\(id)/leave", method: "POST", body: Optional<Int>.none)
    }

    /// runs facial recognition again for every member, from scratch.
    func regenerateClusterGroupPeople(id: String) async throws {
        try await mutate("cluster-groups/\(id)/regenerate-people", method: "POST", body: Optional<Int>.none)
    }

    // MARK: - utilities

    /// groups of near identical photos, found by the duplicate detection job.
    func duplicates() async throws -> [DuplicateGroup] { try await get("duplicates") }

    /// keeps some photos of each group and trashes the rest. when one photo is
    /// kept, the server merges the others' albums, favorites and metadata into it.
    func resolveDuplicates(_ groups: [DuplicateResolution]) async throws -> [BulkIdResult] {
        try await request("duplicates/resolve", method: "POST", body: ["groups": groups])
    }

    /// marks a group as not duplicates.
    func dismissDuplicates(id: String) async throws {
        try await mutate("duplicates/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// the largest originals, biggest first, with their file sizes.
    func largeAssets() async throws -> [AssetDetail] {
        let data = try await send(path: "search/large-assets", method: "POST", query: [
            URLQueryItem(name: "minFileSize", value: "0"),
            URLQueryItem(name: "withExif", value: "true"),
        ])
        do {
            return try JSONDecoder().decode([AssetDetail].self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    // MARK: - library cleanup, gallery and imora

    /// the server refuses a commit or a lookup with more ids than this.
    static let cleanupMaxIDs = 1000

    func cleanupCount(_ queue: CleanupQueue, filters: CleanupFilters = CleanupFilters()) async throws -> CleanupQueueCount {
        try await get("cleanup/queues/\(queue.rawValue)/count", query: filters.queryItems(for: queue))
    }

    func cleanupPage(
        _ queue: CleanupQueue,
        filters: CleanupFilters = CleanupFilters(),
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> CleanupQueuePage {
        var query = filters.queryItems(for: queue)
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get("cleanup/queues/\(queue.rawValue)", query: query)
    }

    /// what the user's trash holds.
    func cleanupTrash() async throws -> CleanupTotals { try await get("cleanup/trash") }

    /// every date of the year, the streak counted in the device's time zone.
    func cleanupCalendar() async throws -> CleanupCalendar {
        try await get("cleanup/calendar", query: [URLQueryItem(name: "tz", value: TimeZone.current.identifier)])
    }

    /// the years with photos on this date, the most recent first.
    func cleanupRewindYears(monthDay: Int) async throws -> [CleanupRewindYear] {
        struct Envelope: Decodable { let years: [CleanupRewindYear] }
        let envelope: Envelope = try await get("cleanup/rewind/\(monthDay)")
        return envelope.years
    }

    /// one year's photos of the date, oldest first.
    func cleanupRewindAssets(monthDay: Int, year: Int) async throws -> [CleanupAsset] {
        struct Envelope: Decodable { let assets: [CleanupAsset] }
        let envelope: Envelope = try await get("cleanup/rewind/\(monthDay)/\(year)")
        return envelope.assets
    }

    /// trashes, favorites and keeps in one go, skipping what changed meanwhile.
    /// a trash is permanent when the server's trash is off.
    func cleanupCommit(_ commit: CleanupCommit) async throws -> CleanupCommitResult {
        try await request("cleanup/commit", method: "POST", body: commit)
    }

    /// undoes keeps, the photos come back to the queue.
    func cleanupForget(queue: CleanupQueue, assetIDs: [String]) async throws {
        try await mutate("cleanup/decisions", method: "DELETE", body: [
            "queue": AnyEncodable(queue.rawValue),
            "assetIds": AnyEncodable(assetIDs),
        ])
    }

    func cleanupInSpaces(assetIDs: [String]) async throws -> CleanupInSpaces {
        try await request("cleanup/in-spaces", method: "POST", body: ["assetIds": assetIDs])
    }

    // MARK: - shared spaces, gallery only

    func sharedSpaces() async throws -> [SharedSpace] { try await get("shared-spaces") }

    func sharedSpace(id: String) async throws -> SharedSpace { try await get("shared-spaces/\(id)") }

    func sharedSpaceMembers(id: String) async throws -> [SharedSpaceMember] {
        try await get("shared-spaces/\(id)/members")
    }

    /// gallery 5.2 and later, see `SharedSpace.supportsAlbums`.
    func sharedSpaceAlbums(id: String) async throws -> [SharedSpaceAlbum] {
        try await get("shared-spaces/\(id)/albums")
    }

    /// editors and owners only. photos join by reference, nothing is copied.
    func addAssets(spaceID: String, ids: [String]) async throws {
        try await mutate("shared-spaces/\(spaceID)/assets", method: "POST", body: ["assetIds": ids])
    }

    func createSharedSpace(name: String, description: String?) async throws -> SharedSpace {
        var body: [String: AnyEncodable] = ["name": AnyEncodable(name)]
        if let description, !description.isEmpty { body["description"] = AnyEncodable(description) }
        return try await request("shared-spaces", method: "POST", body: body)
    }

    /// name and description are owner-only on gallery 5.0, editors may too
    /// later, and no field tells the two apart, so the app offers it to owners.
    func updateSharedSpace(id: String, name: String, description: String) async throws -> SharedSpace {
        try await request("shared-spaces/\(id)", method: "PATCH", body: [
            "name": name,
            "description": description,
        ])
    }

    /// owners only. photos stay in their owners' libraries.
    func deleteSharedSpace(id: String) async throws {
        try await mutate("shared-spaces/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// owners only. the server adds viewers when no role is given.
    func addSharedSpaceMember(spaceID: String, userID: String, role: SharedSpaceRole) async throws -> SharedSpaceMember {
        try await request("shared-spaces/\(spaceID)/members", method: "POST", body: [
            "userId": userID,
            "role": role.rawValue,
        ])
    }

    /// owners only, and never for themselves.
    func updateSharedSpaceMember(spaceID: String, userID: String, role: SharedSpaceRole) async throws -> SharedSpaceMember {
        try await request("shared-spaces/\(spaceID)/members/\(userID)", method: "PATCH", body: ["role": role.rawValue])
    }

    /// owners remove anyone else; any other member may remove themselves,
    /// which is leaving. an owner cannot leave.
    func removeSharedSpaceMember(spaceID: String, userID: String) async throws {
        try await mutate("shared-spaces/\(spaceID)/members/\(userID)", method: "DELETE", body: Optional<Int>.none)
    }

    /// whether this space's photos join the member's own main timeline.
    func setSharedSpaceShownInTimeline(spaceID: String, _ shown: Bool) async throws {
        try await mutate("shared-spaces/\(spaceID)/members/me/timeline", method: "PATCH", body: ["showInTimeline": shown])
    }

    /// editors and owners only. the photos stay in their owners' libraries.
    func removeAssets(spaceID: String, ids: [String]) async throws {
        try await mutate("shared-spaces/\(spaceID)/assets", method: "DELETE", body: ["assetIds": ids])
    }

    // MARK: - user groups, gallery only

    /// the groups the user made. each belongs to its creator alone.
    func userGroups() async throws -> [UserGroup] { try await get("user-groups") }

    func createUserGroup(name: String, color: String?) async throws -> UserGroup {
        var body: [String: String] = ["name": name]
        if let color { body["color"] = color }
        return try await request("user-groups", method: "POST", body: body)
    }

    func updateUserGroup(id: String, name: String, color: String?) async throws -> UserGroup {
        var body: [String: String] = ["name": name]
        if let color { body["color"] = color }
        return try await request("user-groups/\(id)", method: "PATCH", body: body)
    }

    func deleteUserGroup(id: String) async throws {
        try await mutate("user-groups/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    /// replaces the whole member list.
    func setUserGroupMembers(id: String, userIDs: [String]) async throws -> [UserGroupMember] {
        try await request("user-groups/\(id)/members", method: "PUT", body: ["userIds": userIDs])
    }

    // MARK: - memories

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 3.0 only takes a datetime here and 400s on a bare day. its web sends
    /// the local wall clock stamped as utc, so this does too.
    private static let localWallClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// the format the server accepted last, once one was rejected.
    private let memoryQueryDateOnly = Mutex<Bool?>(nil)

    /// immich switched `for` to a bare day in 3.1, gallery in a 3.0 based
    /// release, so the api level only picks the first try and a 400 flips it.
    func memories() async throws -> [Memory] {
        try await get("memories", query: [URLQueryItem(name: "isUpcoming", value: "false"),
                                         URLQueryItem(name: "size", value: "24")])
    }

    func memories(for date: Date) async throws -> [Memory] {
        let learned = memoryQueryDateOnly.withLock { $0 }
        var dateOnly: Bool
        if let learned {
            dateOnly = learned
        } else {
            dateOnly = await serverVersion()?.supportsDateOnlyMemoryQuery != false
        }
        do {
            return try await memories(for: date, dateOnly: dateOnly)
        } catch ImoraError.http(400, _) where learned == nil {
            dateOnly.toggle()
            let fetched = try await memories(for: date, dateOnly: dateOnly)
            memoryQueryDateOnly.withLock { $0 = dateOnly }
            return fetched
        }
    }

    private func memories(for date: Date, dateOnly: Bool) async throws -> [Memory] {
        let value = dateOnly
            ? Self.dayFormatter.string(from: date)
            : Self.localWallClockFormatter.string(from: date)
        return try await get("memories", query: [URLQueryItem(name: "for", value: value)])
    }

    /// saved memories survive the server's 30 day cleanup, the web's favorite.
    func setMemorySaved(id: String, isSaved: Bool) async throws {
        try await mutate("memories/\(id)", method: "PUT", body: ["isSaved": isSaved])
    }

    /// the photos stay, only the memory goes. nightly generation may make a
    /// new one for the same day.
    func deleteMemory(id: String) async throws {
        try await mutate("memories/\(id)", method: "DELETE", body: Optional<Int>.none)
    }

    // MARK: - administration, users

    /// every account, deleted ones included. the optional id narrows it to
    /// one account, which is how the web reads a deleted user - the plain
    /// GET /admin/users/{id} refuses those.
    func adminUsers(id: String? = nil, withDeleted: Bool = true) async throws -> [AdminUser] {
        var query: [URLQueryItem] = []
        if let id { query.append(URLQueryItem(name: "id", value: id)) }
        if withDeleted { query.append(URLQueryItem(name: "withDeleted", value: "true")) }
        return try await get("admin/users", query: query)
    }

    func createAdminUser(_ fields: [String: AnyEncodable]) async throws -> AdminUser {
        try await request("admin/users", method: "POST", body: fields)
    }

    /// partial update; a field set to an explicit null clears it, which is
    /// how a pin code is reset and a quota made unlimited.
    func updateAdminUser(id: String, fields: [String: AnyEncodable]) async throws -> AdminUser {
        try await request("admin/users/\(id)", method: "PUT", body: fields)
    }

    /// queues the removal, or with force starts it right away. the response
    /// is the account with its deletion date set.
    func deleteAdminUser(id: String, force: Bool) async throws -> AdminUser {
        try await request("admin/users/\(id)", method: "DELETE", body: ["force": force])
    }

    func restoreAdminUser(id: String) async throws -> AdminUser {
        try await request("admin/users/\(id)/restore", method: "POST", body: Optional<Int>.none)
    }

    func adminUserPreferences(id: String) async throws -> AdminUserPreferences {
        try await get("admin/users/\(id)/preferences")
    }

    func adminUserSessions(id: String) async throws -> [UserSession] {
        try await get("admin/users/\(id)/sessions")
    }

    func adminUserStatistics(id: String) async throws -> AssetStatistics {
        try await get("admin/users/\(id)/statistics")
    }

    /// upload activity per day between two date-only bounds.
    func adminUserUploadHeatmap(id: String, from: String, to: String) async throws -> CalendarHeatmap {
        try await get("admin/users/\(id)/calendar-heatmap", query: [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "type", value: "Upload"),
        ])
    }

    // MARK: - administration, job queues

    /// every queue with its counters. servers older than the queues api
    /// answer 404 there and still serve the same numbers keyed by name on
    /// the legacy jobs route.
    func queues() async throws -> [Queue] {
        do {
            return try await get("queues")
        } catch ImoraError.http(404, _) {
            let legacy: [String: LegacyQueue] = try await get("jobs")
            return legacy.map { name, queue in
                Queue(name: name, isPaused: queue.queueStatus.isPaused, statistics: queue.jobCounts)
            }
            .sorted { $0.name < $1.name }
        }
    }

    /// the legacy command route works on every server version. force is
    /// tri-state on purpose: the face detection refresh sends no flag at all.
    func runQueueCommand(name: String, command: QueueCommand, force: Bool?) async throws {
        var body: [String: AnyEncodable] = ["command": AnyEncodable(command.rawValue)]
        if let force { body["force"] = AnyEncodable(force) }
        try await mutate("jobs/\(name)", method: "PUT", body: body)
    }

    func createJob(_ job: ManualJob) async throws {
        try await mutate("jobs", method: "POST", body: ["name": job.rawValue])
    }

    // MARK: - backup

    /// downloads an asset's original file into `directory` and returns its url.
    /// the caller owns the returned file. the extension matters: photokit
    /// infers the resource type from it when importing.
    func downloadOriginal(assetID: String, to directory: URL, fileExtension: String) async throws -> URL {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let request = try authorizedRequest(url: originalURL(assetID: assetID))
        let (tempURL, response) = try await transportSession(for: request).download(for: request)
        guard context.isActive else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ServerTrustError.sessionExpired
        }
        guard let http = response as? HTTPURLResponse else { throw ImoraError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImoraError.http(http.statusCode, "")
        }
        var destination = directory.appending(path: "download-\(UUID().uuidString)")
        if !fileExtension.isEmpty {
            destination = destination.appendingPathExtension(fileExtension)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        try ProtectedTemporaryFiles.protect(destination)
        return destination
    }

    /// asks the server which checksums it already stores. only a
    /// reject/duplicate result with an asset id proves the bytes exist.
    /// concurrent: a first backup runs one of these per hundred assets, and
    /// the encode and decode were landing on the main thread each time.
    @concurrent
    func bulkUploadCheck(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        struct Envelope: Decodable { let results: [BulkUploadCheckResult] }
        let body = try JSONEncoder().encode(["assets": items])
        let data = try await send(path: "assets/bulk-upload-check", method: "POST", body: body)
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).results
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    /// multipart upload of one asset, handed to the background session so the
    /// transfer survives the app being suspended. takes ownership of
    /// `bodyURL`, the request body built from `upload.form` inside
    /// `BackgroundUploader.bodyDirectory`. onProgress receives the sent
    /// fraction, `account` routes a completion that outlives this process,
    /// and `lease` is released once the system owns the transfer.
    @concurrent
    func uploadAsset(
        _ upload: AssetUploadRequest,
        bodyURL: URL,
        account: String,
        source: BackupEntry,
        maximumRequestBytes: Int64? = nil,
        lease: ProcessLease? = nil,
        lifetime: BackgroundUploader.RunLifetime? = nil,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)? = nil,
        beforeUpload: (@Sendable () async throws -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AssetUploadResult {
        do {
            // multipart headers count toward Cloudflare's request-body cap.
            try UploadSizeLimit.check(bodyURL, maximumBytes: maximumRequestBytes)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        var request = try authorizedRequest(url: ServerRoute.resolve(apiURL.appending(path: "assets")), method: "POST")
        request.httpMethod = "POST"
        request.setValue(MultipartBody.contentType(boundary: upload.boundary), forHTTPHeaderField: "Content-Type")
        request = UploadChecksumHeader.apply(upload.checksum, verifiedProduct: await serverIdentity()?.product.rawValue, to: request)
        // the background session carries none of this client's session headers.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        request = try authorize(request)
        do { try await beforeUpload?() }
        catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        let ticket = BackgroundUploader.Ticket(
            account: account,
            localId: upload.deviceAssetId,
            isMotion: upload.isMotion,
            bodyPath: bodyURL.path,
            source: source
        )
        let data: Data
        do {
            data = try await BackgroundUploader.shared.upload(
                request,
                fromFile: bodyURL,
                ticket: ticket,
                context: context,
                lease: lease,
                lifetime: lifetime,
                onByteProgress: onByteProgress,
                onProgress: onProgress
            )
        } catch {
            // the backup retries on its own, over the external address now.
            _ = ServerRoute.fallBack(from: request.url, after: error, method: "POST")
            throw error
        }
        do {
            return try JSONDecoder().decode(AssetUploadResult.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    func acceptsChunkedUploads() async -> Bool {
        ServerCapabilities(identity: await serverIdentity()).supportsChunkedUploads
    }

    /// imora's resumable upload. the server finds an open session by
    /// checksum, so asking again is how an interrupted upload resumes.
    @concurrent
    func openUploadSession(_ upload: AssetUploadRequest, filename: String, size: Int64) async throws -> UploadSessionStart {
        var body = Dictionary(uniqueKeysWithValues: upload.form.fields.map { ($0.name, AnyEncodable($0.value)) })
        body["filename"] = AnyEncodable(filename)
        body["size"] = AnyEncodable(size)
        body["checksum"] = AnyEncodable(upload.checksum)
        let data = try await send(path: "assets/uploads", method: "POST", body: JSONEncoder().encode(body))
        do {
            return try JSONDecoder().decode(UploadSessionStart.self, from: data)
        } catch {
            throw ImoraError.decoding("\(error)")
        }
    }

    /// one raw chunk at `offset`, through the background session like a whole
    /// upload. returns the asset once the chunk completes the file. takes
    /// ownership of `bodyURL`.
    @concurrent
    func uploadChunk(
        sessionID: String,
        offset: Int64,
        bodyURL: URL,
        upload: AssetUploadRequest,
        account: String,
        source: BackupEntry,
        lease: ProcessLease? = nil,
        lifetime: BackgroundUploader.RunLifetime? = nil,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AssetUploadResult? {
        var request = URLRequest(url: ServerRoute.resolve(apiURL.appending(path: "assets/uploads/\(sessionID)")))
        request.httpMethod = "PATCH"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        request = try authorize(request)
        let ticket = BackgroundUploader.Ticket(
            account: account,
            localId: upload.deviceAssetId,
            isMotion: upload.isMotion,
            bodyPath: bodyURL.path,
            source: source,
            isChunk: true
        )
        let data: Data
        do {
            data = try await BackgroundUploader.shared.upload(
                request,
                fromFile: bodyURL,
                ticket: ticket,
                context: context,
                lease: lease,
                lifetime: lifetime,
                onByteProgress: onByteProgress,
                onProgress: onProgress
            )
        } catch {
            _ = ServerRoute.fallBack(from: request.url, after: error, method: "PATCH")
            throw error
        }
        // a chunk short of the end answers with the server's new offset.
        return try? JSONDecoder().decode(AssetUploadResult.self, from: data)
    }

    func cancelUploadSession(_ id: String) async throws {
        _ = try await send(path: "assets/uploads/\(id)", method: "DELETE")
    }
}

// MARK: - timeline filter

nonisolated struct TimelineFilter: Hashable {
    var visibility: AssetVisibility? = .timeline
    var withPartners = false
    /// gallery only: mixes in the spaces the user chose to show on the timeline.
    var withSharedSpaces = false
    var withStacked = false
    var isFavorite: Bool?
    var isTrashed: Bool?
    var albumId: String?
    /// gallery only: one shared space's timeline.
    var spaceId: String?
    var personId: String?
    var userId: String?
    var order: String?
    /// takenAt (default) or createdAt for upload-time ordering.
    var orderBy: String?
    /// "west,south,east,north" - restricts the buckets to a map area.
    var bbox: String?

    /// recently-added screens bucket and group by upload time.
    var groupsByUploadDate: Bool { orderBy == "createdAt" }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let bbox { items.append(.init(name: "bbox", value: bbox)) }
        if let visibility { items.append(.init(name: "visibility", value: visibility.rawValue)) }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        if withSharedSpaces { items.append(.init(name: "withSharedSpaces", value: "true")) }
        if withStacked { items.append(.init(name: "withStacked", value: "true")) }
        if let isFavorite { items.append(.init(name: "isFavorite", value: isFavorite ? "true" : "false")) }
        if let isTrashed { items.append(.init(name: "isTrashed", value: isTrashed ? "true" : "false")) }
        if let albumId { items.append(.init(name: "albumId", value: albumId)) }
        if let spaceId { items.append(.init(name: "spaceId", value: spaceId)) }
        if let personId { items.append(.init(name: "personId", value: personId)) }
        if let userId { items.append(.init(name: "userId", value: userId)) }
        if let order { items.append(.init(name: "order", value: order)) }
        if let orderBy { items.append(.init(name: "orderBy", value: orderBy)) }
        return items
    }
}

// MARK: - map marker options

/// query side of GET /map/markers. flags are only sent when true, matching the
/// official web client - the server treats a missing flag as "no".
nonisolated struct MapMarkerOptions: Hashable, Sendable {
    var isFavorite = false
    var isArchived = false
    var withPartners = false
    var withSharedAlbums = false
    var createdAfter: Date?
    var createdBefore: Date?

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if isFavorite { items.append(.init(name: "isFavorite", value: "true")) }
        if isArchived { items.append(.init(name: "isArchived", value: "true")) }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        if withSharedAlbums { items.append(.init(name: "withSharedAlbums", value: "true")) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let createdAfter { items.append(.init(name: "fileCreatedAfter", value: iso.string(from: createdAfter))) }
        if let createdBefore { items.append(.init(name: "fileCreatedBefore", value: iso.string(from: createdBefore))) }
        return items
    }
}

// MARK: - backup dtos

nonisolated struct BulkUploadCheckItem: Encodable, Sendable {
    let id: String
    let checksum: String
}

nonisolated struct BulkUploadCheckResult: Decodable, Sendable {
    let id: String
    let action: String
    let reason: String?
    let assetId: String?
    let isTrashed: Bool?

    /// the only combination that proves the server stores these bytes.
    var isConfirmedDuplicate: Bool {
        action == "reject" && reason == "duplicate" && assetId != nil
    }

    var isUnsupported: Bool {
        action == "reject" && reason == "unsupported-format"
    }
}

nonisolated struct AssetUploadRequest: Sendable {
    var checksum: String
    var deviceAssetId: String
    var deviceId: String
    var fileCreatedAt: Date
    var fileModifiedAt: Date
    var isFavorite: Bool
    var durationMs: Int
    var livePhotoVideoId: String?
    /// hides the motion part of a live photo from the timeline.
    var hidden = false
    /// which half of a live photo this is, so a completion that outlives the
    /// app lands on the right side of the index entry.
    var isMotion = false
    let boundary = "imora-\(UUID().uuidString)"

    var form: MultipartBody.Form {
        var fields: [(name: String, value: String)] = [
            ("deviceAssetId", deviceAssetId),
            ("deviceId", deviceId),
            ("fileCreatedAt", APIDate.string(from: fileCreatedAt)),
            ("fileModifiedAt", APIDate.string(from: fileModifiedAt)),
            ("isFavorite", isFavorite ? "true" : "false"),
            ("duration", String(durationMs)),
        ]
        if let livePhotoVideoId {
            fields.append(("livePhotoVideoId", livePhotoVideoId))
        }
        if hidden {
            fields.append(("visibility", "hidden"))
        }
        return MultipartBody.Form(fields: fields, fileField: "assetData", boundary: boundary)
    }
}

nonisolated struct AssetUploadResult: Decodable, Sendable {
    let id: String
    /// created, replaced or duplicate today - kept as a string so new
    /// server statuses stay a success instead of a decoding failure.
    let status: String

    var isDuplicate: Bool { status == "duplicate" }
}

/// a session to send chunks to, or the asset when the server already has the file.
nonisolated enum UploadSessionStart: Decodable, Sendable {
    case open(id: String, offset: Int64)
    case finished(AssetUploadResult)

    private enum CodingKeys: String, CodingKey {
        case uploadId, offset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .uploadId) {
            self = .open(id: id, offset: try container.decode(Int64.self, forKey: .offset))
        } else {
            self = .finished(try AssetUploadResult(from: decoder))
        }
    }
}

// MARK: - shared link options

/// editable fields of a shared link. create omits empty optionals, edit sends
/// explicit nulls so clearing a password or expiry sticks.
nonisolated struct SharedLinkOptions: Sendable {
    var description = ""
    var password = ""
    var slug = ""
    var showMetadata = true
    var allowDownload = true
    var allowUpload = false
    var expiresAt: Date?

    init() {}

    init(from link: SharedLink) {
        description = link.description ?? ""
        password = link.password ?? ""
        slug = link.slug ?? ""
        showMetadata = link.showMetadata
        allowDownload = link.allowDownload
        allowUpload = link.allowUpload
        expiresAt = link.expiryDate
    }

    func bodyFields(explicitNulls: Bool) -> [String: AnyEncodable] {
        var fields: [String: AnyEncodable] = [
            "showMetadata": AnyEncodable(showMetadata),
            "allowDownload": AnyEncodable(allowDownload),
            "allowUpload": AnyEncodable(allowUpload),
        ]
        for (key, value) in [("description", description), ("password", password), ("slug", slug)] {
            if !value.isEmpty {
                fields[key] = AnyEncodable(value)
            } else if explicitNulls {
                fields[key] = AnyEncodable(Optional<String>.none)
            }
        }
        if let expiresAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields["expiresAt"] = AnyEncodable(iso.string(from: expiresAt))
        } else if explicitNulls {
            fields["expiresAt"] = AnyEncodable(Optional<String>.none)
        }
        return fields
    }
}

// MARK: - helpers

nonisolated struct AnyEncodable: Encodable {
    private let encodeClosure: @Sendable (Encoder) throws -> Void

    init<T: Encodable & Sendable>(_ value: T) {
        encodeClosure = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
