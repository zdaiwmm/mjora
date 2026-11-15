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
    let visibilityPolicy: String?

    init(scope: StableMediaScope, subject: Subject, sourceRevision: String, presentationRevision: String,
         variant: Variant, pixelBucket: Int, fitMode: String, orientationRevision: String, colorProfile: String,
         contentGeneration: String? = nil, visibilityPolicy: String? = nil) {
        self.scope = scope; self.subject = subject; self.sourceRevision = sourceRevision
        self.presentationRevision = presentationRevision; self.variant = variant; self.pixelBucket = pixelBucket
        self.fitMode = fitMode; self.orientationRevision = orientationRevision; self.colorProfile = colorProfile
        self.contentGeneration = contentGeneration
            ?? MediaContentGenerations.shared.current(scope: scope, subject: subject) ?? "unavailable:\(UUID())"
        self.visibilityPolicy = visibilityPolicy
    }

    var isCurrentContent: Bool {
        MediaContentGenerations.shared.isCurrent(scope: scope, subject: subject,
            sourceRevision: sourceRevision, generation: contentGeneration, visibilityPolicy: visibilityPolicy)
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
    private struct Subject: Codable {
        var generation = UUID().uuidString
        var retiredSources: Set<String> = []
        var accessBlocked: Bool?
        var canonicalVisibility: String?
    }
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

    struct CapturedAccess: Sendable {
        fileprivate struct Entry: Sendable { let generation: String; let policy: String?; let blocked: Bool }
        let scope: StableMediaScope
        fileprivate let generations: [String: Entry]
        var isEmpty: Bool { generations.isEmpty }
        func needsConfirmation(subject: MediaDisplayKeyV1.Subject, visibilityPolicy: String) -> Bool {
            guard let entry = generations[MediaContentGenerations.identifier(subject)] else { return false }
            return entry.blocked || entry.policy != visibilityPolicy
        }
    }

    private static func generation(_ state: State?, account: Scope?, subject: Subject?) -> String {
        guard let state else { return "" }
        return "\(state.generation)|\(account?.generation ?? "")|\(subject?.generation ?? "")"
    }

    func isCurrent(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject, sourceRevision: String, generation: String,
                   visibilityPolicy: String? = nil) -> Bool {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable else { return false }
            let account = value.state?.scopes[Self.identifier(scope)]
            let stored = account?.subjects[Self.identifier(subject)]
            return Self.generation(value.state, account: account, subject: stored) == generation
                && stored?.accessBlocked != true && stored?.retiredSources.contains(sourceRevision) != true
                && (stored?.canonicalVisibility == nil || stored?.canonicalVisibility == visibilityPolicy)
        }
    }

    /// One immutable capture per authenticated response, never a library scan.
    func captureAccess(scope: StableMediaScope) -> CapturedAccess {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable, let state = value.state, let account = state.scopes[Self.identifier(scope)] else {
                return .init(scope: scope, generations: [:])
            }
            return .init(scope: scope, generations: account.subjects.compactMapValues { subject -> CapturedAccess.Entry? in
                guard subject.accessBlocked == true || subject.canonicalVisibility != nil else { return nil }
                return .init(generation: Self.generation(state, account: account, subject: subject),
                    policy: subject.canonicalVisibility, blocked: subject.accessBlocked == true)
            })
        }
    }

    func matchesAccess(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject, captured: CapturedAccess) -> Bool {
        guard captured.scope == scope, let expected = captured.generations[Self.identifier(subject)] else { return false }
        return memory.withLock { value in
            load(&value)
            guard !value.unavailable else { return false }
            let account = value.state?.scopes[Self.identifier(scope)], stored = account?.subjects[Self.identifier(subject)]
            return (stored?.accessBlocked == true || stored?.canonicalVisibility != nil)
                && Self.generation(value.state, account: account, subject: stored) == expected.generation
        }
    }

    /// The client response/projection boundary supplies positive policy proof;
    /// this transaction fences its captured block and never erases source history.
    @discardableResult
    func authorize(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject, sourceRevision: String,
                   captured: CapturedAccess, visibilityPolicy: String? = nil) throws -> Bool {
        guard captured.scope == scope, let expected = captured.generations[Self.identifier(subject)] else { return false }
        return try memory.withLock { value in
            load(&value)
            let scopeID = Self.identifier(scope), subjectID = Self.identifier(subject)
            guard !value.unavailable, var state = value.state, var account = state.scopes[scopeID],
                  var stored = account.subjects[subjectID], stored.accessBlocked == true || stored.canonicalVisibility != visibilityPolicy,
                  Self.generation(state, account: account, subject: stored) == expected.generation,
                  !stored.retiredSources.contains(sourceRevision) else { return false }
            stored.accessBlocked = false; stored.generation = UUID().uuidString
            stored.canonicalVisibility = visibilityPolicy
            account.subjects[subjectID] = stored; state.scopes[scopeID] = account
            // Failure leaves the previous persisted/memory block intact.
            try persist(state)
            value = Memory(state: state, loaded: true, unavailable: false)
            return true
        }
    }

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
        presentationNamespace(scope: scope, subject: subject).generation
    }

    func presentationNamespace(scope: StableMediaScope, subject: MediaDisplayKeyV1.Subject) -> (generation: String?, visibilityPolicy: String?) {
        memory.withLock { value in
            load(&value)
            guard !value.unavailable else { return (nil, nil) }
            guard let state = value.state else { return ("", nil) }
            let account = state.scopes[Self.identifier(scope)]
            let stored = account?.subjects[Self.identifier(subject)]
            return (Self.generation(state, account: account, subject: stored), stored?.canonicalVisibility)
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

    func retire(scope: StableMediaScope, subjects: [MediaDisplayKeyV1.Subject]?, keys: [MediaDisplayKeyV1] = [],
                retiresSourceRevisions: Bool = true, blocksAccess: Bool = false) throws {
        try memory.withLock { value in
            load(&value)
            var state = value.state ?? State()
            let scopeID = Self.identifier(scope)
            var account = state.scopes[scopeID] ?? Scope()
            let savedKeys = (try? Data(contentsOf: root.appending(path: scopeID).appending(path: "latest.json")))
                .flatMap { try? JSONDecoder().decode(LaunchViewportSnapshot.self, from: $0) }?.visibleKeys ?? []
            // Pair/source selection changes retire the namespace, not the
            // unchanged remote revision contributed by a saved launch pack.
            let retiredKeys = retiresSourceRevisions
                ? (savedKeys + keys).filter { key in subjects == nil || subjects!.contains(key.subject) } : []
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
                    if blocksAccess { stored.accessBlocked = true }
                    account.subjects[id] = stored
                }
            } else { account.generation = UUID().uuidString }
            if account.subjects.count > 512 {
                account.generation = UUID().uuidString
                account.subjects = account.subjects.filter { !$0.value.retiredSources.isEmpty || $0.value.accessBlocked == true || $0.value.canonicalVisibility != nil }
            }
            state.scopes[scopeID] = account
            if state.scopes.count > 64 {
                // A global rollover retires every evicted scope; never return
                // an evicted account to an earlier empty generation.
                state.generation = UUID().uuidString; state.legacyMigrationAllowed = false
                state.scopes = state.scopes.filter { key, value in
                    key == scopeID || value.subjects.values.contains { !$0.retiredSources.isEmpty || $0.accessBlocked == true || $0.canonicalVisibility != nil }
                }
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
        guard state.scopes.count <= 64, state.scopes.values.allSatisfy({ $0.subjects.count <= 512 }), data.count <= 1 << 20,
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
