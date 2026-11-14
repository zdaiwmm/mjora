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

    var isUsable: Bool { isEnabled && apiURL != nil && !networks.isEmpty }

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

    static func use(local: URL?, external: URL?) {
        guard let local, let external else {
            bases.withLock { $0 = nil }
            return
        }
        guard ServerTrustPolicy.validServerURL(local), ServerTrustPolicy.validServerURL(external) else { return }
        bases.withLock { $0 = Bases(external: external, local: local) }
    }

    /// drops the local address when a request through it found nobody there,
    /// and says whether the request is worth sending again to the external
    /// one. a timeout may have reached the server, so only reads retry then.
    static func fallBack(from sent: URL?, after error: any Error, method: String = "GET") -> Bool {
        guard let error = error as? URLError,
              let sent,
              let local = bases.withLock({ $0?.local }),
              ServerTrustPolicy(apiURL: local).contains(sent)
        else { return false }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            break
        case .timedOut, .networkConnectionLost:
            guard method == "GET" else { return false }
        default:
            return false
        }
        bases.withLock { $0 = nil }
        Task { @MainActor in LocalServerRouter.shared.localUnreachable() }
        return true
    }

    /// An explicit saved configuration, never an address learned from a redirect.
    static func configuredLocal(for external: URL) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "imora.localServer"),
              let config = try? JSONDecoder().decode(LocalServerConfig.self, from: data),
              config.server == external, config.isUsable,
              let local = config.apiURL, ServerTrustPolicy.validServerURL(local)
        else { return nil }
        return local
    }

}

/// decides between the local and the external address. the local one is only
/// used on a listed wi-fi network and once it answered there: an http address
/// on somebody else's network could be anyone, and requests carry the token.
@Observable
final class LocalServerRouter {
    enum Status: Equatable {
        case off
        case external
        case checking
        case local
    }

    static let shared = LocalServerRouter()

    private(set) var config: LocalServerConfig?
    private(set) var status: Status = .off

    @ObservationIgnored private var external: URL?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    /// the wi-fi gateways, nil off wi-fi. a new value means another network,
    /// which is when the local address has to prove itself again.
    @ObservationIgnored private var network: String?
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private let locationAccess = LocationAccess()

    private static let defaultsKey = "imora.localServer"
    private nonisolated static let probe = ControlledSession.noRedirect

    func activate(external: URL) {
        self.external = external
        let stored = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(LocalServerConfig.self, from: $0) }
        config = stored?.server == external ? stored : nil
        startMonitoring()
        evaluate(resetting: true)
    }

    /// sign out forgets the local address along with the rest of the account.
    func deactivate() {
        check?.cancel()
        external = nil
        config = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        ServerRoute.use(local: nil, external: nil)
        status = .off
    }

    func update(_ config: LocalServerConfig) {
        guard config.server == external, config != self.config else { return }
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        evaluate(resetting: true)
    }

    func localUnreachable() {
        guard !ServerRoute.isLocal, status == .local else { return }
        status = .external
    }

    var isLocationDenied: Bool { locationAccess.isDenied }

    /// the wi-fi name needs precise location access, asked for here the
    /// first time since this is the only place that reads it on demand.
    func currentNetworkName() async -> String? {
        await locationAccess.requestIfNeeded()
        let name = await Self.currentSSID()
        if name != nil { evaluate(resetting: false) }
        return name
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network = path.status == .satisfied && path.usesInterfaceType(.wifi)
                ? path.gateways.map { "\($0)" }.joined(separator: ",")
                : nil
            MainActor.assumeIsolated { self?.pathChanged(network: network) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        // the name reads nil in the background, so a check that ran there
        // gets another chance once the app is in front again.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(resetting: false) }
        }
    }

    private func pathChanged(network: String?) {
        guard network != self.network else { return }
        self.network = network
        evaluate(resetting: true)
    }

    private func evaluate(resetting: Bool) {
        check?.cancel()
        guard let external, let config, config.isUsable, let local = config.apiURL else {
            ServerRoute.use(local: nil, external: nil)
            status = config?.isEnabled == true ? .external : .off
            return
        }
        guard network != nil else {
            ServerRoute.use(local: nil, external: nil)
            status = .external
            return
        }
        if resetting {
            ServerRoute.use(local: nil, external: nil)
            status = .checking
        }
        check = Task {
            let ssid = await Self.currentSSID()
            guard !Task.isCancelled else { return }
            guard let ssid, config.networks.contains(ssid) else {
                ServerRoute.use(local: nil, external: nil)
                status = .external
                return
            }
            let answers = await Self.answers(local)
            guard !Task.isCancelled else { return }
            ServerRoute.use(local: answers ? local : nil, external: external)
            status = answers ? .local : .external
        }
    }

    private nonisolated static func currentSSID() async -> String? {
        await NEHotspotNetwork.fetchCurrent()?.ssid
    }

    @concurrent
    private nonisolated static func answers(_ apiURL: URL) async -> Bool {
        var request = URLRequest(url: apiURL.appending(path: "server/ping"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await probe.data(for: request) else { return false }
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
