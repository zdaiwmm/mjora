import XCTest
@testable import Imora

@MainActor
final class BackupIntentStoreTests: XCTestCase {
    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "background-intent-tests-\(UUID().uuidString)/intents.json")
    }

    func testLegacyPendingAccountsRemainRecoverableAfterMigration() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"["https://one.invalid/api|alice","https://two.invalid/api|bob"]"#.utf8).write(to: url)
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.contains("https://one.invalid/api|alice"))
        XCTAssertTrue(store.contains("https://two.invalid/api|bob"))
        XCTAssertFalse(store.requiresExplicitResume("https://one.invalid/api|alice"))
        XCTAssertTrue(store.pause(account: "https://one.invalid/api|alice"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertTrue(reloaded.contains("https://two.invalid/api|bob"))
        XCTAssertFalse(reloaded.requiresExplicitResume("https://two.invalid/api|bob"))
        XCTAssertTrue(reloaded.requiresExplicitResume("https://one.invalid/api|alice"))
    }

    func testUnknownExpirationRetainsPendingWorkAndRequiresExplicitResumeAcrossRestart() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.set(true, account: "owner"))
        XCTAssertTrue(store.pause(account: "owner"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertTrue(reloaded.contains("owner"))
        XCTAssertTrue(reloaded.requiresExplicitResume("owner"))
        XCTAssertFalse(reloaded.canResumeAutomatically("owner", autoBackup: true))
        XCTAssertFalse(reloaded.canResumeAutomatically("owner", autoBackup: false))
        // Ordinary checkpointing must never erase the user's resume gate.
        XCTAssertTrue(reloaded.set(true, account: "owner"))
        XCTAssertTrue(BackupIntentStore(url: url).requiresExplicitResume("owner"))
    }

    func testExplicitResumeClearsOnlyItsAccountGateAndPersistsPendingWork() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.pause(account: "alice"))
        XCTAssertTrue(store.pause(account: "bob"))
        XCTAssertTrue(store.resume(account: "alice"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertTrue(reloaded.contains("alice"))
        XCTAssertFalse(reloaded.requiresExplicitResume("alice"))
        XCTAssertTrue(reloaded.canResumeAutomatically("alice", autoBackup: false))
        XCTAssertTrue(reloaded.contains("bob"))
        XCTAssertTrue(reloaded.requiresExplicitResume("bob"))
        XCTAssertFalse(reloaded.canResumeAutomatically("bob", autoBackup: true))
    }

    func testExplicitCancelClearsBothPendingWorkAndResumeGate() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.pause(account: "owner"))
        XCTAssertTrue(store.set(false, account: "owner"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertFalse(reloaded.contains("owner"))
        XCTAssertFalse(reloaded.requiresExplicitResume("owner"))
    }

    func testUnreadableStateNeverAuthorizesAutomaticResumeOrOverwritesExistingBytes() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not an intent journal".utf8)
        try corrupt.write(to: url)
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.requiresExplicitResume("owner"))
        XCTAssertFalse(store.canResumeAutomatically("owner", autoBackup: true))
        XCTAssertFalse(store.resume(account: "owner"))
        XCTAssertFalse(store.set(true, account: "owner"))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testOnlyAnAutomaticPreferenceOrUnfinishedUnpausedRequestAllowsAutomaticResume() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertFalse(store.canResumeAutomatically("owner", autoBackup: false))
        XCTAssertTrue(store.canResumeAutomatically("owner", autoBackup: true))
        XCTAssertTrue(store.set(true, account: "owner"))
        XCTAssertTrue(store.canResumeAutomatically("owner", autoBackup: false))
        XCTAssertTrue(store.pause(account: "owner"))
        XCTAssertFalse(store.canResumeAutomatically("owner", autoBackup: true))
        XCTAssertTrue(store.resume(account: "owner"))
        XCTAssertTrue(store.canResumeAutomatically("owner", autoBackup: false))
    }

    func testCompletionAfterExpirationCannotEraseTheExplicitResumeBarrier() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.resume(account: "owner"))
        // The worker's index flush was already in flight when expiration ran.
        XCTAssertTrue(store.pause(account: "owner"))
        XCTAssertFalse(store.complete(account: "owner"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertTrue(reloaded.contains("owner"))
        XCTAssertTrue(reloaded.requiresExplicitResume("owner"))
        XCTAssertFalse(reloaded.canResumeAutomatically("owner", autoBackup: true))
    }

    func testSuccessfulCompletionClearsOnlyItsUnpausedRequest() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupIntentStore(url: url)
        XCTAssertTrue(store.resume(account: "completed"))
        XCTAssertTrue(store.pause(account: "paused"))
        XCTAssertTrue(store.complete(account: "completed"))
        let reloaded = BackupIntentStore(url: url)
        XCTAssertFalse(reloaded.contains("completed"))
        XCTAssertTrue(reloaded.contains("paused"))
        XCTAssertTrue(reloaded.requiresExplicitResume("paused"))
        // In-app Cancel remains an explicit removal of the pause barrier.
        XCTAssertTrue(reloaded.set(false, account: "paused"))
        XCTAssertFalse(BackupIntentStore(url: url).requiresExplicitResume("paused"))
    }
}
