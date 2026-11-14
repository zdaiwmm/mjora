import XCTest
import Synchronization
@testable import Imora

private let stillDigest = ResourceDigest(checksum: "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=", byteCount: 3)
private let motionDigest = ResourceDigest(checksum: "WJwiM1o4HxItEpIl9cC6MFbtWBE=", byteCount: 3)

actor CleanupFixtureLibrary: CleanupPhotoLibrary {
    enum DeletionMode: Sendable { case success, cancel, fail, partial }
    var permission = true
    var values: [DeviceAsset]
    var fetchOverride: [DeviceAsset]?
    let mode: DeletionMode
    var invalidHash = false
    var onHash: (@Sendable () -> Void)?
    var protectedIDs: Set<String> = []
    private(set) var deleted: [String] = []
    private(set) var hashCount = 0

    init(_ assets: [DeviceAsset], fetchOverride: [DeviceAsset]? = nil, mode: DeletionMode = .success) {
        values = assets; self.fetchOverride = fetchOverride; self.mode = mode
    }
    func hasFullAccess() async -> Bool { permission }
    func protectedAlbumMemberIDs(_ albumIDs: Set<String>) async throws -> Set<String> { protectedIDs }
    func protect(_ ids: Set<String>) { protectedIDs = ids }
    func assets(ids: [String]) async throws -> [DeviceAsset] { fetchOverride ?? values.filter { ids.contains($0.localIdentifier) } }
    func hashes(for asset: DeviceAsset) async throws -> LocalResourceHashes {
        hashCount += 1
        onHash?()
        return LocalResourceHashes(primaryDigest: invalidHash ? motionDigest : stillDigest, motionDigest: asset.isLivePhoto ? motionDigest : nil)
    }
    func delete(_ assets: [DeviceAsset], permitted: @escaping @Sendable () -> Bool) async throws -> [String] {
        guard permission, permitted() else { throw CleanupVerificationError.changed }
        switch mode {
        case .cancel: throw CancellationError()
        case .fail: throw CocoaError(.fileWriteUnknown)
        case .partial: deleted = Array(assets.prefix(1).map(\.localIdentifier))
        case .success: deleted = assets.map(\.localIdentifier)
        }
        return deleted
    }
    func changeAssets(_ value: [DeviceAsset]) { values = value }
    func denyPermission() { permission = false }
    func useInvalidHash() { invalidHash = true }
    func afterHash(_ operation: @escaping @Sendable () -> Void) { onHash = operation }
}

actor CleanupFixtureRemote: CleanupRemoteAPI {
    var values: [String: BackupRemoteAsset]
    var originals: [String: ResourceDigest]
    var hook: (@Sendable (Int) async -> Void)?
    var stage = 0
    private(set) var readIDs: [String] = []
    private(set) var repairs = 0
    var trashAfterRead = false
    var bulkMode = 0

    init(_ assets: [BackupRemoteAsset], originals: [String: ResourceDigest] = ["still": stillDigest, "motion": motionDigest]) {
        values = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }); self.originals = originals
    }
    private func boundary() async { stage += 1; await hook?(stage) }
    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset {
        await boundary()
        guard let value = values[id] else { throw ImoraError.http(404, "fixture missing") }
        return value
    }
    func bulkUploadCheck(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        await boundary()
        let rows = items.map { item in
            BulkUploadCheckResult(id: item.id, action: "reject", reason: "duplicate", assetId: item.checksum == stillDigest.checksum ? "still" : "motion", isTrashed: false)
        }
        switch bulkMode {
        case 1: return Array(rows.dropLast())
        case 2: return rows + rows
        case 3: return [BulkUploadCheckResult(id: "unknown", action: "reject", reason: "duplicate", assetId: "still", isTrashed: false)]
        case 4: return items.map { BulkUploadCheckResult(id: $0.id, action: "reject", reason: "duplicate", assetId: "unexpected", isTrashed: false) }
        default: return rows
        }
    }
    func invalidBulk(_ mode: Int) { bulkMode = mode }
    func repairLivePhoto(stillID: String, videoID: String) async throws {
        repairs += 1
        throw BackupVerificationError.component(stillID, .pairPending)
    }
    func readbackOriginal(assetID: String, expected: ResourceDigest) async throws -> ResourceDigest {
        await boundary()
        readIDs.append(assetID)
        if trashAfterRead { values[assetID]?.isTrashed = true }
        guard let value = originals[assetID] else { throw ImoraError.http(404, "fixture original missing") }
        return value
    }
    func onCall(_ callback: @escaping @Sendable (Int) async -> Void) { hook = callback }
    func trashOnRead() { trashAfterRead = true }
}

