import XCTest
@testable import Imora

private actor RebackupRemoteFixture: ExplicitRebackupRemoteAPI {
    var values: [String: BackupRemoteAsset]
    var restores: [[String]] = []
    let forbidden: Bool
    init(_ values: [BackupRemoteAsset], forbidden: Bool = false) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        self.forbidden = forbidden
    }
    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset {
        guard let value = values[id] else { throw ImoraError.http(404, "absent") }
        return value
    }
    func restoreAssets(ids: [String]) async throws {
        if forbidden { throw ImoraError.http(403, "forbidden") }
        restores.append(ids)
        for id in ids { values[id]?.isTrashed = false }
    }
    func repairLivePhoto(stillID: String, videoID: String) async throws { XCTFail("No automatic link repair") }
}

final class ExplicitRebackupRecoveryTests: XCTestCase, @unchecked Sendable {
    func testOwnedCompleteTrashPairRestoresAndVerifies() async throws {
        for live in [false, true] {
            var still = fixtureRemote(link: live ? "motion" : nil); still.isTrashed = true
            var motion = fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO"); motion.isTrashed = true
            let remote = RebackupRemoteFixture(live ? [still, motion] : [still])
            let entry = BackupEntry(modificationDate: nil, isLivePhoto: live, primaryChecksum: "still-sha1", primaryRemoteId: "still",
                motionChecksum: live ? "motion-sha1" : nil, motionRemoteId: live ? "motion" : nil)
            let restored = try await ExplicitRebackupRecovery.restoreIfPresent(entry: entry, ownerID: "owner", remote: remote, current: { true })
            XCTAssertTrue(restored)
            let restores = await remote.restores
            XCTAssertEqual(restores, [live ? ["still", "motion"] : ["still"]])
            let final = try await remote.backupAssetDetail(id: "still")
            XCTAssertEqual(final.isTrashed, false)
        }
    }
    func testPermanentAbsenceAllowsReplacementAndAlreadyRestoredNeedsNoMutation() async throws {
        let entry = BackupEntry(modificationDate: nil, isLivePhoto: false, primaryChecksum: "still-sha1", primaryRemoteId: "still")
        for present in [false, true] {
            let remote = RebackupRemoteFixture(present ? [fixtureRemote()] : [])
            let restored = try await ExplicitRebackupRecovery.restoreIfPresent(entry: entry, ownerID: "owner", remote: remote, current: { true })
            XCTAssertEqual(restored, present)
            let requests = await remote.restores
            XCTAssertTrue(requests.isEmpty)
        }
    }
    func testForbiddenOrIncompletePairDoesNotRetireProtection() async throws {
        var still = fixtureRemote(link: "motion"); still.isTrashed = true
        let motion = fixtureRemote("motion", checksum: "motion-sha1", type: "VIDEO")
        let entry = BackupEntry(modificationDate: nil, isLivePhoto: true, primaryChecksum: "still-sha1", primaryRemoteId: "still", motionChecksum: "motion-sha1", motionRemoteId: "motion")
        for values in [[still], [motion], [still, motion]] {
            let remote = RebackupRemoteFixture(values, forbidden: values.count == 2)
            do {
                _ = try await ExplicitRebackupRecovery.restoreIfPresent(entry: entry, ownerID: "owner", remote: remote, current: { true })
                XCTFail("Incomplete or forbidden recovery must leave protection in place")
            } catch {}
            let requests = await remote.restores
            XCTAssertTrue(requests.isEmpty)
        }
    }
}
