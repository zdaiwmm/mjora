import CoreLocation
import Foundation
import Network
import NetworkExtension
import Observation
import Synchronization
import UIKit

/// a second address for the signed in server, used on the wi-fi networks
/// listed here. the external api url stays the identity of the account.
nonisolated struct LocalServerConfig: Codable, Equatable, Sendable {
    /// the external api url this belongs to, so it never follows a sign in to
    /// another server.
    var server: URL
    var apiURL: URL?
    var networks: [String] = []
    var isEnabled = true
    var identity: LocalServerIdentity?
    var automaticallyUseVerifiedLocal = false

    var isUsable: Bool { isEnabled && apiURL.map(ServerTrustPolicy.validServerURL) == true }

    var verifiedIdentity: LocalServerIdentity? {
        guard let identity, identity.isValid, identity.apiURL == apiURL else { return nil }
        return identity
    }

    init(server: URL, apiURL: URL? = nil, networks: [String] = [], isEnabled: Bool = true,
         identity: LocalServerIdentity? = nil, automaticallyUseVerifiedLocal: Bool = false) {
        self.server = server
        self.apiURL = apiURL
        self.networks = networks
        self.isEnabled = isEnabled
        self.identity = identity
        self.automaticallyUseVerifiedLocal = automaticallyUseVerifiedLocal
    }

    private enum CodingKeys: String, CodingKey {
        case server, apiURL, networks, isEnabled, identity, automaticallyUseVerifiedLocal
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        server = try values.decode(URL.self, forKey: .server)
        apiURL = try values.decodeIfPresent(URL.self, forKey: .apiURL)
        networks = try values.decodeIfPresent([String].self, forKey: .networks) ?? []
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        identity = try values.decodeIfPresent(LocalServerIdentity.self, forKey: .identity)
        automaticallyUseVerifiedLocal = try values.decodeIfPresent(Bool.self, forKey: .automaticallyUseVerifiedLocal) ?? false
    }

    /// http by default: a server on the home network rarely has a certificate.
    static func apiURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var url = URL(string: raw), ImoraClient.supportsTransport(to: url) else { return nil }
        if url.lastPathComponent != "api" { url = url.appending(path: "api") }
        return url
    }
}

