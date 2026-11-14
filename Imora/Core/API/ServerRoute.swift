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

    var isUsable: Bool { isEnabled && apiURL.map(ServerTrustPolicy.validServerURL) == true }

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
    }

    private static let bases = Mutex<Bases?>(nil)

    static var isLocal: Bool { bases.withLock { $0 != nil } }

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

    static func use(local: URL?, external: URL?, allowsFallback: Bool = true) {
        guard let local, let external else {
            bases.withLock { $0 = nil }
            return
        }
        guard ServerTrustPolicy.validServerURL(local), ServerTrustPolicy.validServerURL(external) else { return }
        bases.withLock { $0 = Bases(external: external, local: local, allowsFallback: allowsFallback) }
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
            guard let route = current, route.allowsFallback,
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
            guard route?.external == external, route?.local == local else { return nil }
            return local
        }
    }

}

/// The external API root stays the account identity. Automatic selection uses
/// a saved Wi-Fi name; manual selection requires confirmation on this network.
/// A ping proves reachability only, never the server's identity.
@Observable
final class LocalServerRouter {
    enum Status: Equatable {
        case off
        case external
        case checking
        case local
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

    static let shared = LocalServerRouter()

    private(set) var config: LocalServerConfig?
    private(set) var status: Status = .off
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

    private static let defaultsKey = "imora.localServer"

    init(
        defaults: UserDefaults = .standard,
        monitoringEnabled: Bool = true,
        notificationCenter: NotificationCenter = .default,
        probe: (@Sendable (URLRequest) async -> Bool)? = nil,
        ssidProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.defaults = defaults
        self.monitoringEnabled = monitoringEnabled
        self.notificationCenter = notificationCenter
        self.probe = probe ?? Self.answers
        self.ssidProvider = ssidProvider ?? Self.currentSSID
    }

    var isManualLocal: Bool { manualOverride == .local }

    var activeEndpoint: URL? {
        guard let external else { return nil }
        return status == .local ? ServerRoute.resolve(external) : external
    }

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

    func update(_ config: LocalServerConfig) {
        guard config.server == external, config != self.config else { return }
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
        guard revision == nil || revision == selectionRevision else { return .superseded }
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
        let reachable = await probe(request)
        guard !Task.isCancelled, revision == selectionRevision,
              self.external == external, self.config == config, self.network == network
        else {
            if revision == selectionRevision { isCheckingManualLocal = false }
            return .superseded
        }
        isCheckingManualLocal = false
        guard reachable else { return .unreachable }
        manualOverride = .local
        ServerRoute.use(local: local, external: external, allowsFallback: false)
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
            // Permission dialogs and Control Center only make the app inactive.
            // A real background return invalidates this network's manual consent.
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
            let network = path.status == .satisfied && path.usesInterfaceType(.wifi)
                ? path.gateways.map { "\($0)" }.joined(separator: ",")
                : nil
            MainActor.assumeIsolated { self?.networkChanged(network: network) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    /// Every path update invalidates manual consent, including updates whose
    /// gateway string is unchanged. That string cannot establish identity.
    func networkChanged(network: String?) {
        self.network = network
        invalidateSelection()
        evaluate(resetting: true)
    }

    func applicationReturnedToForeground() {
        invalidateSelection()
        evaluate(resetting: true)
    }

    private func invalidateSelection() {
        selectionRevision &+= 1
        check?.cancel()
        check = nil
        isCheckingManualLocal = false
        manualOverride = nil
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
        guard network != nil, !config.networks.isEmpty else {
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
            let ssid = await ssidProvider()
            guard !Task.isCancelled, revision == selectionRevision,
                  self.external == external, self.config == config, self.network == network
            else { return }
            guard let ssid, config.networks.contains(ssid) else {
                ServerRoute.use(local: nil, external: nil)
                status = .external
                return
            }
            var request = URLRequest(url: local.appending(path: "server/ping"))
            request.timeoutInterval = 3
            let answers = await probe(request)
            guard !Task.isCancelled, revision == selectionRevision,
                  self.external == external, self.config == config, self.network == network
            else { return }
            ServerRoute.use(local: answers ? local : nil, external: external)
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
