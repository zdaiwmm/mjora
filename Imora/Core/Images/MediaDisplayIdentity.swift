import Foundation
import CryptoKit
import Synchronization
import Darwin

nonisolated struct LocalSurfaceProvenance: Codable, Equatable, Sendable {
    let localIdentifier: String
    let modificationRevision: String
    let remoteIdentifier: String?
}

/// Content identity is deliberately independent of permission to read it.
nonisolated struct StableMediaScope: Codable, Hashable, Sendable {
    let serverIdentity: String
    let accountID: String?
    let credentialScope: String?

    static func verified(server: String, accountID: String) -> Self {
        Self(serverIdentity: server, accountID: accountID, credentialScope: nil)
    }

    static func credential(_ credential: String, server: String) -> Self {
        Self(serverIdentity: server, accountID: nil, credentialScope: credential)
    }
}

nonisolated struct MediaAccessGeneration: Hashable, Sendable {
    let session: UUID
    let permission: Int
}

/// An accessible PhotoKit final image can be smaller than a tile because the
/// actual source is small. Never infer this from a thumbnail's own dimensions.
nonisolated struct NativeImageResolution: Codable, Equatable, Sendable {
    let sourceRevision: String
    let pixelWidth: Int
    let pixelHeight: Int

    func accepts(width: Int, height: Int, key: MediaDisplayKeyV1) -> Bool {
        guard case .localAsset = key.subject, !sourceRevision.isEmpty,
              sourceRevision == key.sourceRevision, pixelWidth > 0, pixelHeight > 0 else { return false }
        return Double(min(width, height)) >= Double(min(pixelWidth, pixelHeight)) * 0.95
            && Double(max(width, height)) >= Double(max(pixelWidth, pixelHeight)) * 0.95
    }
}

