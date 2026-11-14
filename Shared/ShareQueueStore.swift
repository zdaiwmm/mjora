import Darwin
import Foundation

nonisolated struct ShareQueueRecord: Codable, Equatable, Sendable {
    enum Transfer: Codable, Equatable, Sendable {
        case multipart(boundary: String)
        case raw(uploadId: String)
    }
    let id: UUID
    let identity: ShareCredentialIdentity
    let bodyPath: String
    let filename: String
    let checksum: String
    let verifiedProduct: String?
    let transfer: Transfer
    let mediaType: String
    let createdAt: Date
    var bodyByteCount: Int64?
    var attempts = 0
    var needsAttention = false

    init(identity: ShareCredentialIdentity, bodyPath: String, filename: String, checksum: String,
         verifiedProduct: String?, transfer: Transfer, mediaType: String = "IMAGE") {
        id = UUID(); self.identity = identity; self.bodyPath = bodyPath; self.filename = filename
        self.checksum = checksum; self.verifiedProduct = verifiedProduct; self.transfer = transfer
        self.mediaType = mediaType; createdAt = Date()
    }

    func request(token: String) throws -> URLRequest {
        guard identity.matchesToken(token), !checksum.isEmpty, ["IMAGE", "VIDEO"].contains(mediaType) else { throw ServerTrustError.sessionExpired }
        var request: URLRequest
        switch transfer {
        case .multipart(let boundary):
            guard boundary.range(of: "^[A-Za-z0-9-]{1,100}$", options: .regularExpression) != nil else { throw ServerTrustError.untrustedTarget }
            request = URLRequest(url: identity.apiURL.appending(path: "assets"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request = UploadChecksumHeader.apply(checksum, verifiedProduct: verifiedProduct, to: request)
        case .raw(let id):
            guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw ServerTrustError.untrustedTarget }
            request = URLRequest(url: identity.apiURL.appending(path: "assets/uploads/\(id)"))
            request.httpMethod = "PATCH"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("0", forHTTPHeaderField: "Upload-Offset")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try ServerTrustPolicy(apiURL: identity.apiURL).authorize(request, token: token)
    }
}

nonisolated final class ShareQueueLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    let record: ShareQueueRecord
    init(_ descriptor: Int32, record: ShareQueueRecord) { self.descriptor = descriptor; self.record = record }
    func release() {
        lock.withLock {
            guard let descriptor else { return }
            _ = imora_transfer_unlock(descriptor)
            Darwin.close(descriptor)
            self.descriptor = nil
        }
    }
    deinit { release() }
}

/// One protected, token-free descriptor per body, with an OS lease held across
/// an upload. Process termination releases the lease and leaves recovery data.
nonisolated final class ShareQueueStore: Sendable {
    private let directory: URL
    let bodyDirectory: URL
    init(directory: URL, bodyDirectory: URL) { self.directory = directory; self.bodyDirectory = bodyDirectory }
    private func descriptor(_ record: ShareQueueRecord) -> URL { directory.appending(path: record.id.uuidString + ".json") }
    private func cancellation(_ record: ShareQueueRecord) -> URL { directory.appending(path: record.id.uuidString + ".cancelled") }
    func isPending(_ record: ShareQueueRecord) -> Bool {
        FileManager.default.fileExists(atPath: descriptor(record).path)
            && !FileManager.default.fileExists(atPath: cancellation(record).path)
            && ((try? body(record)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
    private func withControlLock<T>(_ record: ShareQueueRecord, _ operation: () throws -> T) throws -> T {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let url = directory.appending(path: record.id.uuidString + ".control")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard imora_transfer_lock(descriptor, 0) == 0 else { throw POSIXError(.EIO) }
        defer { _ = imora_transfer_unlock(descriptor) }
        try ProtectedTemporaryFiles.protect(url)
        return try operation()
    }
    func withPending<T>(_ record: ShareQueueRecord, _ operation: () throws -> T) throws -> T {
        try withControlLock(record) {
            guard isPending(record) else { throw CancellationError() }
            return try operation()
        }
    }
    func cancel(_ record: ShareQueueRecord) throws {
        try withControlLock(record) {
        _ = try body(record)
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        try Data().write(to: cancellation(record), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try ProtectedTemporaryFiles.protect(cancellation(record))
        try remove(record)
        }
    }

    private func body(_ record: ShareQueueRecord) throws -> URL {
        guard let url = ProtectedTemporaryFiles.ownedFile(record.bodyPath, in: bodyDirectory) else { throw ServerTrustError.untrustedTarget }
        return url
    }
    private func write(_ record: ShareQueueRecord) throws {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let url = descriptor(record)
        try JSONEncoder().encode(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try ProtectedTemporaryFiles.protect(url)
    }
    func enqueue(_ record: ShareQueueRecord) throws -> ShareQueueRecord {
        let url = try body(record)
        try ProtectedTemporaryFiles.protect(url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ControlledUploadError.unconfirmed }
        var record = record; record.bodyByteCount = size
        try write(record)
        return record
    }
    func pending(includeAttention: Bool = false) throws -> [ShareQueueRecord] {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(ShareQueueRecord.self, from: data),
                      (try? body(record)) != nil, isPending(record), includeAttention || (!record.needsAttention && record.attempts < 3) else { return nil }
                return record
            }.sorted { $0.createdAt < $1.createdAt }
    }
    func claim(_ record: ShareQueueRecord, includeAttention: Bool = false) throws -> ShareQueueLease? {
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let lockURL = directory.appending(path: record.id.uuidString + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard imora_transfer_lock(descriptor, 1) == 0 else { Darwin.close(descriptor); return nil }
        do {
            let data: Data
            do { data = try Data(contentsOf: self.descriptor(record)) }
            catch CocoaError.fileReadNoSuchFile { _ = imora_transfer_unlock(descriptor); Darwin.close(descriptor); return nil }
            let current = try JSONDecoder().decode(ShareQueueRecord.self, from: data)
            guard current.id == record.id, current.identity == record.identity, isPending(current),
                  includeAttention || (!current.needsAttention && current.attempts < 3) else {
                _ = imora_transfer_unlock(descriptor); Darwin.close(descriptor); return nil
            }
            let url = try body(current)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == current.bodyByteCount, (size ?? 0) > 0 else { throw ControlledUploadError.unconfirmed }
            try ProtectedTemporaryFiles.protect(lockURL)
            return ShareQueueLease(descriptor, record: current)
        } catch { _ = imora_transfer_unlock(descriptor); Darwin.close(descriptor); throw error }
    }

    func started(_ original: ShareQueueRecord) throws -> ShareQueueRecord {
        guard isPending(original) else { throw CancellationError() }
        var record = original; record.attempts += 1; try write(record); return record
    }
    func markAttention(_ original: ShareQueueRecord) throws {
        guard isPending(original) else { return }
        var record = original; record.needsAttention = true; try write(record)
    }
    func remove(_ record: ShareQueueRecord) throws {
        let url = try body(record)
        do { try FileManager.default.removeItem(at: descriptor(record)) } catch CocoaError.fileNoSuchFile {}
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
        // Keep the tiny stable lease inode: unlinking it could let a second
        // worker lock a different inode while the first still owns this one.
    }
}