/// rewrites requests for the signed in server onto its local address while
/// that one is in use. urls keep the external address everywhere else, since
/// they double as image cache keys and account tags, so a switch never splits
/// a cache or the backup index.
nonisolated enum ServerRoute {
    private struct Bases: Sendable {
        var external: URL
        var local: URL
        var allowsFallback: Bool
        let identity: LocalServerIdentity?
        var isReady: Bool
    }

    private static let bases = Mutex<Bases?>(nil)

    static var isLocal: Bool { bases.withLock { $0?.isReady == true } }

    static func resolve(_ url: URL) -> URL {
        guard let bases = bases.withLock({ $0 }) else { return url }
        guard ServerTrustPolicy(apiURL: bases.external).contains(url) else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let local = URLComponents(url: bases.local, resolvingAgainstBaseURL: false)!
        components.scheme = local.scheme
        components.host = local.host
        components.port = local.port
        let root = bases.external.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localRoot = bases.local.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = components.path.dropFirst(root.isEmpty ? 0 : root.count + 1)
        components.path = (localRoot.isEmpty ? "" : "/" + localRoot) + suffix
        return components.url ?? url
    }

    static func use(local: URL?, external: URL?, allowsFallback: Bool = true, identity: LocalServerIdentity? = nil) {
        guard let local, let external else {
            bases.withLock { $0 = nil }
            return
        }
        guard ServerTrustPolicy.validServerURL(local), ServerTrustPolicy.validServerURL(external) else { return }
        guard identity == nil || (identity?.isValid == true && identity?.apiURL == local) else { return }
        bases.withLock { $0 = Bases(external: external, local: local, allowsFallback: allowsFallback, identity: identity, isReady: true) }
    }

    /// Keep the selected destination while denying new account requests.
    /// A held manual connection never means permission to use the WAN route.
    static func holdManual(local: URL, external: URL, identity: LocalServerIdentity?) {
        guard ServerTrustPolicy.validServerURL(local), ServerTrustPolicy.validServerURL(external),
              identity == nil || (identity?.isValid == true && identity?.apiURL == local)
        else { return }
        bases.withLock { $0 = Bases(external: external, local: local, allowsFallback: false, identity: identity, isReady: false) }
    }

    static func permitsRequest(to url: URL, for external: URL) -> Bool {
        bases.withLock { route in
            let isExternal = ServerTrustPolicy(apiURL: external).contains(url)
            guard let route, route.external == external else { return isExternal }
            guard route.isReady else { return false }
            // Manual local mode also rejects a captured external URL. Callers
            // resolve canonical URLs just before authorizing them instead.
            return (route.allowsFallback && isExternal) || ServerTrustPolicy(apiURL: route.local).contains(url)
        }
    }

    /// One pool-selection decision keeps a local pin from becoming nil/system
    /// trust if the route is held or reset after a request was authorized.
    static func transportIdentity(to url: URL, for external: URL, defaults: UserDefaults = .standard) throws -> LocalServerIdentity? {
        let config = defaults.data(forKey: "imora.localServer")
            .flatMap { try? JSONDecoder().decode(LocalServerConfig.self, from: $0) }
        return try bases.withLock { route in
            let isExternal = ServerTrustPolicy(apiURL: external).contains(url)
            guard let route, route.external == external else {
                guard isExternal else { throw ServerTrustError.untrustedTarget }
                return nil
            }
            guard route.isReady else { throw ServerTrustError.untrustedTarget }
            if ServerTrustPolicy(apiURL: route.local).contains(url) {
                guard let config, config.server == external, config.isUsable,
                      config.apiURL == route.local, config.verifiedIdentity == route.identity
                else { throw ServerTrustError.untrustedTarget }
                return route.identity
            }
            guard route.allowsFallback, isExternal else { throw ServerTrustError.untrustedTarget }
            return nil
        }
    }

    /// drops the local address when a request through it found nobody there,
    /// and says whether the request is worth sending again to the external
    /// one. a timeout may have reached the server, so only reads retry then.
    static func fallBack(from sent: URL?, after error: any Error, method: String = "GET") -> Bool {
        guard let error = error as? URLError, let sent
        else { return false }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            break
        case .timedOut, .networkConnectionLost:
            guard method == "GET" else { return false }
        default:
            return false
        }
        let didFallBack = bases.withLock { current in
            guard let route = current, route.isReady, route.allowsFallback,
                  ServerTrustPolicy(apiURL: route.local).contains(sent)
            else { return false }
            current = nil
            return true
        }
        guard didFallBack else { return false }
        Task { @MainActor in LocalServerRouter.shared.localUnreachable() }
        return true
    }

    /// A saved root may carry credentials only while that exact account and
    /// local root are selected. Captured local URLs lose access on a reset.
    static func configuredLocal(for external: URL, defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: "imora.localServer"),
              let config = try? JSONDecoder().decode(LocalServerConfig.self, from: data),
              config.server == external, config.isUsable,
              let local = config.apiURL, ServerTrustPolicy.validServerURL(local)
        else { return nil }
        return bases.withLock { route in
            guard route?.isReady == true, route?.external == external, route?.local == local,
                  route?.identity == config.verifiedIdentity
            else { return nil }
            return local
        }
    }

    static func configuredIdentity(for external: URL, defaults: UserDefaults = .standard) -> LocalServerIdentity? {
        guard let data = defaults.data(forKey: "imora.localServer"),
              let config = try? JSONDecoder().decode(LocalServerConfig.self, from: data),
              config.server == external, config.isUsable, let identity = config.verifiedIdentity
        else { return nil }
        return bases.withLock { route in
            guard route?.isReady == true, route?.external == external,
                  route?.local == identity.apiURL, route?.identity == identity
            else { return nil }
            return identity
        }
    }

}

