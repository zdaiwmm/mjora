import Foundation
import ImageIO
import os

nonisolated struct LaunchViewportSnapshot: Codable, Equatable, Sendable {
    struct Layout: Codable, Equatable, Sendable {
        let width: Double
        let height: Double
        let scale: Double
        let columns: Int
    }
    let scope: StableMediaScope
    let source: String
    let filter: String
    let sort: String
    let anchor: String
    let layout: Layout
    let visibleKeys: [MediaDisplayKeyV1]
    /// Only the visible viewport's Asset metadata, never the whole library.
    let metadata: Data
    var bucketList: Data? = nil
    var bucketIDByAssetID: [String: String] = [:]
    /// Original per-bucket leading slots omitted from W0 metadata.
    var bucketLeadingAssetCounts: [String: Int] = [:]
    var anchorOffset: Double = 0
}

nonisolated struct PreparedImageRecord: Codable, Equatable, Sendable {
    enum Content: String, Codable, Sendable { case photograph, thumbhash, workingDraft, protected }
    let key: MediaDisplayKeyV1
    let bytes: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let content: Content
    var nativeResolution: NativeImageResolution? = nil
    var localProvenance: LocalSurfaceProvenance? = nil

    var isQualified: Bool {
        guard content == .photograph && !bytes.isEmpty
            && (min(pixelWidth, pixelHeight) >= key.pixelBucket
                || nativeResolution?.accepts(width: pixelWidth, height: pixelHeight, key: key) == true)
            && !key.presentationRevision.hasPrefix("draft:")
            && key.variant != .original,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == pixelWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == pixelHeight,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { return false }
        return true
    }
}

nonisolated struct LaunchContext: Sendable {
    let access: MediaAccessGeneration
    let protectedDataAvailable: Bool
    let filter: String
    let layout: LaunchViewportSnapshot.Layout?
}

nonisolated enum LaunchPackReadResult: Sendable {
    case complete(LaunchViewportSnapshot, [PreparedImageRecord])
    case partial(LaunchViewportSnapshot, [PreparedImageRecord], missingKeys: [MediaDisplayKeyV1])
    case invalid(String)
    case notAvailable
}

nonisolated struct LaunchPackReceipt: Sendable {
    let generation: UUID
    let byteCount: Int
}

