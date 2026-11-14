import Observation

/// shared by SwiftUI screens and the timeline's UIKit-hosted tile roots.
@Observable @MainActor
final class ImageLoadRecovery {
    static let shared = ImageLoadRecovery()

    private(set) var generation = 0
    private var wasConnected: Bool?
    private var networkWatcher: NetworkPathWatcher?

    private init() {
        networkWatcher = NetworkPathWatcher { [weak self] path in
            guard let self else { return }
            if path.connected && self.wasConnected == false { self.generation &+= 1 }
            self.wasConnected = path.connected
        }
    }

    func becameActive() {
        generation &+= 1
        networkWatcher?.refresh()
    }

    func protectedDataBecameAvailable() {
        generation &+= 1
    }
}
