import Foundation
import Synchronization

/// App.init precedes UIKit's protected-data launch state. The real lifecycle
/// event is remembered, without holding gallery exposure or user input.
nonisolated final class LaunchProtectionGate: Sendable {
    private struct State {
        var available: Bool?
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    private let state = Mutex(State())
    var isAvailable: Bool { state.withLock { $0.available == true } }

    func resolve(_ available: Bool) {
        let pending = state.withLock { state in
            state.available = available
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: available) }
    }

    func value() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = state.withLock { state in
                    if Task.isCancelled { return false }
                    if let available = state.available { return available }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: false)
        }
    }
}
