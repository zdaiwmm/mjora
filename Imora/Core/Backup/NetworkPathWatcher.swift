import Foundation
import Network
import os

/// interface and cost are separate facts: cellular and Personal Hotspot may
/// both be expensive, while ordinary Wi-Fi usually is not.
nonisolated struct NetworkPathSnapshot: Sendable {
    let connected: Bool
    let expensive: Bool
    let wifi: Bool
    let cellular: Bool
    let constrained: Bool
    let observedAt: Date

    func sameConditions(as other: Self) -> Bool {
        connected == other.connected && expensive == other.expensive
            && wifi == other.wifi && cellular == other.cellular
            && constrained == other.constrained
    }
}

/// reads the latest path on the main actor. a callback queued before the app
/// resumed cannot overwrite a newer foreground observation.
final class NetworkPathWatcher {
    private let log = Logger(subsystem: "app.imora", category: "network-path")
    private let monitor = NWPathMonitor()
    private let onChange: (NetworkPathSnapshot) -> Void
    private(set) var snapshot: NetworkPathSnapshot?

    init(onChange: @escaping (NetworkPathSnapshot) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.readCurrentPath() }
        }
        monitor.start(queue: DispatchQueue(label: "app.imora.networkpath"))
    }

    func stop() {
        monitor.cancel()
    }

    /// before the first monitor callback, currentPath is only a placeholder.
    func refresh() {
        guard snapshot != nil else { return }
        readCurrentPath()
    }

    private func readCurrentPath() {
        let path = monitor.currentPath
        let connected = path.status == .satisfied
        let next = NetworkPathSnapshot(
            connected: connected,
            expensive: connected && path.isExpensive,
            wifi: connected && path.usesInterfaceType(.wifi),
            cellular: connected && path.usesInterfaceType(.cellular),
            constrained: connected && path.isConstrained,
            observedAt: Date()
        )
        let changed = snapshot.map { !next.sameConditions(as: $0) } ?? true
        snapshot = next
        if changed {
            log.info("path connected=\(next.connected) expensive=\(next.expensive) wifi=\(next.wifi) cellular=\(next.cellular) constrained=\(next.constrained)")
            onChange(next)
        }
    }
}
