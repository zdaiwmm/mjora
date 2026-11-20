import CryptoKit
import Foundation
import Synchronization

nonisolated enum OriginalReadbackError: Error, LocalizedError {
    case unexpectedResponse
    case contentMismatch

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse: String(localized: "The server did not return a complete original file. No device copies were removed.")
        case .contentMismatch: String(localized: "The server original's checksum or size does not match the device resource. No device copies were removed.")
        }
    }
}

nonisolated enum OriginalReadbackVerifier {
    static func verify(request: URLRequest, expected: ResourceDigest, context: AccountRequestContext, session: URLSession = ControlledSession.noRedirect) async throws -> ResourceDigest {
        guard expected.byteCount > 0, context.isActive else { throw OriginalReadbackError.contentMismatch }
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (results, completion) = AsyncThrowingStream<ResourceDigest, Error>.makeStream()
        let task = session.dataTask(with: request)
        // Hash and discard each delivered chunk because AsyncBytes can stall on large TLS responses.
        task.delegate = OriginalReadbackTransfer(url: request.url, expected: expected, context: context, completion: completion)
        defer { task.cancel() }
        try Task.checkCancellation()
        try context.startWhileActive(for: request) { task.resume() }
        var iterator = results.makeAsyncIterator()
        guard let digest = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        return digest
    }
}

private nonisolated final class OriginalReadbackTransfer: NSObject, URLSessionDataDelegate, Sendable {
    private let url: URL?
    private let expected: ResourceDigest
    private let context: AccountRequestContext
    private let completion: AsyncThrowingStream<ResourceDigest, Error>.Continuation
    private let digest = Mutex((hasher: Insecure.SHA1(), count: Int64(0)))

    init(url: URL?, expected: ResourceDigest, context: AccountRequestContext,
         completion: AsyncThrowingStream<ResourceDigest, Error>.Continuation) {
        self.url = url
        self.expected = expected
        self.context = context
        self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @Sendable @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void) {
        guard context.isActive else {
            completion.finish(throwing: ServerTrustError.sessionExpired)
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == url,
              http.value(forHTTPHeaderField: "Content-Range") == nil,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              response.mimeType.map({ $0.hasPrefix("image/") || $0.hasPrefix("video/") || $0 == "application/octet-stream" }) == true,
              response.expectedContentLength < 0 || response.expectedContentLength == expected.byteCount
        else {
            completion.finish(throwing: OriginalReadbackError.unexpectedResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard context.isActive else {
            completion.finish(throwing: ServerTrustError.sessionExpired)
            dataTask.cancel()
            return
        }
        let fits = digest.withLock { state in
            let count = Int64(data.count)
            guard count <= expected.byteCount - state.count else { return false }
            state.hasher.update(data: data)
            state.count += count
            return true
        }
        if !fits {
            completion.finish(throwing: OriginalReadbackError.contentMismatch)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            completion.finish(throwing: error)
            return
        }
        let actual = digest.withLock { state in
            ResourceDigest(checksum: Data(state.hasher.finalize()).base64EncodedString(), byteCount: state.count)
        }
        guard actual == expected else {
            completion.finish(throwing: OriginalReadbackError.contentMismatch)
            return
        }
        completion.yield(actual)
        completion.finish()
    }
}
