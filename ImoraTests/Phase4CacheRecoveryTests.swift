import Security
import XCTest
@testable import Imora

@MainActor
final class Phase4CacheRecoveryTests: XCTestCase {
    func testUnwritableJournalUsesCheckedMatchingCredentialFallback() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-readonly-journal-\(UUID())")
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let scope = StableMediaScope.credential("synthetic-scope", server: "fixture.invalid")
        let subject = MediaDisplayKeyV1.Subject.remoteAsset("synthetic-asset")
        var removalFailed = false
        do { try journal.retire(scope: scope, subjects: [subject]); XCTFail("Read-only journal unexpectedly committed") }
        catch let failure as MediaContentGenerations.RetirementFailure { removalFailed = !failure.journalRemovalSucceeded }
        XCTAssertTrue(removalFailed)
        XCTAssertNil(journal.current(scope: scope, subject: subject))
        let key = "phase4-recovery-\(UUID())", token = "synthetic-\(UUID())"
        KeychainStore.set(token, for: key); defer { KeychainStore.delete(key) }
        let outcome = MediaCacheRecovery.resolve(protectedDataAvailable: true, journalRemovalSucceeded: false) {
            KeychainStore.removeIfMatching(token, for: key)
        }
        XCTAssertEqual(outcome, .signInRequired)
        guard case .missing = KeychainStore.get(key) else { return XCTFail("Removal was claimed without persistence") }
    }

    func testFailedCredentialFallbackReportsUnresolvedDurability() {
        let key = "phase4-recovery-\(UUID())", token = "synthetic-\(UUID())"
        KeychainStore.set(token, for: key); defer { KeychainStore.delete(key) }
        let outcome = MediaCacheRecovery.resolve(protectedDataAvailable: true, journalRemovalSucceeded: false) { .failed(errSecIO) }
        XCTAssertEqual(outcome, .unresolvedDurability)
        guard case .value = KeychainStore.get(key) else { return XCTFail("Synthetic credential unexpectedly changed") }
    }

    func testNewerCredentialWinsBeforeSerializedCompareAndRemoval() {
        let key = "phase4-recovery-\(UUID())", old = "synthetic-old-\(UUID())", newer = "synthetic-new-\(UUID())"
        KeychainStore.set(old, for: key); defer { KeychainStore.delete(key) }
        KeychainStore.set(newer, for: key)
        let outcome = MediaCacheRecovery.resolve(protectedDataAvailable: true, journalRemovalSucceeded: false) {
            KeychainStore.removeIfMatching(old, for: key)
        }
        XCTAssertEqual(outcome, .newerCredential)
        guard case .value(let retained) = KeychainStore.get(key) else { return XCTFail("Newer credential removed") }
        XCTAssertTrue(retained == newer)
    }

    func testTemporaryProtectionDoesNotRemoveCredential() {
        var removalAttempted = false
        let outcome = MediaCacheRecovery.resolve(protectedDataAvailable: false, journalRemovalSucceeded: false) {
            removalAttempted = true; return .removed
        }
        XCTAssertEqual(outcome, .temporaryProtection)
        XCTAssertFalse(removalAttempted)
    }

    func testComparedPersistentReferenceCannotDeleteReplacementItem() {
        let key = "phase4-recovery-\(UUID())", old = "synthetic-old-\(UUID())", newer = "synthetic-new-\(UUID())"
        KeychainStore.set(old, for: key); defer { KeychainStore.delete(key) }
        let result = KeychainStore.removeIfMatching(old, for: key, deleteItem: { query in
            XCTAssertNotNil(query[kSecValuePersistentRef as String])
            XCTAssertNil(query[kSecAttrService as String])
            XCTAssertNil(query[kSecAttrAccount as String])
            // Model a separate writer replacing the matched item between the
            // security read/delete calls; do not touch the real login item.
            KeychainStore.set(newer, for: key)
            return SecItemDelete(query as CFDictionary)
        })
        XCTAssertEqual(result, .differentCredential)
        guard case .value(let retained) = KeychainStore.get(key) else { return XCTFail("Replacement credential removed") }
        XCTAssertTrue(retained == newer)
    }
}
