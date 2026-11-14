import Foundation

/// Uses the existing account authorization, route validation, TLS pinning and redirect policy.
nonisolated struct ImoraClientRemoteSyncTransport: RemoteSyncTransport {
    let client: ImoraClient
    func stream(types: [String], reset: Bool) async throws -> AsyncThrowingStream<Data, Error> {
        var request = try client.authorizedRequest(url: client.apiURL.appending(path: "sync/stream"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["types": types, "reset": reset])
        let (bytes, response) = try await client.transportSession(for: request).bytes(for: request)
        try Self.validate(response)
        let reader = SyncHTTPByteReader(bytes: bytes, client: client)
        // Pull-driven stream: no unbounded producer queue, at most 16 KiB per network chunk.
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    func acknowledge(_ acks: [String]) async throws {
        guard !acks.isEmpty, acks.count <= 1000 else { throw RemoteSyncError.invalidRecord }
        var request = try client.authorizedRequest(url: client.apiURL.appending(path: "sync/ack"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acks": acks])
        let (_, response) = try await client.transportSession(for: request).data(for: request)
        try Self.validate(response)
        guard client.context.isActive else { throw RemoteSyncError.unsafeHistory }
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteSyncError.invalidRecord }
        if [404, 405, 501].contains(http.statusCode) { throw RemoteSyncError.compatibilityRequired }
        guard (200..<300).contains(http.statusCode) else { throw ImoraError.http(http.statusCode, "Sync request failed") }
    }
}

/// AsyncThrowingStream's single pull consumer owns this iterator. It is never shared with a producer task.
private nonisolated final class SyncHTTPByteReader: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.AsyncIterator
    private let client: ImoraClient
    init(bytes: URLSession.AsyncBytes, client: ImoraClient) { iterator = bytes.makeAsyncIterator(); self.client = client }
    func next() async throws -> Data? {
        var chunk = Data()
        while chunk.count < 16 * 1024 {
            try Task.checkCancellation()
            guard client.context.isActive else { throw RemoteSyncError.unsafeHistory }
            guard let byte = try await iterator.next() else { return chunk.isEmpty ? nil : chunk }
            chunk.append(byte)
            // Deliver a complete line immediately; do not await the rest of a sparse long-lived stream.
            if byte == 10 { break }
        }
        return chunk
    }
}