final class CleanupVerificationTests: XCTestCase {
    private let account = "https://fixture.invalid/api|owner"
    private let generation = UUID()

    private func report(assets: [DeviceAsset], knownSizes: Bool = false, expiresAt: Date? = nil,
                        retention: CleanupRetentionSnapshot? = nil) async throws -> CleanupReport {
        var candidates: [CleanupCandidate] = []
        for asset in assets {
            var entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: asset.isLivePhoto,
                                    primaryChecksum: stillDigest.checksum, primaryRemoteId: "still",
                                    motionChecksum: asset.isLivePhoto ? motionDigest.checksum : nil, motionRemoteId: asset.isLivePhoto ? "motion" : nil)
            if knownSizes { entry.primaryByteCount = 3; entry.motionByteCount = asset.isLivePhoto ? 3 : nil }
            let proof = try await BackupVerifier.verify(asset: asset, entry: entry, ownerID: "owner", account: account, generation: generation,
                                                       remote: FixtureBackupRemote(remoteAssets(live: asset.isLivePhoto)), current: { true })
            candidates.append(CleanupCandidate(source: entry, proof: proof))
        }
        return CleanupReport(account: account, generation: generation, candidates: candidates, keptMedia: MediaCounts(), route: URL(string: "http://127.0.0.1:32283/api")!, expiresAt: expiresAt, retention: retention)
    }

    func testAlbumProtectionAddedAfterPreviewStopsDeletion() async throws {
        let asset = fixtureDevice()
        let snapshot = CleanupRetentionPolicy(retentionDays: nil, protectedAlbumIDs: ["protected"]).snapshot()
        let report = try await report(assets: [asset], retention: snapshot)
        let library = CleanupFixtureLibrary([asset])
        let remote = CleanupFixtureRemote(remoteAssets(live: false))
        await remote.onCall { stage in
            if stage == 3 { await library.protect([asset.localIdentifier]) }
        }
        do {
            _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation,
                library: library, remote: remote, isCurrent: { true })
            XCTFail("A newly protected album member was removed")
        } catch CleanupVerificationError.changed {
        } catch BackupVerificationError.stale {}
        let deleted = await library.deleted
        XCTAssertTrue(deleted.isEmpty)
    }

    private func remoteAssets(live: Bool) -> [BackupRemoteAsset] {
        var values = [fixtureRemote(checksum: stillDigest.checksum, link: live ? "motion" : nil)]
        if live { values.append(fixtureRemote("motion", checksum: motionDigest.checksum, type: "VIDEO")) }
        return values
    }

    func testLivePhotoRequiresReadingBothOriginalComponentsBeforeDeletion() async throws {
        let asset = fixtureDevice(live: true)
        let report = try await report(assets: [asset])
        let library = CleanupFixtureLibrary([asset])
        let remote = CleanupFixtureRemote(remoteAssets(live: true))
        let result = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true })
        XCTAssertEqual(result.deletedIDs, [asset.localIdentifier])
        XCTAssertEqual(result.deletedMedia.total, 1)
        let reads = await remote.readIDs
        XCTAssertEqual(reads, ["still", "motion"])
    }

    func testMissingCorruptOrShortMotionOriginalPreventsAllDeletion() async throws {
        let asset = fixtureDevice(live: true)
        for original in [nil, stillDigest, ResourceDigest(checksum: motionDigest.checksum, byteCount: 2)] as [ResourceDigest?] {
            let report = try await report(assets: [asset])
            let library = CleanupFixtureLibrary([asset])
            var originals = ["still": stillDigest]
            originals["motion"] = original
            let remote = CleanupFixtureRemote(remoteAssets(live: true), originals: originals)
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true }); XCTFail("bad motion allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testExpiredReportOrDifferentAccountCannotStartDeletion() async throws {
        let asset = fixtureDevice()
        let expired = try await report(assets: [asset], expiresAt: Date(timeIntervalSince1970: 0))
        let valid = try await report(assets: [asset])
        for (report, expectedAccount, expectedGeneration) in [(expired, account, generation), (valid, "other", generation), (valid, account, UUID())] {
            let library = CleanupFixtureLibrary([asset])
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            do { _ = try await CleanupVerifier.perform(report: report, account: expectedAccount, generation: expectedGeneration, library: library, remote: remote, isCurrent: { true }); XCTFail("invalid report allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testMissingDuplicateUnknownOrUnexpectedBulkRowsNeverPermitCleanup() async throws {
        let asset = fixtureDevice()
        let report = try await report(assets: [asset])
        for mode in 1...4 {
            let library = CleanupFixtureLibrary([asset])
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            await remote.invalidBulk(mode)
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true }); XCTFail("invalid bulk response allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testZeroPartialDuplicateOrEditedPhotosFetchRequiresNewReport() async throws {
        let a = fixtureDevice(id: "a"), b = fixtureDevice(id: "b")
        let report = try await report(assets: [a, b])
        for fetch in [[], [a], [a, a], [a, fixtureDevice(id: "b", modified: Date(timeIntervalSince1970: 200))]] {
            let library = CleanupFixtureLibrary([a, b], fetchOverride: fetch)
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true }); XCTFail("changed Photos set allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testAccountChangeAtEveryNetworkBoundaryPreventsDeletion() async throws {
        let asset = fixtureDevice(live: true)
        for boundary in 1...7 {
            let active = Mutex(true)
            let report = try await report(assets: [asset])
            let library = CleanupFixtureLibrary([asset])
            let remote = CleanupFixtureRemote(remoteAssets(live: true))
            await remote.onCall { stage in if stage == boundary { active.withLock { $0 = false } } }
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { active.withLock { $0 } }); XCTFail("changed account allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testEditOrServerTrashAfterOriginalReadPreventsDeletion() async throws {
        let asset = fixtureDevice()
        for trash in [true, false] {
            let report = try await report(assets: [asset])
            let library = CleanupFixtureLibrary([asset])
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            if trash { await remote.trashOnRead() }
            else { await remote.onCall { stage in if stage == 3 { await library.changeAssets([fixtureDevice(modified: Date(timeIntervalSince1970: 200))]) } } }
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true }); XCTFail("changed evidence allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testCancellationFailureAndActualDeletedCountArePreserved() async throws {
        let a = fixtureDevice(id: "a"), b = fixtureDevice(id: "b")
        let report = try await report(assets: [a, b])
        for mode in [CleanupFixtureLibrary.DeletionMode.cancel, .fail] {
            let library = CleanupFixtureLibrary([a, b], mode: mode)
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true }); XCTFail("failed deletion reported success") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
        let library = CleanupFixtureLibrary([a, b], mode: .partial)
        let result = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true })
        XCTAssertEqual(result.deletedIDs, ["a"])
        XCTAssertEqual(result.deletedMedia.total, 1)
        XCTAssertEqual(result.keptMedia.total, 1)
    }

    func testKnownRevisionAndByteCountAvoidUnnecessaryLocalRehash() async throws {
        let asset = fixtureDevice()
        let report = try await report(assets: [asset], knownSizes: true)
        let library = CleanupFixtureLibrary([asset])
        _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true })
        let hashes = await library.hashCount
        XCTAssertEqual(hashes, 0)
        let unknown = fixtureDevice(modified: nil)
        let unknownReport = try await self.report(assets: [unknown], knownSizes: true)
        let unknownLibrary = CleanupFixtureLibrary([unknown])
        await unknownLibrary.useInvalidHash()
        do { _ = try await CleanupVerifier.perform(report: unknownReport, account: account, generation: generation, library: unknownLibrary, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true }); XCTFail("unknown revision with different bytes deleted") } catch {}
        let deleted = await unknownLibrary.deleted
        XCTAssertTrue(deleted.isEmpty)
    }
}

