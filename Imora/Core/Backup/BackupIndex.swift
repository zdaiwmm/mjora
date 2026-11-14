import Foundation
import CryptoKit
import Synchronization

/// persisted backup state for one device asset. a live photo is backed up only
/// when both its still and its paired motion video are confirmed on the server.
nonisolated struct BackupEntry: Codable, Sendable, Equatable {
    /// phasset modification date at hash time. optional by design - never fabricated.
    var modificationDate: Date?
    var isLivePhoto: Bool
    var primaryChecksum: String
    var primaryRemoteId: String?
    var motionChecksum: String?
    var motionRemoteId: String?
    /// multipart request size observed when this revision exceeded the local cap.
    /// the cap itself may change, so eligibility is checked against the current setting.
    var sizeExcludedRequestBytes: Int64?
    /// server rejected with unsupported-format. never uploaded again blindly, never cleanup-eligible.
    var unsupported: Bool
    /// server copy of the revision before an in-place edit on the device. the
    /// new upload gets stacked over it, then this clears.
    var stackOntoRemoteId: String? = nil
    var proof: BackupProof? = nil
    var verificationState: BackupVerificationState? = nil
    var lastVerifiedAt: Date? = nil
    var verificationRevision: UInt64? = nil
    var pairRepairDenied: Bool? = nil
    var primaryByteCount: Int64? = nil
    var motionByteCount: Int64? = nil

    init(
        modificationDate: Date?,
        isLivePhoto: Bool,
        primaryChecksum: String,
        primaryRemoteId: String? = nil,
        motionChecksum: String? = nil,
        motionRemoteId: String? = nil,
        sizeExcludedRequestBytes: Int64? = nil,
        unsupported: Bool = false
    ) {
        self.modificationDate = modificationDate
        self.isLivePhoto = isLivePhoto
        self.primaryChecksum = primaryChecksum
        self.primaryRemoteId = primaryRemoteId
        self.motionChecksum = motionChecksum
        self.motionRemoteId = motionRemoteId
        self.sizeExcludedRequestBytes = sizeExcludedRequestBytes
        self.unsupported = unsupported
    }

    /// true when every component the asset has is known to exist server-side.
    var isBackedUp: Bool {
        verificationState == .verified && proof?.matches(self) == true
    }

    func hasSameResources(as other: BackupEntry) -> Bool {
        modificationDate == other.modificationDate && isLivePhoto == other.isLivePhoto
            && primaryChecksum == other.primaryChecksum && motionChecksum == other.motionChecksum
    }

    func isSizeExcluded(maximumRequestBytes: Int64?) -> Bool {
        guard !isBackedUp, let maximumRequestBytes, let sizeExcludedRequestBytes else { return false }
        return sizeExcludedRequestBytes > maximumRequestBytes
    }

    /// unchanged only when both dates are equal, including both nil.
    func matches(modificationDate date: Date?) -> Bool {
        modificationDate == date
    }
}

nonisolated struct PendingStack: Sendable {
    let localId: String
    let primaryRemoteId: String
    let previousRemoteId: String
}

/// everything the backup manager publishes about pairings, built in one pass
/// inside the actor so the main actor only ever assigns finished maps.
nonisolated struct BackupIndexSnapshot: Sendable {
    /// every verified pairing, edited server copies included.
    let localByRemote: [String: String]
    /// inverse of the complete pairing map.
    let remoteByLocal: [String: String]
    /// pairings safe to render from the device.
    let renderableLocalByRemote: [String: String]
    /// remote ids of assets that exist on this device and are fully backed up.
    let backedUpRemoteIds: Set<String>
    /// local identifiers whose complete asset, including Live Photo motion,
    /// has a verified server copy.
    let backedUpLocalRevisions: [String: Date?]
    /// local files that exceeded the configured multipart request limit.
    let sizeExcludedRequestBytesByLocal: [String: Int64]
}

