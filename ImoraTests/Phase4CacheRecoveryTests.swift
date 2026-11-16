import Security
import XCTest
@testable import Imora

@MainActor
final class Phase4CacheRecoveryTests: XCTestCase {
    func testFailedAccountRecoveryFenceCannotDenyDifferentLoginOrReviveFailedAccount() async throws {
        for legacy in [false, true] {
            let accountA = "failed-a-\(UUID())", accountB = "healthy-b-\(UUID())"
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAAAp0lEQVR4nO3PQQ0AIBDAsBPBG//ykIAIHg3Jkgno5uz1dcMFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWPHYBkqkxlq2SEToAAAAASUVORK5CYII=")!
            let server = try LocalHTTPServer { request in
                if request.path == "/api/users/me" {
                    let user = request.headers["authorization"]?.contains("token-a") == true ? accountA : accountB
                    return .init(body: Data("{\"id\":\"\(user)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8))
                }
                if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/png"], body: png) }
                return .init(status: 503)
            }
            try await server.start(); defer { server.stop() }
            let failed = ImoraClient(apiURL: server.apiURL, accessToken: "token-a")
            failed.confirmMediaAccount(accountA); defer { failed.invalidate() }
            let scopeA = failed.mediaDisplayScope, subject = MediaDisplayKeyV1.Subject.remoteAsset("failed-subject")
            let old = MediaDisplayKeyV1(scope: scopeA, subject: subject, sourceRevision: "old-R", presentationRevision: "old-R",
                variant: .grid, pixelBucket: 64, fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB")
            try MediaContentGenerations.shared.retire(scope: scopeA, subjects: [subject], keys: [old])
            let credential = try XCTUnwrap(failed.offlineAccountKey)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scopeA))
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "scope": object, "credentialScope": credential]), as: UTF8.self)
            KeychainStore.set(legacy ? credential : encoded, for: KeychainStore.mediaRecoveryFenceKey)
            defer { KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey) }
            let session = SessionStore()
            func login(_ account: String, _ token: String) async {
                await session.logIn(apiURL: server.apiURL, response: .init(accessToken: token, userId: account,
                    userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
                session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
            }
            await login(accountB, "token-b")
            do {
                XCTAssertEqual(session.state, .loggedIn)
                let healthy = try XCTUnwrap(session.client)
                let scopeB = healthy.mediaDisplayScope
                let unknown = MediaDisplayKeyV1.Subject.remoteAsset("unknown")
                let restart = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
                XCTAssertFalse(restart.isCurrent(scope: scopeA, subject: unknown, sourceRevision: "R", generation: restart.current(scope: scopeA, subject: unknown) ?? "missing"), "The failed account, including unlisted subjects, must retain its deny fence")
                XCTAssertTrue(restart.isRetired(scope: scopeA, subject: subject, sourceRevision: "old-R"))
                XCTAssertTrue(restart.isCurrent(scope: scopeB, subject: unknown, sourceRevision: "R", generation: restart.current(scope: scopeB, subject: unknown) ?? "missing"), "A's failure must not deny healthy B")
                do { _ = try await ImageLoader.shared.image(for: healthy.thumbnailURL(assetID: "healthy", cacheKey: "R"), targetPixelSize: 64) }
                catch { XCTFail("Healthy B endpoint was made unavailable by A's recovery: \(error)") }
                guard case .missing = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) else { throw CocoaError(.fileWriteUnknown) }
                await session.logOut(reportRemoteFailure: false)
                await login(accountA, "token-a")
                XCTAssertEqual(session.state, .loggedIn)
                let returned = try XCTUnwrap(session.client)
                XCTAssertFalse(MediaContentGenerations.shared.isCurrent(scope: returned.mediaDisplayScope, subject: unknown,
                    sourceRevision: "R", generation: MediaContentGenerations.shared.current(scope: scopeA, subject: unknown) ?? "missing"))
            } catch { await session.logOut(reportRemoteFailure: false); throw error }
            await session.logOut(reportRemoteFailure: false)
        }
    }

    func testUnknownLegacyRecoveryFenceIsRetainedWithoutGuessingCurrentAccount() async throws {
        let userID = "legacy-unknown-\(UUID())", fence = "unmapped-legacy-\(UUID())"
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        KeychainStore.set(fence, for: KeychainStore.mediaRecoveryFenceKey)
        defer { KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey) }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "unresolved-legacy", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        XCTAssertEqual(session.state, .loggedOut)
        XCTAssertNil(session.client)
        if case .value(let actual) = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) { XCTAssertEqual(actual, fence) }
        else { XCTFail("An unresolved legacy fence must not be silently consumed") }
        let healthy = ImoraClient(apiURL: server.apiURL, accessToken: "healthy-legacy"); healthy.confirmMediaAccount(userID)
        defer { healthy.invalidate() }
        let subject = MediaDisplayKeyV1.Subject.remoteAsset("unrelated")
        XCTAssertTrue(MediaContentGenerations.shared.isCurrent(scope: healthy.mediaDisplayScope, subject: subject,
            sourceRevision: "R", generation: MediaContentGenerations.shared.current(scope: healthy.mediaDisplayScope, subject: subject) ?? "missing"))
        await session.logOut(reportRemoteFailure: false)
    }

    func testPendingAThenBFailureCannotOverwriteEitherScopeBeforeRestartRecovery() async throws {
        for unresolvedLegacy in [false, true] {
            let accountA = "collision-a-\(UUID())", accountB = "collision-b-\(UUID())", accountC = "collision-c-\(UUID())"
            let server = try LocalHTTPServer { request in
                if request.path == "/api/users/me" { return .init(body: Data("{\"id\":\"\(accountC)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)) }
                return .init(status: 503)
            }
            try await server.start(); defer { server.stop() }
            let a = ImoraClient(apiURL: server.apiURL, accessToken: "collision-a"), b = ImoraClient(apiURL: server.apiURL, accessToken: "collision-b")
            a.confirmMediaAccount(accountA); b.confirmMediaAccount(accountB)
            defer { a.invalidate(); b.invalidate() }
            let scopeA = a.mediaDisplayScope, scopeB = b.mediaDisplayScope
            let rawA = unresolvedLegacy ? "unresolved-collision-\(UUID())" : try XCTUnwrap(MediaRecoveryFence.encoded(scope: scopeA, credentialScope: a.offlineAccountKey))
            KeychainStore.set(rawA, for: KeychainStore.mediaRecoveryFenceKey)
            KeychainStore.set(b.accessToken, for: "accessToken")
            defer { KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey); KeychainStore.delete("accessToken") }
            let root = FileManager.default.temporaryDirectory.appending(path: "phase4-collision-io-\(UUID())")
            let journal = MediaContentGenerations(root: root)
            try journal.ensureInitialized()
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            do { try journal.retire(scope: scopeB, subjects: [.remoteAsset("failed-b")], retiresSourceRevisions: false, blocksAccess: true); XCTFail("Real read-only journal unexpectedly wrote") }
            catch let failure as MediaContentGenerations.RetirementFailure { MediaCacheRecovery.handle(client: b, failure: failure) }
            guard case .value(let combined) = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) else { return XCTFail("Both pending negatives require a durable recovery fence") }
            XCTAssertLessThanOrEqual(combined.utf8.count, 8 << 10)
            let session = SessionStore()
            await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "collision-c", userId: accountC,
                userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
            session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
            let restarted = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory), unknown = MediaDisplayKeyV1.Subject.remoteAsset("unlisted")
            XCTAssertFalse(restarted.isCurrent(scope: scopeB, subject: unknown, sourceRevision: "R", generation: restarted.current(scope: scopeB, subject: unknown) ?? "missing"))
            if unresolvedLegacy {
                XCTAssertEqual(session.state, .loggedOut)
                guard case .value(let retained) = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) else { await session.logOut(reportRemoteFailure: false); return XCTFail("Unresolved A must remain durable after B is denied") }
                XCTAssertEqual(retained, combined)
            } else {
                XCTAssertEqual(session.state, .loggedIn)
                XCTAssertFalse(restarted.isCurrent(scope: scopeA, subject: unknown, sourceRevision: "R", generation: restarted.current(scope: scopeA, subject: unknown) ?? "missing"), "B's failure must not overwrite A's only pending deny")
                let c = try XCTUnwrap(session.client)
                XCTAssertTrue(restarted.isCurrent(scope: c.mediaDisplayScope, subject: unknown, sourceRevision: "R", generation: restarted.current(scope: c.mediaDisplayScope, subject: unknown) ?? "missing"))
                guard case .missing = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) else { await session.logOut(reportRemoteFailure: false); return XCTFail("Both scope denies should persist before removing the exact merged fence") }
            }
            await session.logOut(reportRemoteFailure: false)
        }
    }

    func testUnmatchedRecoveryFenceInstallCannotReplaceExistingPendingNegative() throws {
        let key = "phase4-collision-token-\(UUID())", token = "token-b", prior = "pending-a"
        KeychainStore.set(token, for: key); KeychainStore.set(prior, for: KeychainStore.mediaRecoveryFenceKey)
        defer { KeychainStore.delete(key); KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey) }
        let result = KeychainStore.removeIfMatching(token, for: key, recoveryFence: "pending-b")
        if case .failed = result { } else { XCTFail("An install without matching the prior fence cannot overwrite it or delete the credential") }
        if case .value(let value) = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) { XCTAssertEqual(value, prior) }
        else { XCTFail("Existing pending recovery facts were deleted") }
        if case .value(let value) = KeychainStore.get(key) { XCTAssertEqual(value, token) }
        else { XCTFail("Credential removal preceded a proven durable merged fence") }
    }

    func testOversizedRecoveryFailureBecomesBoundedStickyException() throws {
        let scope = StableMediaScope.verified(server: "https://fixture.invalid/api", accountID: String(repeating: "a", count: 10_000))
        let raw = try XCTUnwrap(MediaRecoveryFence.encoded(scope: scope, credentialScope: "credential"))
        XCTAssertLessThanOrEqual(raw.utf8.count, 8 << 10)
        XCTAssertNil(MediaRecoveryFence.failedScope(raw), "Unrepresentable failure identity cannot be treated as complete positive recovery")
    }

    func testOlderClientFailureStillPersistsScopeFenceWithoutRemovingNewerCredential() throws {
        let a = ImoraClient(apiURL: URL(string: "https://late-recovery.invalid/api")!, accessToken: "old-a")
        a.confirmMediaAccount("old-a-\(UUID())"); defer { a.invalidate() }
        KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey)
        KeychainStore.set("newer-b", for: "accessToken")
        defer { KeychainStore.delete("accessToken"); KeychainStore.delete(KeychainStore.mediaRecoveryFenceKey) }
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-late-failure-\(UUID())")
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        do { try journal.retire(scope: a.mediaDisplayScope, subjects: [.remoteAsset("late-a")]); XCTFail("Read-only retirement wrote unexpectedly") }
        catch let failure as MediaContentGenerations.RetirementFailure { MediaCacheRecovery.handle(client: a, failure: failure) }
        if case .value(let token) = KeychainStore.get("accessToken") { XCTAssertEqual(token, "newer-b") }
        else { XCTFail("Old A recovery removed newer B credential") }
        guard case .value(let raw) = KeychainStore.get(KeychainStore.mediaRecoveryFenceKey) else { return XCTFail("A's negative history must be durable even when B owns the credential") }
        XCTAssertEqual(MediaRecoveryFence.failedScope(raw), a.mediaDisplayScope)
    }

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
