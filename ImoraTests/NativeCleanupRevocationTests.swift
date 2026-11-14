import XCTest
@testable import Imora

@MainActor
final class NativeCleanupRevocationTests: XCTestCase {
    private func index(of manager: BackupManager) throws -> BackupIndex {
        try XCTUnwrap(Mirror(reflecting: manager).children.first { $0.label == "index" }?.value as? BackupIndex)
    }

    func testKnownRemovalRevokesFinalPermissionBeforeAsyncIndexWork() throws {
        for change in [BackupRemoteChange.deleted, .trashed] {
            let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
            let manager = BackupManager(client: client)
            defer { manager.shutdown(); client.invalidate() }
            let index = try index(of: manager), epoch = index.evidenceVersion
            let permitted: @Sendable () -> Bool = { index.evidenceVersion == epoch }
            XCTAssertTrue(permitted())
            manager.noteRemoteChange(["synthetic"], change: change)
            // No suspension: SQLite and the deferred index task have not run.
            XCTAssertFalse(permitted(), "Known removal must revoke the final PhotoKit permission synchronously")
        }
    }

    func testKnownEditRevokesFinalPermissionBeforeAsyncIndexWork() throws {
        let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
        let manager = BackupManager(client: client)
        defer { manager.shutdown(); client.invalidate() }
        let index = try index(of: manager), epoch = index.evidenceVersion
        manager.noteRemoteEdits(["synthetic"])
        XCTAssertNotEqual(index.evidenceVersion, epoch)
    }
    func testManagerCallbackAtFinalLibraryPermissionRecordsZeroDeletes() async throws {
        for change in [BackupRemoteChange.deleted, .trashed] {
            let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
            let manager = BackupManager(client: client)
            defer { manager.shutdown(); client.invalidate() }
            let asset = fixtureDevice()
            let checksum = "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
            let entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: false,
                                    primaryChecksum: checksum, primaryRemoteId: "still")
            let remote = CleanupFixtureRemote([fixtureRemote(checksum: checksum)])
            let account = client.serverKey + "|owner"
            let proof = try await BackupVerifier.verify(asset: asset, entry: entry, ownerID: "owner", account: account,
                generation: client.context.id, remote: remote, current: { true })
            let report = CleanupReport(account: account, generation: client.context.id,
                candidates: [CleanupCandidate(source: entry, proof: proof)], keptMedia: MediaCounts(), route: ServerRoute.resolve(client.apiURL))
            let permission = manager.cleanupPermission(for: report)
            let library = CleanupFixtureLibrary([asset])
            await library.beforePermission {
                await MainActor.run {
                    manager.noteRemoteChange(["still"], change: change)
                    XCTAssertFalse(permission(), "No suspension after the known-event callback")
                }
            }
            do {
                _ = try await CleanupVerifier.perform(report: report, account: account, generation: client.context.id,
                    library: library, remote: remote, isCurrent: { permission() }, canCommit: permission)
                XCTFail("The final permission must prevent deletion")
            } catch {}
            let deleted = await library.deleted
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testConfirmationCannotCrossLoginGeneration() async throws {
        let client = ImoraClient(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "synthetic")
        let manager = BackupManager(client: client)
        defer { manager.shutdown(); client.invalidate() }
        let request = RebackupConfirmation(localIdentifier: "captured-local", accountGeneration: UUID())
        do { _ = try await manager.rebackupAfterConfirmation(request); XCTFail() }
        catch BackupVerificationError.stale {}
    }

}
