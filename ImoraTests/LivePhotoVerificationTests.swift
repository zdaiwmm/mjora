import XCTest
import Synchronization
@testable import Imora

actor PairingFixtureRemote: BackupRemoteAPI {
    private var stills: [BackupRemoteAsset]
    private var video = fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")
    private var videoReads = 0
    private let deny: Bool
    private let postwrite: String?
    private let corruptAfterWrite: Bool
    private let trashVideoOnSecondRead: Bool
    private(set) var repairs = 0

    init(links: [String?] = [nil], deny: Bool = false, corruptAfterWrite: Bool = false,
         postwrite: String? = "wrong-motion", trashVideoOnSecondRead: Bool = false) {
        stills = links.map { fixtureRemote(link: $0) }
        self.deny = deny
        self.corruptAfterWrite = corruptAfterWrite
        self.postwrite = postwrite
        self.trashVideoOnSecondRead = trashVideoOnSecondRead
    }

    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset {
        if id == "motion" {
            videoReads += 1
            if trashVideoOnSecondRead, videoReads > 1 { video.isTrashed = true }
            return video
        }
        guard id == "still", let first = stills.first else { throw ImoraError.http(404, "fixture missing") }
        if stills.count > 1 { stills.removeFirst() }
        return first
    }

    func repairLivePhoto(stillID: String, videoID: String) async throws {
        guard stillID == "still", videoID == "motion" else { throw BackupVerificationError.mismatch }
        repairs += 1
        if deny { throw ImoraError.http(403, "权限不足") }
        stills = [fixtureRemote(link: corruptAfterWrite ? postwrite : videoID)]
    }
}

final class LivePhotoVerificationTests: XCTestCase {
    private func verify(_ remote: PairingFixtureRemote, current: @escaping @Sendable () async -> Bool = { true },
                        wait: @escaping @Sendable (Int) async throws -> Void = { _ in }) async throws -> BackupProof {
        let asset = fixtureDevice(live: true)
        let entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: true, primaryChecksum: "still-sha1", primaryRemoteId: "still", motionChecksum: "motion-sha1", motionRemoteId: "motion")
        return try await BackupVerifier.verify(asset: asset, entry: entry, ownerID: "owner", account: "fixture", generation: UUID(), remote: remote, repairEmptyPair: true, wait: wait, current: current)
    }

    func testDelayedAutomaticPairingCompletesWithoutMutation() async throws {
        let remote = PairingFixtureRemote(links: [nil, nil, "motion"])
        let proof = try await verify(remote)
        XCTAssertEqual(proof.livePhotoVideoID, "motion")
        let repairs = await remote.repairs
        XCTAssertEqual(repairs, 0)
    }

    func testEmptyAssociationIsRepairedOnceAndReadBackExactly() async throws {
        let remote = PairingFixtureRemote()
        let proof = try await verify(remote)
        XCTAssertEqual(proof.livePhotoVideoID, "motion")
        let repairs = await remote.repairs
        XCTAssertEqual(repairs, 1)
    }

    func testObservedConflictsAreNeverOverwritten() async throws {
        for links in [["wrong-motion"], [nil, "wrong-motion"]] as [[String?]] {
            let remote = PairingFixtureRemote(links: links)
            do { _ = try await verify(remote); XCTFail("conflict produced proof") } catch {}
            let repairs = await remote.repairs
            XCTAssertEqual(repairs, 0)
        }
    }

    func testPermissionFailureDoesNotRetryMutation() async throws {
        let remote = PairingFixtureRemote(deny: true)
        do { _ = try await verify(remote); XCTFail("permission denial produced proof") } catch {}
        let repairs = await remote.repairs
        XCTAssertEqual(repairs, 1)
    }

    func testWrongOrEmptyPostwriteAssociationNeverCompletes() async throws {
        for link in [nil, "wrong-motion"] as [String?] {
            let remote = PairingFixtureRemote(corruptAfterWrite: true, postwrite: link)
            do { _ = try await verify(remote); XCTFail("bad write readback produced proof") } catch {}
            let repairs = await remote.repairs
            XCTAssertEqual(repairs, 1)
        }
    }

    func testStaleOrCancelledWaitNeverRepairs() async throws {
        let current = Mutex(true)
        let remote = PairingFixtureRemote()
        do {
            _ = try await verify(remote, current: { current.withLock { $0 } }, wait: { _ in current.withLock { $0 = false } })
            XCTFail("stale wait produced proof")
        } catch {}
        let repairs = await remote.repairs
        XCTAssertEqual(repairs, 0)
        let cancelled = PairingFixtureRemote()
        do { _ = try await verify(cancelled, wait: { _ in throw CancellationError() }); XCTFail("cancel produced proof") } catch {}
        let cancelledRepairs = await cancelled.repairs
        XCTAssertEqual(cancelledRepairs, 0)
    }

    func testMotionTrashedDuringWaitPreventsRepair() async throws {
        let remote = PairingFixtureRemote(trashVideoOnSecondRead: true)
        do { _ = try await verify(remote); XCTFail("trashed video produced proof") } catch {}
        let repairs = await remote.repairs
        XCTAssertEqual(repairs, 0)
    }
}
