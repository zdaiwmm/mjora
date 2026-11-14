import Foundation
import Synchronization

/// Background URLSession cannot veto redirects on iOS. Old daemon-owned
/// sessions are attached only to cancel, never to rehome/replay a request.
nonisolated final class LegacyTransferCanceller: NSObject, URLSessionDelegate, Sendable {
    static let shared = LegacyTransferCanceller()
    struct Completion: @unchecked Sendable { let run: () -> Void }
    private struct State {
        var sessions: [String: URLSession] = [:]
        var completions: [String: [Completion]] = [:]
        var finished: Set<String> = []
    }
    private let state = Mutex(State())

    func cancel(identifier: String, appGroup: String? = nil, completion: Completion? = nil) {
        let alreadyFinished = state.withLock { value in
            if value.finished.contains(identifier) { return true }
            if let completion { value.completions[identifier, default: []].append(completion) }
            return false
        }
        if alreadyFinished { if let completion { DispatchQueue.main.async { completion.run() } }; return }
        let session: URLSession? = state.withLock { value in
            guard value.sessions[identifier] == nil else { return nil }
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sharedContainerIdentifier = appGroup
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            value.sessions[identifier] = session
            return session
        }
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        guard let identifier = session.configuration.identifier else { return }
        let completions = state.withLock { value in
            value.sessions[identifier] = nil
            value.finished.insert(identifier)
            return value.completions.removeValue(forKey: identifier) ?? []
        }
        for completion in completions { DispatchQueue.main.async { completion.run() } }
    }
}