/// account-scoped map of device assets to their server backup state, persisted as json.
/// an actor so map mutations and file writes are serialized off the main actor.
actor BackupIndex {
    nonisolated struct Snapshot: Codable {
        var serverHost: String
        var userId: String
        var entries: [String: BackupEntry]
        /// optional so snapshots written before edit tracking still decode.
        var editedRemoteIds: [String]?
        /// optional for migration from snapshots without a backlog boundary.
        var backlogCheckpoint: Date?
    }

    private nonisolated let evidenceEpoch = Mutex<UInt64>(0)
    nonisolated var evidenceVersion: UInt64 { evidenceEpoch.withLock { $0 } }

    private var fileURL: URL
    private let usesAccountFiles: Bool
    private var serverHost = ""
    private var userId = ""
    private var generation: UUID?
    private var entries: [String: BackupEntry] = [:]
    private var remoteToLocal: [String: String] = [:]
    /// server copies that were edited after upload. the pairing stays - a
    /// delete still has to cascade to the device - but the device bytes are no
    /// longer what the server shows, so they must not be rendered.
    private var editedRemoteIds: Set<String> = []
    private var backlogCheckpoint: Date?
    private var loaded = false
    private var dirty = false
    /// the shared pre-account snapshot was migrated and goes once its copy is on disk.
    private var removesLegacySnapshot = false
    private var flushTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? BackupIndex.defaultFileURL
        self.usesAccountFiles = fileURL == nil
    }

    private func accountFileURL(serverHost: String, userId: String) -> URL {
        let key = SHA256.hash(data: Data("\(serverHost)|\(userId)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Self.defaultFileURL.deletingLastPathComponent()
            .appending(path: "backup-index/\(key).json")
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/backup-index.json")
    }

    /// reads the snapshot from disk. a snapshot written for a different server or
    /// user is discarded - accounts must never share local-to-remote mappings.
    @discardableResult
    func load(serverHost: String, userId: String, generation: UUID? = nil) -> Bool {
        if loaded, serverHost == self.serverHost, userId == self.userId {
            if self.generation != generation {
                self.generation = generation
                invalidateProofs()
            }
            return true
        }
        guard flush() else { return false }
        evidenceEpoch.withLock { $0 &+= 1 }
        if usesAccountFiles { fileURL = accountFileURL(serverHost: serverHost, userId: userId) }
        self.serverHost = serverHost
        self.userId = userId
        self.generation = generation
        entries = [:]
        remoteToLocal = [:]
        editedRemoteIds = []
        backlogCheckpoint = nil
        loaded = false
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            // migrate the old shared snapshot only for its own account. keep
            // each account in a separate file so a late logout flush cannot
            // overwrite the newly signed-in account's state.
            guard usesAccountFiles else { loaded = true; return true }
            do {
                let host = URL(string: serverHost)?.host() ?? serverHost
                let legacyFile = accountFileURL(serverHost: host, userId: userId)
                let source = FileManager.default.fileExists(atPath: legacyFile.path) ? legacyFile : Self.defaultFileURL
                let legacy = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: source))
                guard [serverHost, host].contains(legacy.serverHost), legacy.userId == userId else {
                    loaded = true
                    return true
                }
                snapshot = legacy
                dirty = true
                removesLegacySnapshot = source == Self.defaultFileURL
            } catch CocoaError.fileReadNoSuchFile {
                loaded = true
                return true
            } catch { return false }
        } catch {
            // locked, unreadable or malformed is not an empty library. retry
            // later without overwriting the existing account's snapshot.
            return false
        }
        loaded = true
        let legacyHost = URL(string: serverHost)?.host() ?? serverHost
        guard [serverHost, legacyHost].contains(snapshot.serverHost), snapshot.userId == userId else { return true }
        entries = snapshot.entries
        // A saved proof belongs to the session that observed it. Checksums and
        // candidate IDs survive launch; current completion does not.
        invalidateProofs()
        for id in Array(entries.keys) { entries[id]?.pairRepairDenied = nil }
        backlogCheckpoint = snapshot.backlogCheckpoint
        editedRemoteIds = Set(snapshot.editedRemoteIds ?? [])
        for (localId, entry) in entries {
            if let remoteId = entry.primaryRemoteId {
                remoteToLocal[remoteId] = localId
            }
        }
        return true
    }

    @discardableResult
    func flush() -> Bool {
        flushTask?.cancel()
        flushTask = nil
        guard dirty else { return true }
        guard loaded else { return false }
        let snapshot = Snapshot(
            serverHost: serverHost,
            userId: userId,
            entries: entries,
            editedRemoteIds: editedRemoteIds.isEmpty ? nil : Array(editedRemoteIds),
            backlogCheckpoint: backlogCheckpoint
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dirty = false
            if removesLegacySnapshot {
                removesLegacySnapshot = false
                try? FileManager.default.removeItem(at: Self.defaultFileURL)
            }
            return true
        } catch {
            return false
        }
    }

    /// keep the same boundary across interrupted runs. only a fully reconciled
    /// snapshot may advance it; otherwise recent photos would become backlog
    /// after every launch. save before starting resource work.
    func ensureBacklogCheckpoint(at date: Date) -> Date {
        if let backlogCheckpoint { return backlogCheckpoint }
        backlogCheckpoint = date
        markDirty()
        flush()
        return date
    }

    func advanceBacklogCheckpoint(to date: Date, completed assets: [DeviceAsset],
                                  maximumRequestBytes: Int64? = nil) {
        guard assets.allSatisfy({ asset in
            guard let entry = entries[asset.localIdentifier],
                  entry.matches(modificationDate: asset.modificationDate) else { return false }
            return entry.isBackedUp || entry.unsupported
                || entry.isSizeExcluded(maximumRequestBytes: maximumRequestBytes)
        }) else { return }
        guard backlogCheckpoint.map({ date > $0 }) ?? true else { return }
        backlogCheckpoint = date
        markDirty()
        flush()
    }

    private func markDirty() {
        // Synchronous PhotoKit commit guards can observe every index mutation.
        evidenceEpoch.withLock { $0 &+= 1 }
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            flushTask = nil
            flush()
        }
    }

    func entry(for localId: String) -> BackupEntry? {
        entries[localId]
    }

    func libraryStatus(for assets: [DeviceAsset], excludeScreenshots: Bool = false) -> BackupLibraryStatus {
        BackupLibraryStatus(assets: assets, entries: entries, excludeScreenshots: excludeScreenshots)
    }

    func allEntries() -> [String: BackupEntry] {
        entries
    }

    func invalidateProofs(localIds: Set<String>? = nil) {
        for id in Array(entries.keys) where localIds == nil || localIds!.contains(id) {
            guard var entry = entries[id] else { continue }
            entry.proof = nil
            entry.verificationState = .pending
            entry.verificationRevision = (entry.verificationRevision ?? 0) &+ 1
            entries[id] = entry
        }
        if !entries.isEmpty { markDirty() }
    }

    func recordProof(localId: String, source: BackupEntry, proof: BackupProof) -> Bool {
        guard generation == proof.generation, proof.account == "\(serverHost)|\(userId)", proof.primary.ownerID == userId,
              let entry = entries[localId], entry.hasSameResources(as: source),
              entry.verificationRevision == source.verificationRevision, proof.matches(entry)
        else { return false }
        entries[localId]?.proof = proof
        entries[localId]?.verificationState = .verified
        entries[localId]?.lastVerifiedAt = proof.verifiedAt
        entries[localId]?.pairRepairDenied = nil
        entries[localId]?.sizeExcludedRequestBytes = nil
        markDirty()
        return true
    }

    func recordVerificationFailure(localId: String, source: BackupEntry, generation: UUID, state: BackupVerificationState) {
        guard self.generation == generation, entries[localId]?.hasSameResources(as: source) == true,
              entries[localId]?.verificationRevision == source.verificationRevision else { return }
        entries[localId]?.proof = nil
        entries[localId]?.verificationState = state
        if state == .pairPermissionDenied { entries[localId]?.pairRepairDenied = true }
        markDirty()
    }

    func applyRemoteCheck(localId: String, source: BackupEntry, result: BulkUploadCheckResult, motion: Bool, generation: UUID) {
        guard self.generation == generation, entries[localId]?.hasSameResources(as: source) == true,
              entries[localId]?.verificationRevision == source.verificationRevision else { return }
        let wasTrashed = entries[localId]?.verificationState == .trashed
        if result.isConfirmedDuplicate, let id = result.assetId {
            if motion { setMotionRemoteId(localId: localId, id) }
            else { setPrimaryRemoteId(localId: localId, id) }
            if result.isTrashed == true { entries[localId]?.verificationState = .trashed }
        } else if result.action == "accept" {
            if motion { clearMotionRemoteId(localId: localId) }
            else { clearPrimaryRemoteId(localId: localId) }
            entries[localId]?.verificationState = .missing
        } else if result.isUnsupported { markUnsupported(localId: localId) }
        if wasTrashed { entries[localId]?.verificationState = .trashed }
    }

    func clearMissingComponent(localId: String, source: BackupEntry, remoteID: String, generation: UUID) {
        guard self.generation == generation, let entry = entries[localId], entry.hasSameResources(as: source),
              entry.verificationRevision == source.verificationRevision else { return }
        if entry.primaryRemoteId == remoteID { clearPrimaryRemoteId(localId: localId) }
        if entry.motionRemoteId == remoteID { clearMotionRemoteId(localId: localId) }
    }

    func noteRemoteChange(ids: Set<String>, change: BackupRemoteChange, generation: UUID) {
        guard self.generation == generation, change != .hidden else { return }
        for localID in Array(entries.keys) {
            guard let entry = entries[localID],
                  entry.primaryRemoteId.map(ids.contains) == true || entry.motionRemoteId.map(ids.contains) == true else { continue }
            entries[localID]?.proof = nil
            entries[localID]?.verificationRevision = (entry.verificationRevision ?? 0) &+ 1
            switch change {
            case .deleted:
                if let id = entry.primaryRemoteId, ids.contains(id) { clearPrimaryRemoteId(localId: localID) }
                if let id = entry.motionRemoteId, ids.contains(id) { clearMotionRemoteId(localId: localID) }
            case .trashed: entries[localID]?.verificationState = .trashed
            case .restored: entries[localID]?.verificationState = .pending
            case .hidden: break
            }
            markDirty()
        }
    }

    /// records fresh checksums. remote ids survive only when the matching checksum
    /// is unchanged - different bytes on device mean the server copy is stale proof.
    func setHashed(
        localId: String,
        isLivePhoto: Bool,
        primaryChecksum: String,
        motionChecksum: String?,
        modificationDate: Date?,
        primaryByteCount: Int64? = nil,
        motionByteCount: Int64? = nil
    ) {
        let old = entries[localId]
        var entry = BackupEntry(
            modificationDate: modificationDate,
            isLivePhoto: isLivePhoto,
            primaryChecksum: primaryChecksum,
            motionChecksum: motionChecksum
        )
        entry.verificationRevision = (old?.verificationRevision ?? 0) &+ 1
        entry.primaryByteCount = primaryByteCount ?? (old?.primaryChecksum == primaryChecksum ? old?.primaryByteCount : nil)
        entry.motionByteCount = motionByteCount ?? (old?.motionChecksum == motionChecksum ? old?.motionByteCount : nil)
        if let old {
            if old.primaryChecksum == primaryChecksum {
                entry.primaryRemoteId = old.primaryRemoteId
                entry.unsupported = old.unsupported
                entry.stackOntoRemoteId = old.stackOntoRemoteId
            } else {
                if let stale = old.primaryRemoteId {
                    remoteToLocal[stale] = nil
                }
                // a second edit before the first one uploaded still stacks
                // onto the last revision the server has.
                entry.stackOntoRemoteId = old.primaryRemoteId ?? old.stackOntoRemoteId
            }
            if old.motionChecksum == motionChecksum {
                entry.motionRemoteId = old.motionRemoteId
            }
        }
        entries[localId] = entry
        if let remoteId = entry.primaryRemoteId {
            remoteToLocal[remoteId] = localId
        }
        markDirty()
    }

    func setPrimaryRemoteId(localId: String, _ remoteId: String) {
        guard var entry = entries[localId] else { return }
        if let stale = entry.primaryRemoteId {
            remoteToLocal[stale] = nil
        }
        entry.primaryRemoteId = remoteId
        entry.proof = nil
        entry.verificationState = .pending
        if entry.isBackedUp { entry.sizeExcludedRequestBytes = nil }
        entries[localId] = entry
        remoteToLocal[remoteId] = localId
        markDirty()
    }

    /// a receipt can restore a lost/coalesced hash entry, but may never attach
    /// an older upload to newer bytes. caller verifies the PhotoKit revision.
    /// `persist: false` leaves the write to the debounced flush, for callers
    /// that commit a whole batch at once or keep their receipt journaled.
    func applyReceipt(_ receipt: BackgroundUploader.Completion, persist: Bool = true) -> Bool {
        guard loaded, let source = receipt.ticket.source else { return false }
        let localId = receipt.ticket.localId
        if let current = entries[localId] {
            guard current.modificationDate == source.modificationDate,
                  current.isLivePhoto == source.isLivePhoto,
                  current.primaryChecksum == source.primaryChecksum,
                  current.motionChecksum == source.motionChecksum else { return true }
        } else {
            entries[localId] = source
            if let remoteId = source.primaryRemoteId { remoteToLocal[remoteId] = localId }
        }
        if receipt.ticket.isMotion {
            setMotionRemoteId(localId: localId, receipt.remoteId)
        } else {
            setPrimaryRemoteId(localId: localId, receipt.remoteId)
        }
        return persist ? flush() : true
    }

    /// uploaded edits whose previous revision still has to go under them.
    /// an edit that turned out to be the same server asset settles here.
    func pendingStacks() -> [PendingStack] {
        var pending: [PendingStack] = []
        for (localId, entry) in entries {
            guard let previous = entry.stackOntoRemoteId, let primary = entry.primaryRemoteId else { continue }
            if primary == previous {
                entries[localId]?.stackOntoRemoteId = nil
                markDirty()
            } else {
                pending.append(PendingStack(localId: localId, primaryRemoteId: primary, previousRemoteId: previous))
            }
        }
        return pending
    }

    /// only clears when the entry still waits on the same pair, a newer edit
    /// may have replaced it while the request ran.
    func settleStack(_ stack: PendingStack) {
        guard let entry = entries[stack.localId],
              entry.primaryRemoteId == stack.primaryRemoteId,
              entry.stackOntoRemoteId == stack.previousRemoteId else { return }
        entries[stack.localId]?.stackOntoRemoteId = nil
        markDirty()
    }

    func clearPrimaryRemoteId(localId: String) {
        guard var entry = entries[localId] else { return }
        if let stale = entry.primaryRemoteId {
            remoteToLocal[stale] = nil
        }
        entry.primaryRemoteId = nil
        entry.proof = nil
        entry.verificationState = .missing
        entries[localId] = entry
        markDirty()
    }

    func setMotionRemoteId(localId: String, _ remoteId: String) {
        guard var entry = entries[localId] else { return }
        entry.motionRemoteId = remoteId
        entry.proof = nil
        entry.verificationState = .pending
        if entry.isBackedUp { entry.sizeExcludedRequestBytes = nil }
        entries[localId] = entry
        markDirty()
    }

    func markSizeExcluded(localId: String, revision: Date?, requestBytes: Int64) {
        guard var entry = entries[localId], entry.matches(modificationDate: revision),
              !entry.isBackedUp, requestBytes > 0 else { return }
        entry.sizeExcludedRequestBytes = requestBytes
        entries[localId] = entry
        markDirty()
    }

    func clearMotionRemoteId(localId: String) {
        guard var entry = entries[localId] else { return }
        entry.motionRemoteId = nil
        entry.proof = nil
        entry.verificationState = .missing
        entries[localId] = entry
        markDirty()
    }

    func markUnsupported(localId: String) {
        guard var entry = entries[localId] else { return }
        entry.unsupported = true
        entries[localId] = entry
        markDirty()
    }

    func remove(ids: [String]) {
        var changed = false
        for localId in ids {
            guard let entry = entries.removeValue(forKey: localId) else { continue }
            if let remoteId = entry.primaryRemoteId {
                remoteToLocal[remoteId] = nil
            }
            changed = true
        }
        if changed { markDirty() }
    }

    /// drops entries for assets no longer on the device. only ever called after a
    /// full-access scan - a limited scan hides assets and would erase valid state.
    func prune(keeping localIds: Set<String>) {
        let gone = entries.keys.filter { !localIds.contains($0) }
        remove(ids: gone)
    }

    func localId(forRemote remoteId: String) -> String? {
        remoteToLocal[remoteId]
    }

    /// remote-to-device pairing snapshot so tiles can reuse the device
    /// thumbnail as an instant placeholder for their server twin.
    func remoteToLocalMap() -> [String: String] {
        remoteToLocal
    }

    /// pairings safe to render from the device: everything the server has not
    /// repainted since the upload.
    func renderableRemoteToLocalMap() -> [String: String] {
        guard !editedRemoteIds.isEmpty else { return remoteToLocal }
        return remoteToLocal.filter { !editedRemoteIds.contains($0.key) }
    }

    /// server-side edit landed: the device copy still exists and still has to
    /// be deleted along with the server one, it just no longer looks like it.
    /// returns true when this is news, so the caller can refresh and save.
    func markRemoteEdited(_ remoteIds: Set<String>) -> Bool {
        let known = remoteIds.filter { remoteToLocal[$0] != nil }
        guard !known.isSubset(of: editedRemoteIds) else { return false }
        editedRemoteIds.formUnion(known)
        markDirty()
        return true
    }

    /// remote ids of assets that exist on this device and are fully backed
    /// up. drives the merged cloud badge on timeline tiles.
    func backedUpRemoteIds() -> Set<String> {
        var ids: Set<String> = []
        ids.reserveCapacity(entries.count)
        for entry in entries.values where entry.isBackedUp {
            if let remoteId = entry.primaryRemoteId {
                ids.insert(remoteId)
            }
        }
        return ids
    }

    func localSnapshot() -> BackupIndexSnapshot {
        var remoteByLocal: [String: String] = [:]
        remoteByLocal.reserveCapacity(remoteToLocal.count)
        for (remoteId, localId) in remoteToLocal {
            remoteByLocal[localId] = remoteId
        }
        var backedUpLocalRevisions: [String: Date?] = [:]
        var sizeExcludedRequestBytesByLocal: [String: Int64] = [:]
        for (localId, entry) in entries where entry.isBackedUp {
            backedUpLocalRevisions.updateValue(entry.modificationDate, forKey: localId)
        }
        for (localId, entry) in entries where !entry.isBackedUp {
            if let requestBytes = entry.sizeExcludedRequestBytes {
                sizeExcludedRequestBytesByLocal[localId] = requestBytes
            }
        }
        return BackupIndexSnapshot(
            localByRemote: remoteToLocal,
            remoteByLocal: remoteByLocal,
            renderableLocalByRemote: renderableRemoteToLocalMap(),
            backedUpRemoteIds: backedUpRemoteIds(),
            backedUpLocalRevisions: backedUpLocalRevisions,
            sizeExcludedRequestBytesByLocal: sizeExcludedRequestBytesByLocal
        )
    }
}
