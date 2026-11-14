import Foundation

nonisolated enum ControlledUploadError: Error, LocalizedError {
    case http(Int)
    case unconfirmed
    var errorDescription: String? {
        switch self {
        case .http(let code): String(localized: "The server rejected the upload (HTTP \(code)).")
        case .unconfirmed: String(localized: "The server did not confirm the uploaded file.")
        }
    }
}

/// Default sessions keep redirect decisions in our process. Durable recovery
/// belongs to protected queue records, never an unguarded background session.
nonisolated final class ControlledFileUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let context: AccountRequestContext
    var apiURL: URL { context.apiURL }
    private let lock = NSLock()
    private var session: URLSession!
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), any Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var authorizations: [Int: @Sendable () throws -> Void] = [:]

    init(apiURL: URL, token: String) {
        context = AccountRequestContext(apiURL: apiURL, token: token)
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() { context.invalidate(); session.invalidateAndCancel() }

    func upload(_ input: URLRequest, fromFile file: URL,
                startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void = { try $0() }) async throws -> (Data, HTTPURLResponse) {
        let request = try context.authorize(input)
        try ProtectedTemporaryFiles.protect(file)
        let task = session.uploadTask(with: request, fromFile: file)
        return try await perform(task, startAuthorized: startAuthorized)
    }

    func data(_ input: URLRequest,
              startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: try context.authorize(input))
        return try await perform(task, startAuthorized: startAuthorized)
    }

    private func perform(_ task: URLSessionTask,
                         startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[id] = continuation; buffers[id] = Data(); authorizations[id] = { try startAuthorized({}) } }
                do {
                    try Task.checkCancellation()
                    try context.startWhileActive { try startAuthorized { task.resume() } }
                } catch {
                    task.cancel()
                    let waiting = lock.withLock { buffers[id] = nil; authorizations[id] = nil; return pending.removeValue(forKey: id) }
                    waiting?.resume(throwing: error)
                }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @Sendable @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard let current = buffers[dataTask.taskIdentifier] else { return false }
            guard current.count + data.count <= 1 << 20 else { return true }
            buffers[dataTask.taskIdentifier]?.append(data)
            return false
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let authorize = lock.withLock { authorizations[task.taskIdentifier] }
        do { try authorize?() } catch { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let value = lock.withLock {
            (pending.removeValue(forKey: task.taskIdentifier), buffers.removeValue(forKey: task.taskIdentifier) ?? Data(), authorizations.removeValue(forKey: task.taskIdentifier))
        }
        guard let continuation = value.0 else { return }
        if let error { continuation.resume(throwing: error); return }
        do {
            guard context.isActive else { throw ServerTrustError.sessionExpired }
            try value.2?()
            guard let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ControlledUploadError.http((task.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            continuation.resume(returning: (value.1, response))
        } catch { continuation.resume(throwing: error) }
    }
}
