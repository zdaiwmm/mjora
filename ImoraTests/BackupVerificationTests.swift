import XCTest
import Synchronization
@testable import Imora

final class BackupVerificationTests: XCTestCase {
    func testLegacyCandidateIDsAreNotVerifiedBackup() throws {
        let json = Data("""
        {"isLivePhoto":true,"primaryChecksum":"still-sha1","primaryRemoteId":"still-id","motionChecksum":"motion-sha1","motionRemoteId":"video-id","unsupported":false}
        """.utf8)
        let entry = try JSONDecoder().decode(BackupEntry.self, from: json)
        XCTAssertFalse(entry.isBackedUp, "two candidate IDs do not prove state or exact pairing")
        XCTAssertEqual(entry.primaryChecksum, "still-sha1")
        XCTAssertEqual(entry.motionRemoteId, "video-id")
    }
}

extension BackupVerificationTests {
    func testOnlyExactRemoteIdentityAndAvailableStateCanProduceProof() async throws {
        let device = fixtureDevice()
        let entry = BackupEntry(modificationDate: device.modificationDate, isLivePhoto: false, primaryChecksum: "still-sha1", primaryRemoteId: "still")
        let valid = fixtureRemote()
        let proof = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: "owner", account: "https://fixture.invalid/api|owner", generation: UUID(), remote: FixtureBackupRemote([valid]), current: { true })
        XCTAssertEqual(proof.primary.remoteID, "still")
        XCTAssertEqual(proof.primary.checksum, "still-sha1")
        var variants: [BackupRemoteAsset] = []
        var wrong = valid; wrong.ownerId = "other"; variants.append(wrong)
        wrong = valid; wrong.type = "VIDEO"; variants.append(wrong)
        wrong = valid; wrong.checksum = "other"; variants.append(wrong)
        wrong = valid; wrong.isTrashed = true; variants.append(wrong)
        wrong = valid; wrong.isOffline = true; variants.append(wrong)
        wrong = valid; wrong.isOffline = nil; variants.append(wrong)
        wrong = valid; wrong.isTrashed = nil; variants.append(wrong)
        for invalid in variants {
            do {
                _ = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: "owner", account: "fixture", generation: UUID(), remote: FixtureBackupRemote([invalid]), current: { true })
                XCTFail("unavailable or mismatched remote asset produced proof")
            } catch {}
        }
    }

    func testBothLivePhotoComponentsAndExactAssociationAreRequired() async throws {
        let device = fixtureDevice(live: true)
        let entry = BackupEntry(modificationDate: device.modificationDate, isLivePhoto: true, primaryChecksum: "still-sha1", primaryRemoteId: "still", motionChecksum: "motion-sha1", motionRemoteId: "motion")
        for link in [nil, "wrong-motion"] as [String?] {
            do {
                _ = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: "owner", account: "fixture", generation: UUID(), remote: FixtureBackupRemote([fixtureRemote(link: link), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]), current: { true })
                XCTFail("unpaired Live Photo produced proof")
            } catch {}
        }
        let proof = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: "owner", account: "fixture", generation: UUID(), remote: FixtureBackupRemote([fixtureRemote(link: "motion"), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]), current: { true })
        XCTAssertEqual(proof.motion?.remoteID, "motion")
        XCTAssertEqual(proof.livePhotoVideoID, "motion")
    }

    func testBulkResultsMustContainExactlyOneKnownRowPerRequest() throws {
        let items = [BulkUploadCheckItem(id: "one", checksum: "still-sha1")]
        let duplicate = BulkUploadCheckResult(id: "one", action: "reject", reason: "duplicate", assetId: "still", isTrashed: false)
        XCTAssertEqual(try BackupVerifier.validatedResults(items: items, results: [duplicate])["one"]?.assetId, "still")
        for rows in [[], [duplicate, duplicate], [BulkUploadCheckResult(id: "unknown", action: "accept", reason: nil, assetId: nil, isTrashed: nil)], [BulkUploadCheckResult(id: "one", action: "reject", reason: "new-unknown-reason", assetId: "still", isTrashed: false)]] {
            XCTAssertThrowsError(try BackupVerifier.validatedResults(items: items, results: rows))
        }
    }

    func testStaleAccountOrEditedLocalResourceAfterReadCannotProduceProof() async throws {
        let current = Synchronization.Mutex(true)
        let device = fixtureDevice()
        let entry = BackupEntry(modificationDate: device.modificationDate, isLivePhoto: false, primaryChecksum: "still-sha1", primaryRemoteId: "still")
        let remote = FixtureBackupRemote([fixtureRemote()], onRead: { current.withLock { $0 = false } })
        do {
            _ = try await BackupVerifier.verify(asset: device, entry: entry, ownerID: "owner", account: "fixture", generation: UUID(), remote: remote, current: { current.withLock { $0 } })
            XCTFail("stale asynchronous result produced proof")
        } catch {}
    }

    func testPersistedProofIsPendingOnNewSessionAndCannotApplyToEditedRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json")
        let index = BackupIndex(fileURL: file)
        let generation = UUID()
        let loaded = await index.load(serverHost: "https://fixture.invalid/api", userId: "owner", generation: generation)
        XCTAssertTrue(loaded)
        let device = fixtureDevice()
        await index.setHashed(localId: device.localIdentifier, isLivePhoto: false, primaryChecksum: "still-sha1", motionChecksum: nil, modificationDate: device.modificationDate)
        await index.setPrimaryRemoteId(localId: device.localIdentifier, "still")
        let stored = await index.entry(for: device.localIdentifier)
        let source = try XCTUnwrap(stored)
        let proof = try await BackupVerifier.verify(asset: device, entry: source, ownerID: "owner", account: "https://fixture.invalid/api|owner", generation: generation, remote: FixtureBackupRemote([fixtureRemote()]), current: { true })
        let committed = await index.recordProof(localId: device.localIdentifier, source: source, proof: proof)
        XCTAssertTrue(committed)
        let before = await index.entry(for: device.localIdentifier)
        XCTAssertEqual(before?.isBackedUp, true)
        _ = await index.flush()
        let reloaded = BackupIndex(fileURL: file)
        _ = await reloaded.load(serverHost: "https://fixture.invalid/api", userId: "owner", generation: UUID())
        let migrated = await reloaded.entry(for: device.localIdentifier)
        XCTAssertEqual(migrated?.isBackedUp, false)
        XCTAssertEqual(migrated?.primaryChecksum, "still-sha1")
        await index.setHashed(localId: device.localIdentifier, isLivePhoto: false, primaryChecksum: "still-sha1", motionChecksum: nil, modificationDate: Date(timeIntervalSince1970: 200))
        let stale = await index.recordProof(localId: device.localIdentifier, source: source, proof: proof)
        XCTAssertFalse(stale)
    }
}

