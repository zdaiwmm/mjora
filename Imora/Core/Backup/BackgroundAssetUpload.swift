import CryptoKit
import Foundation
import os

nonisolated struct BackgroundUploadState: Decodable, Sendable {
    var uploadId: String?
    var offset: Int64?
    var size: Int64?
    var partBytes: Int64?
    var key: String?
    var capability: String?
    var result: AssetUploadResult?
}

/// The daemon receives neither plaintext nor account credentials. Its response
/// is never completion evidence; only the authenticated status request is.
nonisolated enum SealedUploadPart {
    static func seal(_ data: Data, key: String, id: String, offset: Int64) throws -> Data {
        guard let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            throw ImoraError.decoding("Invalid background upload key")
        }
        let aad = Data("\(id):\(offset):\(data.count)".utf8)
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: bytes), authenticating: aad)
        guard let combined = sealed.combined else { throw ImoraError.decoding("Invalid encrypted upload") }
        return combined
    }
}

nonisolated enum BackgroundAssetUpload {
    static func send(
        _ upload: AssetUploadRequest, motion: Bool, client: ImoraClient, account: String,
        source: BackupEntry, lifetime: BackgroundUploader.RunLifetime?,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)?,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)?,
        beforeUpload: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AssetUploadResult {
        defer { BackgroundUploader.shared.finishedPreparing(account: account, localId: upload.deviceAssetId) }
        guard let resource = await PhotoLibraryService.resourceSize(localIdentifier: upload.deviceAssetId, motion: motion) else {
            throw ChunkedAssetUpload.Unavailable()
        }
        var state = try await client.openBackgroundUpload(upload, filename: resource.filename, size: resource.bytes)
        if let result = state.result { return result }
        if let id = state.uploadId, id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) {
            // A daemon may have finished after the preceding app process ended.
            try await beforeUpload()
            state = try await client.backgroundUploadStatus(id)
            if let result = state.result { return result }
        }
        guard let id = state.uploadId, id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
              let offset = state.offset, offset >= 0, offset <= resource.bytes,
              state.size == resource.bytes,
              let chunkBytes = state.partBytes, chunkBytes > 0, chunkBytes <= 8 << 20 else {
            throw ImoraError.decoding("Invalid background upload state")
        }
        let progress = OSAllocatedUnfairLock<BackgroundUploadState>(initialState: state)
        try await PhotoLibraryService.streamChunks(
            localIdentifier: upload.deviceAssetId, motion: motion, from: offset,
            chunkBytes: chunkBytes, expectedBytes: resource.bytes, to: BackgroundUploader.bodyDirectory,
            onResourceProgress: onResourceProgress
        ) { chunk in
            defer { try? FileManager.default.removeItem(at: chunk.fileURL) }
            try await beforeUpload()
            guard lifetime?.hasExpired != true else { throw CancellationError() }
            var current = progress.withLock { $0 }
            guard let key = current.key, let capability = current.capability else {
                throw ImoraError.decoding("Missing background upload authorization")
            }
            let sealed = try SealedUploadPart.seal(Data(contentsOf: chunk.fileURL), key: key, id: id, offset: chunk.offset)
            let file = BackgroundUploader.bodyDirectory.appending(path: "sealed-\(UUID().uuidString)")
            try sealed.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try ProtectedTemporaryFiles.protect(file)
            try FileManager.default.removeItem(at: chunk.fileURL)
            var retry = 0
            var needsUpload = true
            while true {
                try await beforeUpload()
                guard lifetime?.hasExpired != true else { throw CancellationError() }
                do {
                    if needsUpload {
                        if !FileManager.default.fileExists(atPath: file.path) {
                            try sealed.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                            try ProtectedTemporaryFiles.protect(file)
                        }
                        // A failed response is ambiguous: check the committed offset before retrying bytes.
                        needsUpload = false
                        try await client.uploadBackgroundPart(id: id, capability: capability, offset: chunk.offset,
                            bodyURL: file, upload: upload, account: account, source: source, lifetime: lifetime,
                            onByteProgress: onByteProgress,
                            onProgress: { fraction in onProgress((Double(chunk.offset) + fraction * Double(chunk.length)) / Double(resource.bytes)) })
                    }
                    try await beforeUpload()
                    current = try await client.backgroundUploadStatus(id)
                    guard current.result != nil || (current.offset ?? -1) >= chunk.offset + chunk.length else {
                        needsUpload = true
                        throw URLError(.cannotParseResponse)
                    }
                    let acknowledged = current
                    progress.withLock { $0 = acknowledged }
                    break
                } catch {
                    guard retry < 3, Self.isRetryable(error), !Task.isCancelled else { throw error }
                    retry += 1
                    try await Task.sleep(for: .seconds(1 << (retry - 1)))
                }
            }
        }
        try await beforeUpload()
        state = try await client.backgroundUploadStatus(id)
        guard let result = state.result else { throw ImoraError.decoding("Background upload is incomplete") }
        return result
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .cannotParseResponse].contains(error.code)
        }
        if case ImoraError.http(let status, _) = error { return status == 408 || status == 429 || status >= 500 }
        return false
    }
}