extension CleanupVerificationTests {
    func testEvidenceInvalidatedDuringFinalRemoteReadsNeverReachesPhotos() async throws {
        for assets in [[fixtureDevice(id: "a")], [fixtureDevice(id: "a"), fixtureDevice(id: "b")]] {
            let report = try await report(assets: assets)
            let library = CleanupFixtureLibrary(assets)
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            let current = Mutex(true)
            let finalBoundary = assets.count == 1 ? 4 : 7
            await remote.onCall { stage in if stage == finalBoundary { current.withLock { $0 = false } } }
            do {
                _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation,
                    library: library, remote: remote, isCurrent: { true },
                    evidenceCurrent: { candidate in candidate.asset.localIdentifier != "a" || current.withLock { $0 } })
                XCTFail("Observed invalidation during the final read authorized deletion")
            } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testPermissionRevocationAndCommitGatePreventDeletion() async throws {
        let asset = fixtureDevice()
        for revokeDuringRead in [false, true] {
            let report = try await report(assets: [asset])
            let library = CleanupFixtureLibrary([asset])
            let remote = CleanupFixtureRemote(remoteAssets(live: false))
            if revokeDuringRead { await remote.onCall { stage in if stage == 3 { await library.denyPermission() } } }
            else { await library.denyPermission() }
            do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: remote, isCurrent: { true }); XCTFail("revoked Photos access allowed deletion") } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
        let report = try await report(assets: [asset])
        let library = CleanupFixtureLibrary([asset])
        do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: library, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true }, canCommit: { false }); XCTFail("commit gate ignored") } catch {}
        let deleted = await library.deleted
        XCTAssertTrue(deleted.isEmpty)
    }

    func testTaskCancellationDuringOriginalBoundaryAndChangedEvidencePreventDeletion() async throws {
        let asset = fixtureDevice()
        let report = try await report(assets: [asset])
        let library = CleanupFixtureLibrary([asset])
        let remote = CleanupFixtureRemote(remoteAssets(live: false))
        await remote.onCall { stage in if stage == 3 { withUnsafeCurrentTask { $0?.cancel() } } }
        let taskAccount = account, taskGeneration = generation
        let operation = Task {
            try await CleanupVerifier.perform(report: report, account: taskAccount, generation: taskGeneration, library: library, remote: remote, isCurrent: { true })
        }
        switch await operation.result {
        case .success: XCTFail("task cancellation allowed deletion")
        case .failure: break
        }
        let deleted = await library.deleted
        XCTAssertTrue(deleted.isEmpty)
        let secondLibrary = CleanupFixtureLibrary([asset])
        do { _ = try await CleanupVerifier.perform(report: report, account: account, generation: generation, library: secondLibrary, remote: CleanupFixtureRemote(remoteAssets(live: false)), isCurrent: { true }, evidenceCurrent: { _ in false }); XCTFail("changed evidence allowed deletion") } catch {}
        let secondDeleted = await secondLibrary.deleted
        XCTAssertTrue(secondDeleted.isEmpty)
    }
}