actor LaunchPreviewStore {
    static let budget = 32 << 20
    nonisolated static let rootDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appending(path: "imora/launch-previews")
    static let shared = LaunchPreviewStore(root: rootDirectory)
    private let root: URL
    init(root: URL) { self.root = root }

    private struct Entry: Codable {
        let key: MediaDisplayKeyV1
        let digest: String
        let width: Int
        let height: Int
        let nativeResolution: NativeImageResolution?
        var localProvenance: LocalSurfaceProvenance? = nil
    }
    private struct Manifest: Codable {
        let version: Int
        let generation: UUID
        let snapshot: LaunchViewportSnapshot
        let entries: [Entry]
    }

    private func directory(_ scope: StableMediaScope) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return root.appending(path: MediaDisplayKeyV1.digest(try encoder.encode(scope)))
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    /// Reclaim process-death staging before allocating, not only after a commit.
    /// The currently referenced complete generation is always retained.
    private func recoverAbandonedGenerations() {
        PreviewDiskBudget.recoverAbandonedGenerations(root: root)
    }

    private func reserve(_ bytes: Int, preserving directory: URL) throws {
        let reserve = PreviewDiskBudget.allocatedBytes(for: bytes) + 4096
        let others = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
        for other in others.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if diskUsage() + reserve <= Int64(Self.budget - (1 << 20)) { break }
            guard other.lastPathComponent != directory.lastPathComponent,
                  (try? other.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try FileManager.default.removeItem(at: other)
        }
        // One MiB is always available for an atomic retirement-journal update.
        guard diskUsage() + reserve <= Int64(Self.budget - (1 << 20)) else { throw CocoaError(.fileWriteOutOfSpace) }
    }

    /// This survives even when bytes for the new viewport have not arrived.
    func noteViewport(_ snapshot: LaunchViewportSnapshot) throws {
        guard snapshot.visibleKeys.allSatisfy(\.isCurrentContent) else { throw CocoaError(.fileReadCorruptFile) }
        try PreviewDiskBudget.withLock { try writeViewport(snapshot) }
    }

    private func writeViewport(_ snapshot: LaunchViewportSnapshot) throws {
        try Task.checkCancellation()
        guard !snapshot.visibleKeys.isEmpty,
              Set(snapshot.visibleKeys).count == snapshot.visibleKeys.count,
              snapshot.visibleKeys.allSatisfy({ $0.scope == snapshot.scope }),
              snapshot.metadata.count <= 1 << 20,
              try JSONEncoder().encode(snapshot).count <= 1 << 20 else { throw CocoaError(.fileWriteInvalidFileName) }
        let directory = try directory(snapshot.scope)
        recoverAbandonedGenerations()
        try createDirectory(directory)
        let data = try JSONEncoder().encode(snapshot)
        try reserve(data.count, preserving: directory)
        try data.write(to: directory.appending(path: "latest.json"), options: .atomic)
    }

    func checkpoint(snapshot: LaunchViewportSnapshot, images: [PreparedImageRecord]) throws -> LaunchPackReceipt {
        guard snapshot.visibleKeys.allSatisfy(\.isCurrentContent) else { throw CocoaError(.fileReadCorruptFile) }
        return try PreviewDiskBudget.withLock { try writeCheckpoint(snapshot: snapshot, images: images) }
    }

    private func writeCheckpoint(snapshot: LaunchViewportSnapshot, images: [PreparedImageRecord]) throws -> LaunchPackReceipt {
        try Task.checkCancellation()
        try writeViewport(snapshot)
        let wanted = Set(snapshot.visibleKeys)
        let qualified = images.filter { $0.isQualified && $0.key.scope == snapshot.scope && wanted.contains($0.key) }
        guard Set(qualified.map(\.key)) == wanted,
              qualified.count == wanted.count else { throw CocoaError(.fileReadCorruptFile) }
        let metadataBytes = try JSONEncoder().encode(snapshot).count
        let byteCount = qualified.reduce(metadataBytes * 3 + qualified.count * 1024) { $0 + $1.bytes.count }
        // Leave room for independently advancing latest metadata and one
        // quarantined manifest while the previous complete generation survives.
        guard byteCount <= Self.budget - (2 << 20) else { throw CocoaError(.fileWriteOutOfSpace) }

        let directory = try directory(snapshot.scope)
        let generation = UUID()
        let entries = qualified.map { image in
            Entry(key: image.key, digest: MediaDisplayKeyV1.digest(image.bytes), width: image.pixelWidth,
                  height: image.pixelHeight, nativeResolution: image.nativeResolution, localProvenance: image.localProvenance)
        }
        let manifest = Manifest(version: 3, generation: generation, snapshot: snapshot, entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let incomingBytes = qualified.reduce(0) { $0 + Int(PreviewDiskBudget.allocatedBytes(for: $1.bytes.count)) }
            + Int(PreviewDiskBudget.allocatedBytes(for: manifestData.count)) + 8192
        // Atomic replacement needs room for both generations. Never delete the
        // previous complete pack to make a too-large replacement appear to fit.
        try reserve(incomingBytes, preserving: directory)
        let staging = directory.appending(path: generation.uuidString)
        try createDirectory(staging)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        for (image, entry) in zip(qualified, entries) {
            try Task.checkCancellation()
            let file = staging.appending(path: image.key.digest)
            try reserve(image.bytes.count, preserving: directory)
            try image.bytes.write(to: file, options: .atomic)
            // A successful write alone does not prove the complete pack is readable.
            guard MediaDisplayKeyV1.digest(try Data(contentsOf: file)) == entry.digest else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try Task.checkCancellation()
        try reserve(manifestData.count, preserving: directory)
        try manifestData.write(to: directory.appending(path: "complete.json"), options: .atomic)
        committed = true
        // GC owns only this re-creatable preview directory, never source/draft/pinned files.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: file.lastPathComponent) != nil, file.lastPathComponent != generation.uuidString {
                try? FileManager.default.removeItem(at: file)
            }
        }
        // The reserve is part of the existing global disk limit. Retire previews
        // belonging to inactive scopes instead of adding an unbounded per-login cache.
        for other in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where other.lastPathComponent != directory.lastPathComponent
            && (try? other.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: other)
        }
        return LaunchPackReceipt(generation: generation, byteCount: byteCount)
    }

    func restore(scope: StableMediaScope, context: LaunchContext) throws -> LaunchPackReadResult {
        #if DEBUG || PHASE4_PERFORMANCE
        let readStarted = ProcessInfo.processInfo.systemUptime
        defer { LaunchPipelineTrace.record("disk-read+digest+encoded-metadata", since: readStarted) }
        #endif
        let result = try PreviewDiskBudget.withLock { try readPack(scope: scope, context: context) }
        switch result {
        case .complete(let snapshot, _), .partial(let snapshot, _, _):
            guard snapshot.visibleKeys.allSatisfy(\.isCurrentContent) else { return .invalid("knownContentRevisionChanged") }
        case .invalid, .notAvailable: break
        }
        return result
    }

    private func readPack(scope: StableMediaScope, context: LaunchContext) throws -> LaunchPackReadResult {
        guard context.protectedDataAvailable else { return .invalid("protectedDataUnavailable") }
        try Task.checkCancellation()
        recoverAbandonedGenerations()
        let directory = try directory(scope)
        let latestURL = directory.appending(path: "latest.json")
        guard FileManager.default.fileExists(atPath: latestURL.path) else { return .notAvailable }
        guard let latestData = try? Data(contentsOf: latestURL), latestData.count <= 2 << 20,
              let latest = try? JSONDecoder().decode(LaunchViewportSnapshot.self, from: latestData),
              latest.scope == scope, latest.visibleKeys.allSatisfy({ $0.scope == scope }) else {
            return .invalid("invalidViewportMetadata")
        }
        guard latest.filter == context.filter else { return .notAvailable }
        let layoutMatches = context.layout == nil || latest.layout == context.layout
        let manifestURL = directory.appending(path: "complete.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .partial(latest, [], missingKeys: latest.visibleKeys)
        }
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 2 << 20,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 3, manifest.snapshot.scope == scope,
              Set(manifest.entries.map(\.key)).count == manifest.entries.count else {
            // Isolate only the corrupt pack's commit pointer. Other caches and drafts survive.
            try? FileManager.default.moveItem(at: manifestURL, to: directory.appending(path: "invalid.json"))
            return .invalid("invalidCompleteGeneration")
        }
        var images: [PreparedImageRecord] = []
        for key in latest.visibleKeys {
            try Task.checkCancellation()
            guard let entry = manifest.entries.first(where: { $0.key == key }),
                  let bytes = try? Data(contentsOf: directory.appending(path: manifest.generation.uuidString).appending(path: key.digest)),
                  bytes.count <= Self.budget,
                  MediaDisplayKeyV1.digest(bytes) == entry.digest else { continue }
            let image = PreparedImageRecord(key: key, bytes: bytes, pixelWidth: entry.width, pixelHeight: entry.height,
                                            content: .photograph, nativeResolution: entry.nativeResolution,
                                            localProvenance: entry.localProvenance)
            if image.isQualified { images.append(image) }
        }
        let found = Set(images.map(\.key))
        let missing = latest.visibleKeys.filter { !found.contains($0) }
        #if DEBUG || PHASE4_PERFORMANCE
        if LaunchPipelineTrace.enabled {
            Logger(subsystem: "com.vexcited.imora", category: "LaunchPreview").info("restore assessment missing=\(missing.count) sameSnapshot=\(latest == manifest.snapshot) sameMetadata=\(latest.metadata == manifest.snapshot.metadata) sameKeys=\(latest.visibleKeys == manifest.snapshot.visibleKeys) sameAnchor=\(latest.anchor == manifest.snapshot.anchor) latestOffset=\(latest.anchorOffset) completeOffset=\(manifest.snapshot.anchorOffset) layoutMatches=\(layoutMatches) savedHeight=\(latest.layout.height) requestedHeight=\(context.layout?.height ?? -1) savedWidth=\(latest.layout.width) requestedWidth=\(context.layout?.width ?? -1)")
        }
        #endif
        guard missing.isEmpty, latest == manifest.snapshot, layoutMatches else {
            return .partial(latest, images, missingKeys: missing)
        }
        return .complete(latest, images)
    }

    func invalidate(scope: StableMediaScope) throws {
        try PreviewDiskBudget.withLock {
            let directory = try directory(scope)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    func removeAll() throws {
        // Retirement state is derivative metadata, not an image. Keep it when
        // clearing bytes so an old Nuke namespace cannot become valid again.
        try PreviewDiskBudget.withLock {
            for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent != "content-generations.json" { try FileManager.default.removeItem(at: file) }
        }
    }

    func diskUsage() -> Int64 {
        PreviewDiskBudget.diskUsage(root: root)
    }
}

nonisolated enum PreviewDiskBudget {
    private static let lock = NSRecursiveLock()
    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try operation()
    }
    static func recoverAbandonedGenerations(root: URL) {
        for scope in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if scope.lastPathComponent.hasPrefix(".content-generations-") {
                try? FileManager.default.removeItem(at: scope); continue
            }
            guard (try? scope.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifest = (try? Data(contentsOf: scope.appending(path: "complete.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let retained = manifest?["generation"] as? String
            for file in (try? FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil)) ?? [] {
                if UUID(uuidString: file.lastPathComponent) != nil, file.lastPathComponent != retained {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try? FileManager.default.removeItem(at: scope.appending(path: "invalid.json"))
        }
    }
    static func allocatedBytes(for count: Int) -> Int64 { Int64((max(0, count) + 4095) / 4096 * 4096) }
    static func diskUsage(root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
    }
}