/// The external API root stays the account identity. Automatic selection uses
/// a saved Wi-Fi name; manual selection requires confirmation on this network.
/// A ping proves reachability only, never the server's identity.
@Observable
final class LocalServerRouter {
    enum ConnectionMode: CaseIterable, Identifiable {
        case automatic, external, local
        var id: Self { self }
    }

    enum Status: Equatable {
        case off
        case external
        case checking
        case local
        case held
    }

    enum HoldReason: Equatable {
        case wifiRequired
        case confirmationRequired
        case checking
        case unreachable
    }

    enum ManualSelectionResult: Equatable {
        case selected
        case unavailable
        case unreachable
        case superseded
    }

    private enum ManualOverride {
        case local
        case external
    }

    static let shared = LocalServerRouter(provisioningData: LocalServerIdentityProvisioning.bundledData())

    private(set) var config: LocalServerConfig?
    private(set) var status: Status = .off
    private(set) var holdReason: HoldReason?
    private(set) var isCheckingManualLocal = false
    private(set) var selectionRevision: UInt64 = 0
    private var manualOverride: ManualOverride?
    private var network: String?

    @ObservationIgnored private var external: URL?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var locationAccess: LocationAccess?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let monitoringEnabled: Bool
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let probe: @Sendable (URLRequest) async -> Bool
    @ObservationIgnored private let ssidProvider: @Sendable () async -> String?
    @ObservationIgnored private let identityProbe: @Sendable (URLRequest, LocalServerIdentity) async -> Bool
    @ObservationIgnored private let provisioning: LocalServerIdentityProvisioning?

    private static let defaultsKey = "imora.localServer"

    init(
        defaults: UserDefaults = .standard,
        monitoringEnabled: Bool = true,
        notificationCenter: NotificationCenter = .default,
        probe: (@Sendable (URLRequest) async -> Bool)? = nil,
        ssidProvider: (@Sendable () async -> String?)? = nil,
        identityProbe: (@Sendable (URLRequest, LocalServerIdentity) async -> Bool)? = nil,
        provisioningData: Data? = nil
    ) {
        self.defaults = defaults
        self.monitoringEnabled = monitoringEnabled
        self.notificationCenter = notificationCenter
        self.probe = probe ?? Self.answers
        self.ssidProvider = ssidProvider ?? Self.currentSSID
        self.identityProbe = identityProbe ?? Self.answersWithIdentity
        provisioning = LocalServerIdentityProvisioning.decode(provisioningData)
    }

    var connectionMode: ConnectionMode {
        switch manualOverride {
        case .local: .local
        case .external: .external
        case nil: config?.isEnabled == false ? .external : .automatic
        }
    }

    func useAutomatic() {
        if var config {
            config.isEnabled = true
            config.automaticallyUseVerifiedLocal = config.verifiedIdentity != nil
            update(config)
        }
        invalidateSelection()
        evaluate(resetting: true)
    }

    var isManualLocal: Bool { manualOverride == .local }

    var activeEndpoint: URL? {
        guard let external else { return nil }
        return status == .local || status == .held ? ServerRoute.resolve(external) : external
    }

    var isLocalIdentityVerified: Bool { status == .local && config?.verifiedIdentity != nil }

    var canSelectManualLocal: Bool {
        guard let external, let config, config.server == external,
              config.isUsable, network != nil
        else { return false }
        return true
    }