nonisolated struct MediaDisplayKeyV1: Codable, Hashable, Sendable {
    enum Subject: Codable, Hashable, Sendable {
        case remoteAsset(String)
        case localAsset(installationID: String, localIdentifier: String)
        case artwork(kind: String, objectID: String, contentRevision: String)
    }
    enum Variant: String, Codable, Sendable {
        case grid, cover, avatar, artwork, viewerPreview, original, livePoster, motionFrame
    }
    let scope: StableMediaScope
    let subject: Subject
    let sourceRevision: String
    let presentationRevision: String
    let variant: Variant
    let pixelBucket: Int
    let fitMode: String
    let orientationRevision: String
    let colorProfile: String
    let contentGeneration: String

    init(scope: StableMediaScope, subject: Subject, sourceRevision: String, presentationRevision: String,
         variant: Variant, pixelBucket: Int, fitMode: String, orientationRevision: String, colorProfile: String,
         contentGeneration: String? = nil) {
        self.scope = scope; self.subject = subject; self.sourceRevision = sourceRevision
        self.presentationRevision = presentationRevision; self.variant = variant; self.pixelBucket = pixelBucket
        self.fitMode = fitMode; self.orientationRevision = orientationRevision; self.colorProfile = colorProfile
        self.contentGeneration = contentGeneration
            ?? MediaContentGenerations.shared.current(scope: scope, subject: subject) ?? "unavailable:\(UUID())"
    }

    var isCurrentContent: Bool {
        MediaContentGenerations.shared.current(scope: scope, subject: subject) == contentGeneration
            && !MediaContentGenerations.shared.isRetired(scope: scope, subject: subject, sourceRevision: sourceRevision)
    }

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest((try? encoder.encode(self)) ?? Data())
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Small derivative-only retirement journal. Every image size/endpoint shares
/// a subject generation; the journal is inside the same 32 MiB preview domain.
/// Missing state gets a new random namespace before the app uses a cache, so
/// GC/corruption can never recreate a formerly authorized content namespace.
nonisolated final class MediaContentGenerations: Sendable {
    struct RetirementFailure: Error, Sendable {
        let journalRemovalSucceeded: Bool
    }
    static let shared = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
    private struct Subject: Codable { var generation = UUID().uuidString; var retiredSources: Set<String> = [] }
    private struct Scope: Codable { var generation = ""; var subjects: [String: Subject] = [:] }
    private struct State: Codable {
        var generation = UUID().uuidString
        var scopes: [String: Scope] = [:]
        var legacyMigrationAllowed = true
    }
    private struct Memory { var state: State?; var loaded = false; var unavailable = false }
    private let memory = Mutex(Memory())
    private let root: URL
    private var file: URL { root.appending(path: "content-generations.json") }
    init(root: URL) { self.root = root }

    private static func identifier<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return MediaDisplayKeyV1.digest((try? encoder.encode(value)) ?? Data())
    }

    private func load(_ value: inout Memory) {
        guard !value.loaded else { return }
        value.loaded = true
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file), data.count <= 1 << 20,
              let state = try? JSONDecoder().decode(State.self, from: data) else { value.unavailable = true; return }
        value.state = state
    }

    func current(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject) -> String? {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable else { return nil }
            guard let state = value.state else { return "" }
            let account = state.scopes[Self.identifier(scope)]
            return "\(state.generation)|\(account?.generation ?? "")|\(account?.subjects[Self.identifier(subject)]?.generation ?? "")"
        }
    }

    func isRetired(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject, sourceRevision: String) -> Bool {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable else { return true }
            return value.state?.scopes[Self.identifier(scope)]?.subjects[Self.identifier(subject)]?.retiredSources.contains(sourceRevision) == true
        }
    }

    func canMigrateLegacy(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject) -> Bool {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable, value.state?.legacyMigrationAllowed != false else { return false }
            let account = value.state?.scopes[Self.identifier(scope)]
            return account?.generation.isEmpty != false && account?.subjects[Self.identifier(subject)] == nil
        }
    }

    func ensureInitialized() throws {
        try memory.withLock { value in
            load(&value)
            if value.state != nil, !value.unavailable { return }
            var state = value.state ?? State()
            if value.unavailable { state.legacyMigrationAllowed = false }
            do { try persist(state); value = Memory(state: state, loaded: true, unavailable: false) }
            catch { value.unavailable = true; throw error }
        }
    }

    func rollover() throws {
        try memory.withLock { value in
            load(&value)
            var state = value.state ?? State(); state.generation = UUID().uuidString; state.legacyMigrationAllowed = false
            try persist(state)
            value = Memory(state: state, loaded: true, unavailable: false)
        }
    }

    func retire(scope: StableMediaScope, subjects: [MediaDisplayKeyV1.Subject]?, keys: [MediaDisplayKeyV1] = []) throws {
        try memory.withLock { value in
            load(&value)
            var state = value.state ?? State()
            let scopeID = Self.identifier(scope)
            var account = state.scopes[scopeID] ?? Scope()
            let savedKeys = (try? Data(contentsOf: root.appending(path: scopeID).appending(path: "latest.json")))
                .flatMap { try? JSONDecoder().decode(LaunchViewportSnapshot.self, from: $0) }?.visibleKeys ?? []
            let retiredKeys = (savedKeys + keys).filter { key in subjects == nil || subjects!.contains(key.subject) }
            for key in retiredKeys {
                let id = Self.identifier(key.subject)
                var subject = account.subjects[id] ?? Subject()
                subject.retiredSources.insert(key.sourceRevision)
                subject.generation = UUID().uuidString
                account.subjects[id] = subject
            }
            if let subjects {
                for subject in subjects {
                    let id = Self.identifier(subject)
                    var stored = account.subjects[id] ?? Subject()
                    stored.generation = UUID().uuidString
                    account.subjects[id] = stored
                }
            } else { account.generation = UUID().uuidString }
            if account.subjects.count > 512 { account.generation = UUID().uuidString; account.subjects = [:] }
            state.scopes[scopeID] = account
            if state.scopes.count > 64 {
                // A global rollover retires every evicted scope; never return
                // an evicted account to an earlier empty generation.
                state = State(scopes: [scopeID: account], legacyMigrationAllowed: false)
            }
            do { try persist(state); value = Memory(state: state, loaded: true, unavailable: false) }
            catch {
                value.state = state
                value.unavailable = true
                // Removing a stale commit pointer is fail-closed: on restart a
                // fresh namespace is required, never the failed old journal.
                let removed = PreviewDiskBudget.withLock {
                    do {
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                        return !FileManager.default.fileExists(atPath: file.path)
                    } catch { return false }
                }
                throw RetirementFailure(journalRemovalSucceeded: removed)
            }
        }
    }

    private func persist(_ state: State) throws {
        try PreviewDiskBudget.withLock { try write(state) }
    }

    private func write(_ state: State) throws {
        PreviewDiskBudget.recoverAbandonedGenerations(root: root)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1 << 20,
              PreviewDiskBudget.diskUsage(root: root) + PreviewDiskBudget.allocatedBytes(for: data.count) + 4096
                <= Int64(LaunchPreviewStore.budget) else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".content-generations-staging")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging)
        var url = staging
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
        #endif
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize(); try handle.close()
        guard Darwin.rename(staging.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = Darwin.open(root.path, O_RDONLY)
        if directory >= 0 { _ = Darwin.fsync(directory); _ = Darwin.close(directory) }
    }
}
