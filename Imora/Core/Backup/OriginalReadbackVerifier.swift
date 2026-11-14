import CryptoKit
import Foundation

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
    /// No original bytes are accumulated in memory or written to disk. A small
    /// buffer amortizes SHA1 updates, including for large Live Photo videos.
    static func verify(request: URLRequest, expected: ResourceDigest, context: AccountRequestContext) async throws -> ResourceDigest {
        guard expected.byteCount > 0, context.isActive else { throw OriginalReadbackError.contentMismatch }
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await ControlledSession.noRedirect.bytes(for: request)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == request.url,
              http.value(forHTTPHeaderField: "Content-Range") == nil,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              response.mimeType.map({ $0.hasPrefix("image/") || $0.hasPrefix("video/") || $0 == "application/octet-stream" }) == true,
              response.expectedContentLength < 0 || response.expectedContentLength == expected.byteCount
        else { throw OriginalReadbackError.unexpectedResponse }
        var hasher = Insecure.SHA1()
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var count: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            count += 1
            guard count <= expected.byteCount else { throw OriginalReadbackError.contentMismatch }
            if buffer.count == 64 * 1024 {
                try Task.checkCancellation()
                guard context.isActive else { throw ServerTrustError.sessionExpired }
                hasher.update(data: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        hasher.update(data: buffer)
        try Task.checkCancellation()
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        let digest = ResourceDigest(checksum: Data(hasher.finalize()).base64EncodedString(), byteCount: count)
        guard digest == expected else { throw OriginalReadbackError.contentMismatch }
        return digest
    }
}
