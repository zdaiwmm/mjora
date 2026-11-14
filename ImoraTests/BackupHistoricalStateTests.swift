import XCTest
@testable import Imora

final class BackupHistoricalStateTests: XCTestCase, @unchecked Sendable {
    func testRemoteChangeInvalidatesProofAlreadyBeingVerifiedFromPendingEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json")), generation = UUID()
        _ = await index.load(serverHost: "server", userId: "owner", generation: generation)
        let asset = fixtureDevice()
        await index.setHashed(localId: asset.localIdentifier, isLivePhoto: false, primaryChecksum: "still-sha1", motionChecksum: nil,
            modificationDate: asset.modificationDate)
        await index.setPrimaryRemoteId(localId: asset.localIdentifier, "still")
        let candidate = await index.entry(for: asset.localIdentifier)
        let source = try XCTUnwrap(candidate)
        let proof = try await BackupVerifier.verify(asset: asset, entry: source, ownerID: "owner", account: "server|owner",
            generation: generation, remote: FixtureBackupRemote([fixtureRemote()]), current: { true })
        try await index.applySyncOperations([.invalidate("still")], scope: .init(serverIdentity: "server", accountID: "owner", loginSessionKey: "session"), generation: generation)
        let recorded = await index.recordProof(localId: asset.localIdentifier, source: source, proof: proof)
        XCTAssertFalse(recorded, "An in-flight proof must not outrank a newer authoritative remote change")
    }

    func testColdLaunchRetainsDisplayHistoryWithoutProofOrCleanupAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json"), generation = UUID()
        let index = BackupIndex(fileURL: file)
        _ = await index.load(serverHost: "server", userId: "owner", generation: generation)
        await index.setHashed(localId: "local", isLivePhoto: false, primaryChecksum: "checksum", motionChecksum: nil,
            modificationDate: Date(timeIntervalSince1970: 100))
        await index.setPrimaryRemoteId(localId: "local", "remote")
        await index.markHistoricallyPresent(localIDs: ["local"])
        let flushed = await index.flush()
        XCTAssertTrue(flushed)
        let cold = BackupIndex(fileURL: file)
        _ = await cold.load(serverHost: "server", userId: "owner", generation: UUID())
        let entry = await cold.entry(for: "local")
        XCTAssertEqual(entry?.hasHistoricalBackup, true)
        XCTAssertEqual(entry?.isBackedUp, false)
        XCTAssertNil(entry?.proof)
        let snapshot = await cold.localSnapshot()
        XCTAssertEqual(snapshot.backedUpRemoteIds, ["remote"])
    }

    func testRoutineRecheckPolicyRequiresKnownUnchangedRevisionAndNoRemovalOrFailure() {
        let asset = fixtureDevice()
        var entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: false, primaryChecksum: "checksum")
        entry.verificationState = .pending // cold-launch proof invalidation is not new evidence of a change.
        XCTAssertTrue(BackupRoutineRecheckPolicy.hasUnchangedRevision(asset: asset, entry: entry))
        XCTAssertFalse(BackupRoutineRecheckPolicy.hasUnchangedRevision(asset: fixtureDevice(modified: nil), entry: entry))
        XCTAssertFalse(BackupRoutineRecheckPolicy.hasUnchangedRevision(asset: fixtureDevice(modified: Date()), entry: entry))
        for state in [BackupVerificationState.offline, .failed, .pairPending] {
            entry.verificationState = state
            XCTAssertFalse(BackupRoutineRecheckPolicy.hasUnchangedRevision(asset: asset, entry: entry))
        }
        entry.verificationState = .pending
        entry.remoteDeletionDetected = true
        XCTAssertFalse(BackupRoutineRecheckPolicy.hasUnchangedRevision(asset: asset, entry: entry))
    }

    func testRemovedPairIsAbsentFromDisplayMapsAndExplicitRebackupFlushesBeforeUnlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json"), generation = UUID()
        let index = BackupIndex(fileURL: file)
        _ = await index.load(serverHost: "server", userId: "owner", generation: generation)
        await index.setHashed(localId: "local", isLivePhoto: false, primaryChecksum: "checksum", motionChecksum: nil,
            modificationDate: Date(timeIntervalSince1970: 100))
        await index.setPrimaryRemoteId(localId: "local", "remote")
        await index.markHistoricallyPresent(localIDs: ["local"])
        await index.noteRemoteChange(ids: ["remote"], change: .trashed, generation: generation)
        let removed = await index.localSnapshot()
        XCTAssertTrue(removed.localByRemote.isEmpty)
        XCTAssertTrue(removed.renderableLocalByRemote.isEmpty)
        XCTAssertTrue(removed.backedUpRemoteIds.isEmpty)
        try await index.prepareForExplicitRebackup(localID: "local", generation: generation)
        let cold = BackupIndex(fileURL: file)
        _ = await cold.load(serverHost: "server", userId: "owner", generation: UUID())
        let entry = await cold.entry(for: "local")
        XCTAssertEqual(entry?.isUploadBlockedByRemoteRemoval, false)
        XCTAssertNil(entry?.primaryRemoteId)
        XCTAssertEqual(entry?.hasHistoricalBackup, false)
    }
}

extension BackupHistoricalStateTests {
    func testCorruptJSONAndSQLiteHistoryFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appending(path: "index.json"), sqlite = directory.appending(path: "sync.sqlite")
        try Data("corrupt-history".utf8).write(to: json)
        try Data("corrupt-history".utf8).write(to: sqlite)
        let loaded = await BackupIndex(fileURL: json).load(serverHost: "server", userId: "owner", generation: UUID())
        XCTAssertFalse(loaded)
        XCTAssertThrowsError(try SyncStateStore(fileURL: sqlite))
    }
}

extension BackupHistoricalStateTests {
    func testFailedJSONRebackupWriteRestoresInMemoryRemovalProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json"), generation = UUID()
        let index = BackupIndex(fileURL: file)
        _ = await index.load(serverHost: "server", userId: "owner", generation: generation)
        await index.setHashed(localId: "local", isLivePhoto: false, primaryChecksum: "checksum", motionChecksum: nil, modificationDate: nil)
        await index.setPrimaryRemoteId(localId: "local", "retired")
        await index.noteRemoteChange(ids: ["retired"], change: .trashed, generation: generation)
        let flushed = await index.flush(); XCTAssertTrue(flushed)
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await index.prepareForExplicitRebackup(localID: "local", generation: generation); XCTFail() }
        catch RemoteSyncError.indexFlushFailed {}
        let protected = await index.entry(for: "local")
        XCTAssertEqual(protected?.isUploadBlockedByRemoteRemoval, true)
        XCTAssertEqual(protected?.primaryRemoteId, "retired")
        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
    }
}
