import AVFoundation
import Foundation
import ObjectiveC
import Synchronization

/// Keeps the file alive through asynchronous preparation and AVFoundation use.
nonisolated final class ControlledMediaFile: Sendable {
    let url: URL
    private let release: @Sendable () -> Void
    private nonisolated(unsafe) static var associationKey: UInt8 = 0
    init(url: URL, release: @escaping @Sendable () -> Void) { self.url = url; self.release = release }
    deinit { release() }
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        objc_setAssociatedObject(asset, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}

/// Credentials never enter AVFoundation. Idle cache is bounded; files in use
/// remain pinned until their consumers release them, including across awaits.
actor ControlledMediaStore {
    nonisolated static let rootDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/controlled-media")
    private struct Registry: Sendable {
        var directories: Set<URL> = []
        var pins: [URL: Int] = [:]
        var clearWhenReleased: Set<URL> = []
    }
    private nonisolated static let registry = Mutex(Registry())
    private let directory: URL
    private let maximumBytes: Int64
    private var files: [URL: URL] = [:]
    private var revision: UInt64 = 0

    init(root: URL = ControlledMediaStore.rootDirectory, maximumBytes: Int64 = 1_073_741_824) {
        directory = root.appending(path: UUID().uuidString)
        self.maximumBytes = maximumBytes
        Self.registry.withLock { state in
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !state.directories.contains(child) {
                try? FileManager.default.removeItem(at: child)
            }
            state.directories.insert(directory)
        }
    }
    deinit {
        let path = directory
        Self.registry.withLock { state in
            state.directories.remove(path)
            try? FileManager.default.removeItem(at: path)
        }
    }
    nonisolated static func diskUsage(root: URL = rootDirectory) -> Int64 {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return items.reduce(Int64(0)) { sum, item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return sum }
            return sum + Int64(values.fileSize ?? 0)
        }
    }
    nonisolated static func clearCache(root: URL = rootDirectory) {
        registry.withLock { state in
            guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            for case let url as URL in items {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if (state.pins[url] ?? 0) > 0 { state.clearWhenReleased.insert(url) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
    private func lease(_ file: URL) -> ControlledMediaFile {
        Self.registry.withLock { $0.pins[file, default: 0] += 1 }
        return ControlledMediaFile(url: file) { [self] in
            Self.registry.withLock { state in
                state.pins[file, default: 0] -= 1
                if state.pins[file] == 0 {
                    state.pins[file] = nil
                    if state.clearWhenReleased.remove(file) != nil { try? FileManager.default.removeItem(at: file) }
                }
            }
            Task { await self.trim() }
        }
    }
    private func trim() {
        Self.registry.withLock { state in
            var size = Self.diskUsage(root: directory)
            let idle = files.values.filter { (state.pins[$0] ?? 0) == 0 }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in idle where size > maximumBytes {
                let bytes = Int64((try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? FileManager.default.removeItem(at: old)
                size -= bytes
                files = files.filter { $0.value != old }
            }
        }
    }
    func file(request: URLRequest, session: URLSession, context: AccountRequestContext) async throws -> ControlledMediaFile {
        try Task.checkCancellation()
        guard context.isActive, let key = request.url else { throw ServerTrustError.sessionExpired }
        if let file = files[key], FileManager.default.isReadableFile(atPath: file.path) { return lease(file) }
        let downloadRevision = revision
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard context.isActive else { throw ServerTrustError.sessionExpired }
        guard revision == downloadRevision else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImoraError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        // Another overlapping request may already have installed this URL.
        if let file = files[key], FileManager.default.isReadableFile(atPath: file.path) { return lease(file) }
        let mime = response.mimeType?.lowercased() ?? ""
        let handle = try FileHandle(forReadingFrom: temporary)
        let prefix = try handle.read(upToCount: 8) ?? Data()
        try handle.close()
        guard (mime.hasPrefix("video/") || mime == "application/octet-stream"),
              !mime.contains("mpegurl"), !prefix.starts(with: Data("#EXTM3U".utf8))
        else { throw ImoraError.decoding(String(localized: "The server did not return a self-contained video file.")) }
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let file = directory.appending(path: UUID().uuidString).appendingPathExtension(mime == "video/quicktime" ? "mov" : "mp4")
        try FileManager.default.moveItem(at: temporary, to: file)
        try ProtectedTemporaryFiles.protect(file)
        files[key] = file
        let result = lease(file)
        trim()
        return result
    }
    func invalidateCachedFiles() {
        revision &+= 1
        Self.clearCache(root: directory)
        files.removeAll()
    }

    func removeAll() {
        revision &+= 1
        files.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