    func activate(external: URL) {
        invalidateSelection()
        self.external = external
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(LocalServerConfig.self, from: $0) }
        config = stored?.server == external ? stored : nil
        if let provisioning {
            config = provisioning.applying(to: config, activeExternal: external, defaults: defaults)
        }
        startMonitoring()
        evaluate(resetting: true)
    }

    /// sign out forgets the local address along with the rest of the account.
    func deactivate() {
        invalidateSelection()
        external = nil
        config = nil
        defaults.removeObject(forKey: Self.defaultsKey)
        ServerRoute.use(local: nil, external: nil)
        status = .off
    }

    func update(_ proposed: LocalServerConfig) {
        guard let external, proposed.server == external else { return }
        var config = proposed
        if let identity = config.identity, identity.apiURL != config.apiURL {
            config.identity = nil
            config.automaticallyUseVerifiedLocal = false
        }
        if let provisioning {
            config = provisioning.applying(to: config, activeExternal: external, defaults: defaults, explicitSetup: true) ?? config
        }
        guard config != self.config else { return }
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        invalidateSelection()
        evaluate(resetting: true)
    }

    /// Called only after the user confirms this saved URL. No account request
    /// is sent until an unauthenticated, redirect-blocking ping answers.
    func requestManualLocal(confirmedURL: URL, revision: UInt64? = nil) async -> ManualSelectionResult {
        guard !Task.isCancelled, revision == nil || revision == selectionRevision else { return .superseded }
        guard canSelectManualLocal, let external, let config,
              let local = config.apiURL, local == confirmedURL
        else { return .unavailable }

        check?.cancel()
        check = nil
        selectionRevision &+= 1
        let revision = selectionRevision
        let network = network
        isCheckingManualLocal = true
        // A cancelled automatic check must not leave a permanent Checking row.
        if status == .checking { status = ServerRoute.isLocal ? .local : .external }
        var request = URLRequest(url: local.appending(path: "server/ping"))
        request.timeoutInterval = 3
        let identity = config.verifiedIdentity
        let reachable: Bool
        if let identity { reachable = await identityProbe(request, identity) }
        else { reachable = await probe(request) }
        guard !Task.isCancelled, revision == selectionRevision,
              self.external == external, self.config == config, self.network == network
        else {
            if revision == selectionRevision { isCheckingManualLocal = false }
            return .superseded
        }
        isCheckingManualLocal = false
        guard reachable else { return .unreachable }
        manualOverride = .local
        holdReason = nil
        ServerRoute.use(local: local, external: external, allowsFallback: false, identity: identity)
        status = .local
        return .selected
    }

    func useExternal() {
        invalidateSelection()
        manualOverride = .external
        ServerRoute.use(local: nil, external: nil)
        status = .external
    }

    func cancelManualSelection() {
        guard isCheckingManualLocal else { return }
        selectionRevision &+= 1
        isCheckingManualLocal = false
    }

    func localUnreachable() {
        guard !ServerRoute.isLocal, status == .local else { return }
        status = .external
    }

    var isLocationDenied: Bool { locationAccess?.isDenied ?? false }

    /// the wi-fi name needs precise location access, asked for here the
    /// first time since this is the only place that reads it on demand.
    func currentNetworkName() async -> String? {
        if locationAccess == nil { locationAccess = LocationAccess() }
        guard let locationAccess else { return nil }
        await locationAccess.requestIfNeeded()
        let name = await ssidProvider()
        if name != nil { evaluate(resetting: false) }
        return name
    }

    private func startMonitoring() {
        if foregroundObserver == nil {
            // Inactive excursions do not change intent. A real return keeps
            // pinned local mode and holds an unverified route for confirmation.
            foregroundObserver = notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationReturnedToForeground() }
            }
        }
        guard monitoringEnabled, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network = Self.networkSignature(
                gateways: path.gateways.map { "\($0)" },
                connectedToWiFi: path.status == .satisfied && path.usesInterfaceType(.wifi)
            )
            MainActor.assumeIsolated { self?.networkChanged(network: network) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    nonisolated static func networkSignature(gateways: [String], connectedToWiFi: Bool) -> String? {
        connectedToWiFi ? gateways.sorted().joined(separator: ",") : nil
    }

    /// A gateway signature cannot authenticate a network. Only a pinned route
    /// can ignore duplicate callbacks; unverified manual intent stays selected
    /// but requires confirmation before any new account request can proceed.
    func networkChanged(network: String?) {
        guard network != self.network || config?.verifiedIdentity == nil else { return }
        self.network = network
        if manualOverride == .local {
            holdManualIntent()
            return
        }
        invalidateSelection()
        evaluate(resetting: true)
    }

    func applicationReturnedToForeground() {
        if manualOverride == .local {
            if config?.verifiedIdentity != nil, network != nil, status == .local { return }
            if holdReason != .checking { holdManualIntent() }
            return
        }
        if manualOverride == .external { return }
        invalidateSelection()
        evaluate(resetting: true)
    }

    private func invalidateSelection() {
        cancelChecks()
        manualOverride = nil
        holdReason = nil
    }

    private func cancelChecks() {
        selectionRevision &+= 1
        check?.cancel()
        check = nil
        isCheckingManualLocal = false
    }

    private func holdManualIntent() {
        cancelChecks()
        guard let external, let config, let local = config.apiURL else { return }
        let identity = config.verifiedIdentity
        ServerRoute.holdManual(local: local, external: external, identity: identity)
        status = .held
        guard network != nil else {
            holdReason = .wifiRequired
            return
        }
        guard let identity else {
            holdReason = .confirmationRequired
            return
        }
        holdReason = .checking
        let revision = selectionRevision
        let network = network
        check = Task {
            var request = URLRequest(url: local.appending(path: "server/ping"))
            request.timeoutInterval = 3
            let reachable = await identityProbe(request, identity)
            guard !Task.isCancelled, revision == selectionRevision, manualOverride == .local,
                  self.external == external, self.config == config, self.network == network
            else { return }
            if reachable {
                ServerRoute.use(local: local, external: external, allowsFallback: false, identity: identity)
                holdReason = nil
                status = .local
            } else {
                holdReason = .unreachable
            }
        }
    }

    private func evaluate(resetting: Bool) {
        guard manualOverride == nil, !isCheckingManualLocal else { return }
        check?.cancel()
        guard let external, let config, config.server == external,
              config.isUsable, let local = config.apiURL else {
            ServerRoute.use(local: nil, external: nil)
            status = config?.isEnabled == true ? .external : .off
            return
        }
        let identity = config.verifiedIdentity
        let verifiesAutomatically = config.automaticallyUseVerifiedLocal && identity != nil
        guard network != nil, verifiesAutomatically || !config.networks.isEmpty else {
            ServerRoute.use(local: nil, external: nil)
            status = .external
            return
        }
        if resetting {
            ServerRoute.use(local: nil, external: nil)
            status = .checking
        }
        selectionRevision &+= 1
        let revision = selectionRevision
        let network = network
        check = Task {
            if !verifiesAutomatically {
                let ssid = await ssidProvider()
                guard !Task.isCancelled, revision == selectionRevision,
                      self.external == external, self.config == config, self.network == network
                else { return }
                guard let ssid, config.networks.contains(ssid) else {
                    ServerRoute.use(local: nil, external: nil)
                    status = .external
                    return
                }
            }
            var request = URLRequest(url: local.appending(path: "server/ping"))
            request.timeoutInterval = 3
            let answers: Bool
            if let identity { answers = await identityProbe(request, identity) }
            else { answers = await probe(request) }
            guard !Task.isCancelled, revision == selectionRevision,
                  self.external == external, self.config == config, self.network == network
            else { return }
            ServerRoute.use(local: answers ? local : nil, external: external, identity: identity)
            status = answers ? .local : .external
        }
    }

    private nonisolated static func currentSSID() async -> String? {
        await NEHotspotNetwork.fetchCurrent()?.ssid
    }

    @concurrent
    private nonisolated static func answers(_ request: URLRequest) async -> Bool {
        guard let (_, response) = try? await ControlledSession.noRedirect.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @concurrent
    private nonisolated static func answersWithIdentity(_ request: URLRequest, identity: LocalServerIdentity) async -> Bool {
        let session = ControlledSession.make(identity: identity)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// asks for location access and waits for the answer, which is what the
/// wi-fi name is gated behind.
private final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var isDenied: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: true
        case .notDetermined: false
        default: manager.accuracyAuthorization == .reducedAccuracy
        }
    }

    func requestIfNeeded() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // called on the main queue by core location.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        MainActor.assumeIsolated {
            let waiters = self.waiters
            self.waiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
}
