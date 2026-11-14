import XCTest
@testable import Imora

final class BackupReceiptReplayTests: XCTestCase {
    func testReceiptFromDeletedCopyCannotReplaceNewlyVerifiedExternalCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (index, oldSource, oldProof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
        await index.noteRemoteChange(ids: ["still"], change: .deleted, generation: oldProof.generation)
        let removedEntries = await index.allEntries()
        let removed = try XCTUnwrap(removedEntries["fixture-local"])
        await index.applyRemoteCheck(localId: "fixture-local", source: removed,
            result: .init(id: "fixture-local", action: "reject", reason: "duplicate", assetId: "restored-still", isTrashed: false),
            motion: false, generation: oldProof.generation)
        let candidates = await index.allEntries()
        let candidate = try XCTUnwrap(candidates["fixture-local"])
        let proof = try await BackupVerifier.verify(asset: fixtureDevice(live: true), entry: candidate, ownerID: "owner",
            account: "https://fixture.invalid/api|owner", generation: oldProof.generation,
            remote: FixtureBackupRemote([fixtureRemote("restored-still", link: "motion"), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]), current: { true })
        let recorded = await index.recordProof(localId: "fixture-local", source: candidate, proof: proof)
        XCTAssertTrue(recorded)
        _ = await index.applyReceipt(receipt(source: oldSource, motion: false, remoteID: "still"))
        let final = await index.entry(for: "fixture-local")
        XCTAssertEqual(final?.primaryRemoteId, "restored-still")
        XCTAssertEqual(final?.proof, proof)
        XCTAssertEqual(final?.isBackedUp, true)
    }

    func testNewerTrashEvidenceRejectsEarlierSuccessfulProof() async throws {
        for fromBulk in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (index, source, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
            if fromBulk {
                await index.applyRemoteCheck(localId: "fixture-local", source: source,
                    result: .init(id: "fixture-local", action: "reject", reason: "duplicate", assetId: "still", isTrashed: true),
                    motion: false, generation: proof.generation)
            } else {
                await index.recordVerificationFailure(localId: "fixture-local", source: source, generation: proof.generation, state: .trashed)
            }
            let accepted = await index.recordProof(localId: "fixture-local", source: source, proof: proof)
            XCTAssertFalse(accepted, "A proof obtained before newer trash metadata cannot clear its upload hold")
        }
    }

    func testTrashIntentSurvivesVerificationFailureAndLocalEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (index, _, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
        await index.noteRemoteChange(ids: ["still"], change: .trashed, generation: proof.generation)
        let trashedEntries = await index.allEntries()
        let trashed = try XCTUnwrap(trashedEntries["fixture-local"])
        await index.recordVerificationFailure(localId: "fixture-local", source: trashed, generation: proof.generation, state: .offline)
        await index.setHashed(localId: "fixture-local", isLivePhoto: true, primaryChecksum: "edited-still",
            motionChecksum: "motion-sha1", modificationDate: trashed.modificationDate)
        let editedEntries = await index.allEntries()
        let edited = try XCTUnwrap(editedEntries["fixture-local"])
        let permitted = await index.permitsUpload(localId: "fixture-local", source: edited, generation: proof.generation)
        XCTAssertFalse(permitted, "An unavailable server must not erase a user's trash decision")
    }

    func testRemovedStillStaysBlockedAfterMotionIsEdited() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (index, source, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
        let before = await index.permitsUpload(localId: "fixture-local", source: source, generation: proof.generation)
        XCTAssertTrue(before)
        await index.applyRemoteCheck(localId: "fixture-local", source: source,
            result: .init(id: "fixture-local", action: "accept", reason: nil, assetId: nil, isTrashed: nil),
            motion: false, generation: proof.generation)
        await index.setHashed(localId: "fixture-local", isLivePhoto: true, primaryChecksum: "still-sha1",
            motionChecksum: "edited-motion-sha1", modificationDate: source.modificationDate)
        let hashed = await index.entry(for: "fixture-local")
        XCTAssertEqual(hashed?.isUploadBlockedByRemoteRemoval, true, "Editing motion must not silently recreate the removed still")
        if let hashed {
            let permitted = await index.permitsUpload(localId: "fixture-local", source: hashed, generation: proof.generation)
            XCTAssertFalse(permitted)
        }
    }

    func testFreshProofCanReconcileServerRestoreWithoutUploading() async throws {
        for change in [BackupRemoteChange.trashed, .deleted] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (index, _, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
            await index.noteRemoteChange(ids: ["still"], change: change, generation: proof.generation)
            await index.invalidateProofs()
            let pendingEntries = await index.allEntries()
            let pending = try XCTUnwrap(pendingEntries["fixture-local"])
            await index.applyRemoteCheck(localId: "fixture-local", source: pending,
                result: .init(id: "fixture-local", action: "reject", reason: "duplicate", assetId: "still", isTrashed: false),
                motion: false, generation: proof.generation)
            let currentEntries = await index.allEntries()
            let current = try XCTUnwrap(currentEntries["fixture-local"])
            let freshProof = try await BackupVerifier.verify(asset: fixtureDevice(live: true), entry: current, ownerID: "owner",
                account: "https://fixture.invalid/api|owner", generation: proof.generation,
                remote: FixtureBackupRemote([fixtureRemote(link: "motion"), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]), current: { true })
            let recorded = await index.recordProof(localId: "fixture-local", source: current, proof: freshProof)
            XCTAssertTrue(recorded, "Read-only verification must recognize an externally restored copy")
            let restored = await index.entry(for: "fixture-local")
            XCTAssertEqual(restored?.isBackedUp, true)
            XCTAssertEqual(restored?.isUploadBlockedByRemoteRemoval, false)
        }
    }

