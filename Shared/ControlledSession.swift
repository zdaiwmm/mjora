import Foundation
import Synchronization

/// A nil policy rejects every redirect (discovery, mutations and WebSockets).
/// Read-only API sessions may follow up to five redirects within their API root.
nonisolated final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: ServerTrustPolicy?
    private let policyForRequest: (@Sendable (URLRequest) -> ServerTrustPolicy?)?
    private let identity: LocalServerIdentity?
    private let counts = Mutex<[Int: Int]>([:])

    init(policy: ServerTrustPolicy? = nil, identity: LocalServerIdentity? = nil,
         policyForRequest: (@Sendable (URLRequest) -> ServerTrustPolicy?)? = nil) {
        self.policy = policy
        self.identity = identity
        self.policyForRequest = policyForRequest
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @Sendable @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        LocalServerIdentity.answer(challenge, requestURL: task.currentRequest?.url, identity: identity, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @Sendable @escaping (URLRequest?) -> Void) {
        let count = counts.withLock { counts in
            let count = counts[task.taskIdentifier, default: 0]
            counts[task.taskIdentifier] = count + 1
            return count
        }
        guard let original = task.originalRequest,
              let policy = policyForRequest?(original) ?? policy,
              RedirectPolicy(policy: policy).permits(original: original, response: response, proposed: request, redirects: count)
        else { completionHandler(nil); return }
        var next = request
        next.setValue(original.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        counts.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
    }
}

nonisolated enum ControlledSession {
    static let noRedirect = make()

    static func make(apiURL: URL? = nil, identity: LocalServerIdentity? = nil,
                     configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: SafeRedirectDelegate(policy: apiURL.map { ServerTrustPolicy(apiURL: $0) }, identity: identity), delegateQueue: nil)
    }
}
