import XCTest
@testable import Imora

final class BackupReceiptReplayTests: XCTestCase {
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