extension BackupVerificationTests {
    func testHiddenDoesNotInvalidateButTrashRestoreAndDeleteDo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let generation = UUID()
        _ = await index.load(serverHost: "https://fixture.invalid/api", userId: "owner", generation: generation)
        let asset = fixtureDevice(live: true)
        await index.setHashed(localId: asset.localIdentifier, isLivePhoto: true, primaryChecksum: "still-sha1", motionChecksum: "motion-sha1", modificationDate: asset.modificationDate)
        await index.setPrimaryRemoteId(localId: asset.localIdentifier, "still")
        await index.setMotionRemoteId(localId: asset.localIdentifier, "motion")
        let stored = await index.entry(for: asset.localIdentifier)
        let source = try XCTUnwrap(stored)
        let proof = try await BackupVerifier.verify(asset: asset, entry: source, ownerID: "owner", account: "https://fixture.invalid/api|owner", generation: generation, remote: FixtureBackupRemote([fixtureRemote(link: "motion"), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]), current: { true })
        _ = await index.recordProof(localId: asset.localIdentifier, source: source, proof: proof)
        await index.noteRemoteChange(ids: ["motion"], change: .hidden, generation: generation)
        let hidden = await index.entry(for: asset.localIdentifier)
        XCTAssertEqual(hidden?.isBackedUp, true)
        await index.noteRemoteChange(ids: ["motion"], change: .trashed, generation: generation)
        let trashed = await index.entry(for: asset.localIdentifier)
        XCTAssertEqual(trashed?.isBackedUp, false)
        XCTAssertEqual(trashed?.verificationState, .trashed)
        let late = await index.recordProof(localId: asset.localIdentifier, source: source, proof: proof)
        XCTAssertFalse(late, "an older in-flight check overrode a newer trash event")
        await index.noteRemoteChange(ids: ["motion"], change: .restored, generation: generation)
        let restored = await index.entry(for: asset.localIdentifier)
        XCTAssertEqual(restored?.isBackedUp, false)
        XCTAssertEqual(restored?.motionRemoteId, "motion")
        await index.noteRemoteChange(ids: ["still"], change: .deleted, generation: generation)
        let deleted = await index.entry(for: asset.localIdentifier)
        XCTAssertNil(deleted?.primaryRemoteId)
        XCTAssertEqual(deleted?.primaryChecksum, "still-sha1")
    }
}

extension BackupVerificationTests {
    func testIncompleteLivePhotoProofCannotMatchMissingMotionCandidate() {
        let asset = fixtureDevice(live: true)
        let entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: true, primaryChecksum: "still-sha1", primaryRemoteId: "still")
        let proof = BackupProof(account: "fixture", generation: UUID(), localRevision: asset,
                                primary: BackupComponentProof(remoteID: "still", checksum: "still-sha1", ownerID: "owner", type: "IMAGE"),
                                motion: nil, livePhotoVideoID: nil, verifiedAt: Date())
        XCTAssertFalse(proof.matches(entry))
    }
}
