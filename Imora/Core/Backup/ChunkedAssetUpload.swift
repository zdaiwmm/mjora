import Foundation
import os

/// imora takes a file as raw chunks, so a backup holds about two chunks of a
/// large video on disk instead of a whole copy of it.
nonisolated enum ChunkedAssetUpload {
    /// fits under the 100 MB request cap of common proxies.
    static let defaultChunkBytes: Int64 = 64 << 20

    struct Policy: Sendable {
        let chunkBytes: Int64

        /// the upload size limit from Backup Settings caps each chunk instead
        /// of the whole file.
        init(maximumRequestBytes: Int64?) {
            chunkBytes = min(ChunkedAssetUpload.defaultChunkBytes, maximumRequestBytes ?? .max)
        }
    }

    /// photokit does not know the file's size or its bytes did not add up to
    /// it. the caller sends the file in one multipart request instead.
    struct Unavailable: Error {}

    static func send(
        _ upload: AssetUploadRequest,
        motion: Bool,
        policy: Policy,
        client: ImoraClient,
        account: String,
        source: BackupEntry,
        lease: ProcessLease?,
        lifetime: BackgroundUploader.RunLifetime?,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)? = nil,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AssetUploadResult {
        guard let resource = await PhotoLibraryService.resourceSize(
            localIdentifier: upload.deviceAssetId, motion: motion
        ) else { throw Unavailable() }
        onResourceProgress?(.init(resourceID: UUID(), filename: resource.filename, stage: .preparing, fraction: nil))
        let relay = LeaseRelay(lease)
        defer { relay.release() }

        var conflicts = 0
        while true {
            let id: String
            let offset: Int64
            switch try await client.openUploadSession(upload, filename: resource.filename, size: resource.bytes) {
            case .finished(let result):
                return result
            case .open(let openID, let openOffset):
                (id, offset) = (openID, openOffset)
            }
            do {
                let result = try await sendChunks(
                    upload, motion: motion, sessionID: id, offset: offset, size: resource.bytes,
                    policy: policy, client: client, account: account, source: source,
                    relay: relay, lifetime: lifetime, onResourceProgress: onResourceProgress,
                    onByteProgress: onByteProgress, onProgress: onProgress
                )
                if let result { return result }
            } catch ImoraError.http(409, _) where conflicts < 2 {
                // something else moved the server's offset, so ask for it again.
                conflicts += 1
                continue
            } catch PhotoLibraryError.unexpectedSize {
                try? await client.cancelUploadSession(id)
                throw Unavailable()
            }
            // every chunk went through and still no asset: the server counted
            // other bytes than photokit reported.
            try? await client.cancelUploadSession(id)
            throw Unavailable()
        }
    }

    private static func sendChunks(
        _ upload: AssetUploadRequest,
        motion: Bool,
        sessionID: String,
        offset: Int64,
        size: Int64,
        policy: Policy,
        client: ImoraClient,
        account: String,
        source: BackupEntry,
        relay: LeaseRelay,
        lifetime: BackgroundUploader.RunLifetime?,
        onResourceProgress: (@Sendable (BackupResourceProgress) -> Void)?,
        onByteProgress: (@Sendable (UploadByteProgress) -> Void)?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AssetUploadResult? {
        let finished = OSAllocatedUnfairLock<AssetUploadResult?>(initialState: nil)
        let send: @Sendable (PhotoLibraryService.ResourceChunk) async throws -> Void = { chunk in
            let result = try await client.uploadChunk(
                sessionID: sessionID,
                offset: chunk.offset,
                bodyURL: chunk.fileURL,
                upload: upload,
                account: account,
                source: source,
                lease: await relay.handOff(),
                lifetime: lifetime,
                onByteProgress: onByteProgress
            ) { fraction in
                onProgress((Double(chunk.offset) + fraction * Double(chunk.length)) / Double(size))
            }
            if let result { finished.withLock { $0 = result } }
        }
        if offset >= size {
            // the server has every byte but never made the asset. an empty
            // chunk at the end completes it.
            let url = BackgroundUploader.bodyDirectory.appending(path: "chunk-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw PhotoLibraryError.exportFailed
            }
            try await send(PhotoLibraryService.ResourceChunk(fileURL: url, offset: offset, length: 0))
        } else {
            try await PhotoLibraryService.streamChunks(
                localIdentifier: upload.deviceAssetId,
                motion: motion,
                from: offset,
                chunkBytes: policy.chunkBytes,
                expectedBytes: size,
                to: BackgroundUploader.bodyDirectory,
                onResourceProgress: onResourceProgress,
                consume: send
            )
        }
        return finished.withLock { $0 }
    }
}

/// keeps the process alive while the next chunk is exported. the uploader
/// lets go of a chunk's lease once the system owns that transfer, by which
/// time a fresh one covers the export of the next.
private nonisolated final class LeaseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProcessLease?

    init(_ lease: ProcessLease?) {
        current = lease
    }

    func handOff() async -> ProcessLease? {
        let next = await ProcessLease.take("backup export")
        return lock.withLock {
            defer { current = next }
            return current
        }
    }

    func release() {
        lock.withLock { current }?.release()
    }
}
