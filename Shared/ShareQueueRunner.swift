import Foundation

nonisolated struct ShareQueueResult: Sendable {
    var uploaded = 0
    var failed = 0
    var pending = 0
    var cancelled = false
}

nonisolated enum ShareQueueRunner {
    private struct Owner: Decodable { let id: String }
    private struct Upload: Decodable { let id: String }
    private struct Remote: Decodable {
        let id: String
        let ownerId: String
        let type: String
        let checksum: String?
        let isTrashed: Bool?
        let isOffline: Bool?
    }

    private static func verifyAsset(assetID: String, checksum: String, mediaType: String, ownerID: String,
                                    uploader: ControlledFileUploader,
                                    startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void) async throws {
        guard assetID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw ControlledUploadError.unconfirmed }
        let request = URLRequest(url: uploader.apiURL.appending(path: "assets/\(assetID)"))
        let (data, _) = try await uploader.data(request, startAuthorized: startAuthorized)
        let detail = try JSONDecoder().decode(Remote.self, from: data)
        guard detail.id == assetID, detail.ownerId == ownerID, detail.type == mediaType,
              detail.checksum == checksum, detail.isTrashed == false, detail.isOffline == false else { throw ControlledUploadError.unconfirmed }
        try startAuthorized({})
    }

    static func verifyExisting(assetID: String, checksum: String, mediaType: String, credentials: ShareTransfer.Credentials,
                               startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void) async throws {
        let uploader = ControlledFileUploader(apiURL: credentials.apiURL, token: credentials.token)
        defer { uploader.invalidate() }
        let (data, _) = try await uploader.data(URLRequest(url: credentials.apiURL.appending(path: "users/me")), startAuthorized: startAuthorized)
        let owner = try JSONDecoder().decode(Owner.self, from: data)
        guard !owner.id.isEmpty else { throw ControlledUploadError.unconfirmed }
        try await verifyAsset(assetID: assetID, checksum: checksum, mediaType: mediaType, ownerID: owner.id,
                              uploader: uploader, startAuthorized: startAuthorized)
    }

    static func run(_ records: [ShareQueueRecord], store: ShareQueueStore, credentials: ShareTransfer.Credentials,
                    startAuthorized: @escaping @Sendable (@Sendable () throws -> Void) throws -> Void) async -> ShareQueueResult {
        var result = ShareQueueResult()
        let uploader = ControlledFileUploader(apiURL: credentials.apiURL, token: credentials.token)
        defer { uploader.invalidate() }
        for (index, original) in records.enumerated() {
            if Task.isCancelled { result.cancelled = true; result.pending += records.count - index; break }
            guard original.identity == credentials.identity else { result.failed += 1; continue }
            do {
                guard let lease = try store.claim(original) else { result.pending += 1; continue }
                defer { lease.release() }
                let record = try store.started(lease.record)
                let guardedStart: @Sendable (@Sendable () throws -> Void) throws -> Void = { resume in
                    try startAuthorized { try store.withPending(record) { try resume() } }
                }
                let ownerRequest = URLRequest(url: credentials.apiURL.appending(path: "users/me"))
                let (ownerData, _) = try await uploader.data(ownerRequest, startAuthorized: guardedStart)
                let owner = try JSONDecoder().decode(Owner.self, from: ownerData)
                guard !owner.id.isEmpty else { throw ControlledUploadError.unconfirmed }
                try Task.checkCancellation()
                let request = try record.request(token: credentials.token)
                let (data, _) = try await uploader.upload(request, fromFile: URL(fileURLWithPath: record.bodyPath), startAuthorized: guardedStart)
                let uploaded = try JSONDecoder().decode(Upload.self, from: data)
                try await verifyAsset(assetID: uploaded.id, checksum: record.checksum, mediaType: record.mediaType,
                                      ownerID: owner.id, uploader: uploader, startAuthorized: guardedStart)
                try Task.checkCancellation()
                try guardedStart({})
                try store.remove(record)
                result.uploaded += 1
            } catch {
                if Task.isCancelled || error is CancellationError {
                    result.cancelled = true; result.pending += records.count - index; break
                }
                result.failed += 1
                // Transient transport failures retain a bounded automatic retry.
                // Contract/authorization failures require a fresh user action.
                if !(error is URLError) { try? store.markAttention(original) }
            }
        }
        return result
    }
}
