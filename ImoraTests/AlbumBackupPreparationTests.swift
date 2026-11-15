import XCTest
@testable import Imora

@MainActor
final class AlbumBackupPreparationTests: XCTestCase {
    func testLocalSelectionRequiresConsentBeforeBackupOrAlbumWrite() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["local"], accountGeneration: generation)
        var effects: [String] = []
        do {
            _ = try await plan.perform(assetIDs: [], consent: nil, isCurrent: { true }, backup: {
                effects.append("backup:\($0)"); return "remote"
            }, verify: { _, _ in true }, operation: { ids in effects.append("album"); return ids })
            XCTFail("Opening or an unconfirmed selection must not upload")
        } catch { XCTAssertEqual(error as? AlbumBackupPreparation.Failure, .confirmationRequired) }
        XCTAssertEqual(effects, [])
    }

    func testPartialBackupKeepsVerifiedResolutionAndRetriesOnlyRemainingItem() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["a", "b", "a"], accountGeneration: generation)
        var backups: [String] = [], writes: [[String]] = []
        var failsB = true
        let backup: (String) async throws -> String = { id in
            backups.append(id)
            if id == "b", failsB { throw URLError(.notConnectedToInternet) }
            return "remote-\(id)"
        }
        do {
            _ = try await plan.perform(assetIDs: ["cloud"], consent: generation, isCurrent: { true },
                backup: backup, verify: { _, _ in true }, operation: { ids in writes.append(ids); return ids })
            XCTFail()
        } catch {}
        XCTAssertEqual(plan.resolvedRemoteIDs, ["a": "remote-a"])
        XCTAssertEqual(writes, [])
        failsB = false
        let ids = try await plan.perform(assetIDs: ["cloud"], consent: generation, isCurrent: { true },
            backup: backup, verify: { _, _ in true }, operation: { ids in writes.append(ids); return ids })
        XCTAssertEqual(backups, ["a", "b", "b"])
        XCTAssertEqual(ids, ["cloud", "remote-a", "remote-b"])
        XCTAssertEqual(writes, [["cloud", "remote-a", "remote-b"]])
    }

    func testUnverifiedBackupNeverReachesAlbumMutation() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["local"], accountGeneration: generation)
        var writes = 0
        do {
            _ = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { true },
                backup: { _ in "partial-live-pair" }, verify: { _, _ in false }, operation: { ids in writes += 1; return ids })
            XCTFail()
        } catch { XCTAssertEqual(error as? AlbumBackupPreparation.Failure, .unverifiedBackup) }
        XCTAssertEqual(plan.resolvedRemoteIDs, [:])
        XCTAssertEqual(writes, 0)
    }

    func testAccountChangeDuringBackupDiscardsThatResultAndPreventsAlbumWrite() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["local"], accountGeneration: generation)
        var current = true, writes = 0
        do {
            _ = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { current },
                backup: { _ in current = false; return "old-account-remote" }, verify: { _, _ in true },
                operation: { ids in writes += 1; return ids })
            XCTFail()
        } catch { XCTAssertEqual(error as? AlbumBackupPreparation.Failure, .accountChanged) }
        XCTAssertEqual(plan.resolvedRemoteIDs, [:])
        XCTAssertEqual(writes, 0)
    }

    func testFailedAlbumWriteRetainsVerifiedBackupsForRetry() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["local"], accountGeneration: generation)
        var backups = 0
        do {
            _ = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { true },
                backup: { _ in backups += 1; return "verified" }, verify: { _, _ in true },
                operation: { _ -> [String] in throw URLError(.timedOut) })
            XCTFail()
        } catch {}
        let ids = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { true },
            backup: { _ in backups += 1; return "verified" }, verify: { _, _ in true }, operation: { $0 })
        XCTAssertEqual(backups, 1)
        XCTAssertEqual(ids, ["verified"])
    }

    func testRevokedCachedPairIsReverifiedAndCannotReachAlbumWrite() async throws {
        let generation = UUID()
        let plan = AlbumBackupPreparation(localIdentifiers: ["local"], accountGeneration: generation)
        _ = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { true },
            backup: { _ in "verified" }, verify: { _, _ in true }, operation: { $0 })
        var writes = 0
        do {
            _ = try await plan.perform(assetIDs: [], consent: generation, isCurrent: { true },
                backup: { _ in throw URLError(.cannotFindHost) }, verify: { _, _ in false }, operation: { ids in writes += 1; return ids })
            XCTFail()
        } catch {}
        XCTAssertEqual(plan.resolvedRemoteIDs, [:])
        XCTAssertEqual(writes, 0)
    }

    func testRemoteOnlySelectionDoesNotRequestBackupAndDeduplicatesIDs() async throws {
        let plan = AlbumBackupPreparation(localIdentifiers: [], accountGeneration: UUID())
        var backupCalls = 0
        let ids = try await plan.perform(assetIDs: ["a", "b", "a"], consent: nil, isCurrent: { true },
            backup: { _ in backupCalls += 1; return "unexpected" }, verify: { _, _ in false }, operation: { $0 })
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(backupCalls, 0)
    }
}