    func testRemoteDeletionSurvivesLateReceiptAndNewSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.json")
        let (index, source, proof) = try await verifiedIndex(file: file)
        await index.noteRemoteChange(ids: ["still"], change: .deleted, generation: proof.generation)
        let permittedAfterExport = await index.permitsUpload(localId: "fixture-local", source: source, generation: proof.generation)
        XCTAssertFalse(permittedAfterExport, "Deletion arriving during preparation must prevent upload handoff")
        _ = await index.applyReceipt(receipt(source: source, motion: false, remoteID: "still"))
        let afterReceipt = await index.entry(for: "fixture-local")
        XCTAssertNil(afterReceipt?.primaryRemoteId, "A late receipt must not revive a server-deleted copy")
        _ = await index.flush()
        let restored = BackupIndex(fileURL: file)
        let generation = UUID()
        _ = await restored.load(serverHost: "https://fixture.invalid/api", userId: "owner", generation: generation)
        await restored.invalidateProofs()
        let restoredEntries = await restored.allEntries()
        let stored = try XCTUnwrap(restoredEntries["fixture-local"])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        XCTAssertEqual(encoded?["remoteDeletionDetected"] as? Bool, true, "Deletion intent must remain durable across reconciliation and restart")
    }

    private func verifiedIndex(file: URL) async throws -> (BackupIndex, BackupEntry, BackupProof) {
        let index = BackupIndex(fileURL: file)
        let generation = UUID()
        _ = await index.load(serverHost: "https://fixture.invalid/api", userId: "owner", generation: generation)
        let asset = fixtureDevice(live: true)
        await index.setHashed(localId: asset.localIdentifier, isLivePhoto: true, primaryChecksum: "still-sha1",
            motionChecksum: "motion-sha1", modificationDate: asset.modificationDate)
        await index.setPrimaryRemoteId(localId: asset.localIdentifier, "still")
        await index.setMotionRemoteId(localId: asset.localIdentifier, "motion")
        let stored = await index.entry(for: asset.localIdentifier)
        let source = try XCTUnwrap(stored)
        let proof = try await BackupVerifier.verify(asset: asset, entry: source, ownerID: "owner",
            account: "https://fixture.invalid/api|owner", generation: generation,
            remote: FixtureBackupRemote([fixtureRemote(link: "motion"), fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")]),
            current: { true })
        let recorded = await index.recordProof(localId: asset.localIdentifier, source: source, proof: proof)
        XCTAssertTrue(recorded)
        return (index, source, proof)
    }

    private func receipt(source: BackupEntry, motion: Bool, remoteID: String) -> BackgroundUploader.Completion {
        .init(ticket: .init(account: "https://fixture.invalid/api|owner", localId: "fixture-local", isMotion: motion,
                            bodyPath: "", source: source), remoteId: remoteID)
    }

    func testIdenticalStillAndMotionReceiptReplaysPreserveExactVerifiedProof() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (index, source, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
        let epoch = index.evidenceVersion
        for motion in [false, true] {
            let accepted = await index.applyReceipt(receipt(source: source, motion: motion, remoteID: motion ? "motion" : "still"))
            XCTAssertTrue(accepted)
            let replayed = await index.entry(for: "fixture-local")
            XCTAssertEqual(replayed?.proof, proof)
            XCTAssertEqual(replayed?.verificationState, .verified)
            XCTAssertEqual(replayed?.isBackedUp, true)
            XCTAssertEqual(index.evidenceVersion, epoch, "a no-op receipt must not cancel an active cleanup's evidence")
        }
    }

    func testDifferentRemoteReceiptStillInvalidatesProofForEachComponent() async throws {
        for motion in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (index, source, _) = try await verifiedIndex(file: directory.appending(path: "index.json"))
            _ = await index.applyReceipt(receipt(source: source, motion: motion, remoteID: "changed-remote"))
            let changed = await index.entry(for: "fixture-local")
            XCTAssertNil(changed?.proof)
            XCTAssertEqual(changed?.verificationState, .pending)
            XCTAssertEqual(motion ? changed?.motionRemoteId : changed?.primaryRemoteId, "changed-remote")
        }
    }

    func testStaleSourceReceiptCannotReplaceCurrentProofOrRemoteIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (index, source, proof) = try await verifiedIndex(file: directory.appending(path: "index.json"))
        var stale = source
        stale.primaryChecksum = "previous-bytes"
        _ = await index.applyReceipt(receipt(source: stale, motion: false, remoteID: "old-remote"))
        let current = await index.entry(for: "fixture-local")
        XCTAssertEqual(current?.proof, proof)
        XCTAssertEqual(current?.primaryRemoteId, "still")
    }
}
