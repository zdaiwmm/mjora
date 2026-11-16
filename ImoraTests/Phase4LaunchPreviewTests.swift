import Foundation

#if !LAUNCH_PREVIEW_HARNESS
import XCTest
@testable import Imora
#endif

final class Phase4LaunchPreviewTests: XCTestCase {
    private let scope = StableMediaScope.verified(server: "https://fixture.invalid/api", accountID: "alice")

    private func key(_ id: String, scope: StableMediaScope? = nil, revision: String = "committed:one") -> MediaDisplayKeyV1 {
        MediaDisplayKeyV1(scope: scope ?? self.scope, subject: .remoteAsset(id), sourceRevision: "source:one",
            presentationRevision: revision, variant: .grid, pixelBucket: 64, fitMode: "fill",
            orientationRevision: "up", colorProfile: "sRGB")
    }

    private func snapshot(_ keys: [MediaDisplayKeyV1], anchor: String = "first") -> LaunchViewportSnapshot {
        LaunchViewportSnapshot(scope: keys.first?.scope ?? scope, source: "cloud", filter: "default", sort: "date-desc",
            anchor: anchor, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: keys, metadata: Data("visible asset metadata".utf8))
    }

    private func record(_ key: MediaDisplayKeyV1, content: PreparedImageRecord.Content = .photograph) -> PreparedImageRecord {
        PreparedImageRecord(key: key, bytes: fixturePNG, pixelWidth: 64, pixelHeight: 96, content: content)
    }

    // An actual 64×96 RGB PNG. Native flow tests additionally decode and present it.
    private var fixturePNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAAAp0lEQVR4nO3PQQ0AIBDAsBPBG//ykIAIHg3Jkgno5uz1dcMFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWPHYBkqkxlq2SEToAAAAASUVORK5CYII=")!
    }

    private func context(session: UUID = UUID(), available: Bool = true) -> LaunchContext {
        .init(access: .init(session: session, permission: 1), protectedDataAvailable: available,
              filter: "default", layout: nil)
    }

    private func withStore(_ run: (LaunchPreviewStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-pack-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(LaunchPreviewStore(root: root), root)
    }

    func testCompleteLaunchPackRestoresRealW0() async throws {
        try await withStore { store, root in
            let keys = [key("a"), key("b")]
            _ = try await store.checkpoint(snapshot: snapshot(keys), images: keys.map { record($0) })
            // A new actor represents a process restart, without memory state.
            let read = try await LaunchPreviewStore(root: root).restore(scope: scope, context: context())
            guard case .complete(let restored, let images) = read else { return XCTFail("W0 was not restored") }
            XCTAssertEqual(restored.visibleKeys, keys)
            XCTAssertEqual(images.map(\.bytes), [fixturePNG, fixturePNG])
        }
    }

    func testMetadataOrThumbhashDoesNotCountAsPresented() async throws {
        try await withStore { store, _ in
            let imageKey = key("a")
            do {
                _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey, content: .thumbhash)])
                XCTFail("Thumbhash must never commit a complete pack")
            } catch {}
            let result = try await store.restore(scope: scope, context: context())
            guard case .partial(_, let images, let missing) = result else { return XCTFail("Expected metadata-only partial") }
            XCTAssertTrue(images.isEmpty)
            XCTAssertEqual(missing, [imageKey])
        }
    }

    func testInterruptedCheckpointKeepsPreviousCompletePackAndLatestAnchor() async throws {
        try await withStore { store, root in
            let first = key("a"), latest = key("b")
            let receipt = try await store.checkpoint(snapshot: snapshot([first]), images: [record(first)])
            do { _ = try await store.checkpoint(snapshot: snapshot([latest], anchor: "new-date"), images: []) } catch {}
            let result = try await LaunchPreviewStore(root: root).restore(scope: scope, context: context())
            guard case .partial(let restored, _, let missing) = result else { return XCTFail("Must honor latest anchor") }
            XCTAssertEqual(restored.anchor, "new-date")
            XCTAssertEqual(missing, [latest])
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            XCTAssertTrue(files.contains { $0.contains(receipt.generation.uuidString) }, "Previous complete generation was lost")
        }
    }

    func testNewContextSameVerifiedUserReusesContentWithoutReusingAuthorization() async throws {
        try await withStore { store, _ in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let first = context(), second = context()
            XCTAssertNotEqual(first.access, second.access)
            guard case .complete = try await store.restore(scope: scope, context: second) else {
                return XCTFail("Verified content must survive runtime context rotation")
            }
        }
    }

    func testDifferentAccountSameAssetIDNeverHits() async throws {
        try await withStore { store, _ in
            let imageKey = key("same-id")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let other = StableMediaScope.verified(server: "https://fixture.invalid/api", accountID: "bob")
            guard case .notAvailable = try await store.restore(scope: other, context: context()) else {
                return XCTFail("Another account read Alice's pack")
            }
        }
    }

    func testUnknownIdentityStaysCredentialScoped() async throws {
        try await withStore { store, _ in
            let unknown = StableMediaScope.credential("token-digest-one", server: "fixture")
            let imageKey = key("a", scope: unknown)
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let other = StableMediaScope.credential("token-digest-two", server: "fixture")
            guard case .notAvailable = try await store.restore(scope: other, context: context()) else {
                return XCTFail("Unknown identities were merged across tokens")
            }
            guard case .complete = try await store.restore(scope: unknown, context: context()) else {
                return XCTFail("Same credential lost its own content")
            }
        }
    }

    func testDraftPreviewDoesNotPolluteCommittedPack() async throws {
        try await withStore { store, _ in
            let committed = key("a"), draft = key("a", revision: "draft:session-one")
            _ = try await store.checkpoint(snapshot: snapshot([committed]), images: [record(committed)])
            do { _ = try await store.checkpoint(snapshot: snapshot([committed]), images: [record(draft)]) } catch {}
            guard case .complete(_, let images) = try await store.restore(scope: scope, context: context()) else {
                return XCTFail("Committed pack should survive rejected draft")
            }
            XCTAssertEqual(images.map(\.key), [committed])
        }
    }

    func testProtectedOrLockedContentIsExcluded() async throws {
        try await withStore { store, _ in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            guard case .invalid = try await store.restore(scope: scope, context: context(available: false)) else {
                return XCTFail("Protected data must not be read")
            }
            do {
                _ = try await store.checkpoint(snapshot: snapshot([key("locked")]), images: [record(key("locked"), content: .protected)])
                XCTFail("Locked content entered ordinary pack")
            } catch {}
        }
    }

    func testArbitraryBytesCannotCommitARealPreviewPack() async throws {
        try await withStore { store, _ in
            let imageKey = key("a")
            let invalid = PreparedImageRecord(key: imageKey, bytes: Data([1, 2, 3, 4]), pixelWidth: 64, pixelHeight: 96, content: .photograph)
            do {
                _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [invalid])
                XCTFail("A photograph label is not evidence of encoded image pixels")
            } catch {}
        }
    }

    func testKnownSmallNativeFinalImageKeepsRequestedKeyAndCompletesPack() async throws {
        try await withStore { store, _ in
            let imageKey = MediaDisplayKeyV1(scope: scope, subject: .localAsset(installationID: "fixture-install", localIdentifier: "small-source"),
                sourceRevision: "native-revision-one", presentationRevision: "committed:one", variant: .grid,
                pixelBucket: 416, fitMode: "fit-cover", orientationRevision: "up", colorProfile: "sRGB")
            let image = PreparedImageRecord(key: imageKey, bytes: fixturePNG, pixelWidth: 64, pixelHeight: 96,
                content: .photograph, nativeResolution: .init(sourceRevision: "native-revision-one", pixelWidth: 64, pixelHeight: 96))
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [image])
            guard case .complete(_, let restored) = try await store.restore(scope: scope, context: context()) else {
                return XCTFail("A real source-resolution final image must not be permanently ineligible")
            }
            XCTAssertEqual(restored.first?.key.pixelBucket, 416)
            XCTAssertEqual(restored.first?.pixelWidth, 64)
        }
    }

    func testSmallDerivativeOrUnboundNativeDimensionsNeverClaimAdequacy() {
        let local = MediaDisplayKeyV1(scope: scope, subject: .localAsset(installationID: "fixture", localIdentifier: "a"),
            sourceRevision: "revision-one", presentationRevision: "committed:one", variant: .grid, pixelBucket: 416,
            fitMode: "fit-cover", orientationRevision: "up", colorProfile: "sRGB")
        let insufficient = PreparedImageRecord(key: local, bytes: fixturePNG, pixelWidth: 64, pixelHeight: 96,
            content: .photograph, nativeResolution: .init(sourceRevision: "revision-one", pixelWidth: 640, pixelHeight: 960))
        XCTAssertFalse(insufficient.isQualified)
        let stale = PreparedImageRecord(key: local, bytes: fixturePNG, pixelWidth: 64, pixelHeight: 96,
            content: .photograph, nativeResolution: .init(sourceRevision: "revision-two", pixelWidth: 64, pixelHeight: 96))
        XCTAssertFalse(stale.isQualified)
        let remote = PreparedImageRecord(key: key("remote"), bytes: fixturePNG, pixelWidth: 64, pixelHeight: 96,
            content: .thumbhash, nativeResolution: .init(sourceRevision: "source:one", pixelWidth: 64, pixelHeight: 96))
        XCTAssertFalse(remote.isQualified)
    }

    func testCorruptImageIsAPartialMissAtTheSameAnchor() async throws {
        try await withStore { store, root in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey], anchor: "same-date"), images: [record(imageKey)])
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            let imageFile = files.compactMap { $0 as? URL }.first { $0.lastPathComponent == imageKey.digest }!
            try Data([9, 9, 9]).write(to: imageFile)
            guard case .partial(let restored, let images, let missing) = try await store.restore(scope: scope, context: context()) else {
                return XCTFail("Corrupt bytes were treated as a complete pack")
            }
            XCTAssertEqual(restored.anchor, "same-date")
            XCTAssertEqual(missing, [imageKey])
            XCTAssertTrue(images.isEmpty)
        }
    }

    func testCorruptManifestDoesNotDeleteUnrelatedDraftOrOriginal() async throws {
        try await withStore { store, root in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let unrelated = root.deletingLastPathComponent().appending(path: "draft-original-\(UUID())")
            defer { try? FileManager.default.removeItem(at: unrelated) }
            try Data("original and draft must survive".utf8).write(to: unrelated)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            let manifest = files.compactMap { $0 as? URL }.first { $0.lastPathComponent == "complete.json" }!
            try Data("broken".utf8).write(to: manifest)
            guard case .invalid = try await store.restore(scope: scope, context: context()) else { return XCTFail("Expected invalid manifest") }
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("original and draft must survive".utf8))
        }
    }

    func testDifferentLayoutDoesNotClaimCompleteW0() async throws {
        try await withStore { store, _ in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let changed = LaunchContext(access: .init(session: UUID(), permission: 1), protectedDataAvailable: true,
                filter: "default", layout: .init(width: 820, height: 700, scale: 2, columns: 5))
            guard case .partial(let restored, _, _) = try await store.restore(scope: scope, context: changed) else {
                return XCTFail("A different viewport geometry was falsely complete")
            }
            XCTAssertEqual(restored.anchor, "first")
        }
    }

    func testOversizePackKeepsPreviousGenerationAndLatestAnchor() async throws {
        try await withStore { store, root in
            let first = key("a"), latest = key("b")
            let receipt = try await store.checkpoint(snapshot: snapshot([first]), images: [record(first)])
            var bytes = fixturePNG
            bytes.append(Data(repeating: 0, count: 32 << 20))
            let large = PreparedImageRecord(key: latest, bytes: bytes, pixelWidth: 64, pixelHeight: 96, content: .photograph)
            do { _ = try await store.checkpoint(snapshot: snapshot([latest], anchor: "latest"), images: [large]); XCTFail("Budget exceeded") } catch {}
            guard case .partial(let restored, _, _) = try await store.restore(scope: scope, context: context()) else {
                return XCTFail("Expected checkpoint miss")
            }
            XCTAssertEqual(restored.anchor, "latest")
            XCTAssertTrue(try FileManager.default.subpathsOfDirectory(atPath: root.path).contains { $0.contains(receipt.generation.uuidString) })
        }
    }

    func testRestartReclaimsAbandonedGenerationsBeforeReadingOrAllocating() async throws {
        try await withStore { store, root in
            let imageKey = key("a")
            _ = try await store.checkpoint(snapshot: snapshot([imageKey]), images: [record(imageKey)])
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            let scopeDirectory = files.compactMap { $0 as? URL }.first { $0.lastPathComponent == "complete.json" }!.deletingLastPathComponent()
            // Emulate processes killed after staging bytes, so no actor defer runs.
            for _ in 0..<3 {
                let orphan = scopeDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 12 << 20).write(to: orphan.appending(path: "abandoned-preview"))
            }
            let restart = LaunchPreviewStore(root: root)
            guard case .complete = try await restart.restore(scope: scope, context: context()) else {
                return XCTFail("Recovery must retain the last committed pack")
            }
            let usage = await restart.diskUsage()
            XCTAssertTrue(usage <= 32 << 20, "Abandoned generations escaped the global reserve: \(usage)")
            let remaining = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            XCTAssertFalse(remaining.contains { $0.contains("abandoned-preview") })
        }
    }

    func testReplacementCannotAllocateBeyondQuotaWhilePreviousPackSurvives() async throws {
        try await withStore { store, root in
            let first = key("a"), latest = key("b")
            var large = fixturePNG
            large.append(Data(repeating: 0, count: 17 << 20))
            let previous = PreparedImageRecord(key: first, bytes: large, pixelWidth: 64, pixelHeight: 96, content: .photograph)
            let receipt = try await store.checkpoint(snapshot: snapshot([first]), images: [previous])
            let incoming = PreparedImageRecord(key: latest, bytes: large, pixelWidth: 64, pixelHeight: 96, content: .photograph)
            do {
                _ = try await store.checkpoint(snapshot: snapshot([latest], anchor: "latest"), images: [incoming])
                XCTFail("Two disjoint 17 MiB generations cannot coexist in a 32 MiB reserve")
            } catch {}
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            XCTAssertTrue(files.contains { $0.contains(receipt.generation.uuidString) }, "Previous complete pack was discarded to make room")
            guard case .partial(let saved, _, _) = try await LaunchPreviewStore(root: root).restore(scope: scope, context: context()) else {
                return XCTFail("Latest anchor must record a quota checkpoint miss")
            }
            XCTAssertEqual(saved.anchor, "latest")
            let usage = await store.diskUsage()
            XCTAssertTrue(usage <= 32 << 20)
        }
    }

    func testRetirementJournalSurvivesRestartWithoutChangingOtherSubjects() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let first = MediaDisplayKeyV1.Subject.remoteAsset("first"), other = MediaDisplayKeyV1.Subject.remoteAsset("other")
        let before = journal.current(scope: scope, subject: first)
        let unaffected = journal.current(scope: scope, subject: other)
        try journal.retire(scope: scope, subjects: [first])
        let restart = MediaContentGenerations(root: root)
        XCTAssertNotEqual(restart.current(scope: scope, subject: first), before)
        XCTAssertEqual(restart.current(scope: scope, subject: other), unaffected)
        XCTAssertFalse(restart.canMigrateLegacy(scope: scope, subject: first))
    }

    func testNamespaceOnlyRetirementHonorsSavedKeysWithoutErasingKnownEditTombstones() async throws {
        try await withStore { store, root in
            let saved = key("pair-change")
            _ = try await store.checkpoint(snapshot: snapshot([saved]), images: [record(saved)])
            let journal = MediaContentGenerations(root: root)
            try journal.ensureInitialized()
            let before = journal.current(scope: scope, subject: saved.subject)
            try journal.retire(scope: scope, subjects: [saved.subject], keys: [saved], retiresSourceRevisions: false)
            let restarted = MediaContentGenerations(root: root)
            XCTAssertNotEqual(restarted.current(scope: scope, subject: saved.subject), before)
            XCTAssertFalse(restarted.isRetired(scope: scope, subject: saved.subject, sourceRevision: saved.sourceRevision),
                "Namespace policy applies to explicit AND latest.json source keys")
            XCTAssertFalse(restarted.canMigrateLegacy(scope: scope, subject: saved.subject))
            try restarted.retire(scope: scope, subjects: [saved.subject])
            XCTAssertTrue(restarted.isRetired(scope: scope, subject: saved.subject, sourceRevision: saved.sourceRevision),
                "A genuine known edit still retires the source contributed by the saved viewport")
            try restarted.retire(scope: scope, subjects: [saved.subject], retiresSourceRevisions: false)
            XCTAssertTrue(MediaContentGenerations(root: root).isRetired(scope: scope, subject: saved.subject,
                sourceRevision: saved.sourceRevision), "Later namespace rotation cannot resurrect a committed old revision")
        }
    }

    func testInterruptedOrCorruptJournalNeverReturnsToAnOldNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let subject = MediaDisplayKeyV1.Subject.remoteAsset("first")
        let original = journal.current(scope: scope, subject: subject)
        try journal.retire(scope: scope, subjects: [subject])
        try Data("interrupted new journal bytes".utf8).write(to: root.appending(path: ".content-generations-staging"))
        let restarted = MediaContentGenerations(root: root)
        XCTAssertNotEqual(restarted.current(scope: scope, subject: subject), original)
        try Data("corrupt committed journal".utf8).write(to: root.appending(path: "content-generations.json"))
        let corrupt = MediaContentGenerations(root: root)
        XCTAssertNil(corrupt.current(scope: scope, subject: subject))
        try corrupt.ensureInitialized()
        XCTAssertNotEqual(corrupt.current(scope: scope, subject: subject), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ".content-generations-staging").path))
    }

    func testAccessBlockRequiresCurrentProofAcrossRestartAndRolloverWithoutRevivingEdits() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-access-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root), subject = MediaDisplayKeyV1.Subject.remoteAsset("blocked")
        try journal.ensureInitialized()
        let old = journal.current(scope: scope, subject: subject)!
        try journal.retire(scope: scope, subjects: [subject], retiresSourceRevisions: false, blocksAccess: true)
        let proof = journal.captureAccess(scope: scope)
        let blockedGeneration = journal.current(scope: scope, subject: subject)!
        XCTAssertFalse(journal.isCurrent(scope: scope, subject: subject, sourceRevision: "R", generation: blockedGeneration))
        let restart = MediaContentGenerations(root: root)
        try restart.rollover()
        XCTAssertFalse(restart.isCurrent(scope: scope, subject: subject, sourceRevision: "R", generation: restart.current(scope: scope, subject: subject)!))
        XCTAssertFalse(try restart.authorize(scope: scope, subject: subject, sourceRevision: "R", captured: proof), "An old readback cannot survive an intervening namespace change")
        let edited = MediaDisplayKeyV1(scope: scope, subject: subject, sourceRevision: "R", presentationRevision: "committed:R",
            variant: .grid, pixelBucket: 64, fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB")
        try restart.retire(scope: scope, subjects: [subject], keys: [edited])
        let currentProof = restart.captureAccess(scope: scope)
        XCTAssertFalse(try restart.authorize(scope: scope, subject: subject, sourceRevision: "R", captured: currentProof), "Positive visibility never deletes a committed-edit tombstone")
        XCTAssertTrue(try restart.authorize(scope: scope, subject: subject, sourceRevision: "new-R", captured: currentProof))
        let final = MediaContentGenerations(root: root), generation = final.current(scope: scope, subject: subject)!
        XCTAssertNotEqual(old, generation)
        XCTAssertTrue(final.isCurrent(scope: scope, subject: subject, sourceRevision: "new-R", generation: generation))
        XCTAssertFalse(final.isCurrent(scope: scope, subject: subject, sourceRevision: "R", generation: generation))
        XCTAssertFalse(final.canMigrateLegacy(scope: scope, subject: subject))
        XCTAssertFalse(final.isCurrent(scope: scope, subject: subject, sourceRevision: "new-R", generation: blockedGeneration))
    }

    func testFailedPositivePublicationKeepsPersistedAccessBlock() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-positive-write-failure-\(UUID())")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let journal = MediaContentGenerations(root: root), subject = MediaDisplayKeyV1.Subject.remoteAsset("denied")
        try journal.ensureInitialized()
        try journal.retire(scope: scope, subjects: [subject], retiresSourceRevisions: false, blocksAccess: true)
        let proof = journal.captureAccess(scope: scope), generation = journal.current(scope: scope, subject: subject)!
        let file = root.appending(path: "content-generations.json"), original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try journal.authorize(scope: scope, subject: subject, sourceRevision: "R",
            captured: proof, visibilityPolicy: "timeline"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(journal.isCurrent(scope: scope, subject: subject, sourceRevision: "R", generation: generation, visibilityPolicy: "timeline"))
        XCTAssertFalse(MediaContentGenerations(root: root).isCurrent(scope: scope, subject: subject,
            sourceRevision: "R", generation: generation, visibilityPolicy: "timeline"))
    }

    func test513ProtectedSubjectsPreserveAvailabilityAndNegativeHistoryAcrossRestart() throws {
        try checkCapacityBoundary(count: 513, separateScopes: false)
    }

    func test65ProtectedScopesPreserveAvailabilityAndNegativeHistoryAcrossRestart() throws {
        try checkCapacityBoundary(count: 65, separateScopes: true)
    }

    func testActualByteHighWaterFoldsToDefaultDenyAndFreshProofRestoresOnlyCurrentSubject() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-byte-fold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let edited = MediaDisplayKeyV1.Subject.remoteAsset("edited")
        let old = key("edited")
        try journal.retire(scope: scope, subjects: [edited], keys: [old])
        let oldProof = journal.captureAccess(scope: scope)
        let unknown = MediaDisplayKeyV1.Subject.remoteAsset("not-in-any-prior-response")
        let oldUnknown = try XCTUnwrap(journal.current(scope: scope, subject: unknown))
        let blocked = (0..<6_000).map { MediaDisplayKeyV1.Subject.remoteAsset("subject-\($0)") }
        try journal.retire(scope: scope, subjects: blocked, retiresSourceRevisions: false, blocksAccess: true)
        let file = root.appending(path: "content-generations.json")
        let bytes = try Data(contentsOf: file).count
        XCTAssertLessThan(bytes, 768 << 10, "Real byte pressure folds recoverable records rather than retaining an oversized journal")
        let restart = MediaContentGenerations(root: root)
        for candidate in [journal, restart] {
            XCTAssertTrue(candidate.isRetired(scope: scope, subject: edited, sourceRevision: old.sourceRevision))
            XCTAssertFalse(candidate.isCurrent(scope: scope, subject: unknown, sourceRevision: "R", generation: oldUnknown))
            let current = try XCTUnwrap(candidate.current(scope: scope, subject: unknown))
            XCTAssertFalse(candidate.isCurrent(scope: scope, subject: unknown, sourceRevision: "R", generation: current))
            XCTAssertFalse(candidate.canMigrateLegacy(scope: scope, subject: unknown))
            let proof = candidate.captureAccess(scope: scope)
            XCTAssertFalse(proof.isEmpty, "A default-deny scope is proof-requiring even without explicit subject records")
            XCTAssertTrue(proof.needsConfirmation(subject: unknown, visibilityPolicy: "timeline"))
            XCTAssertFalse(try candidate.authorize(scope: scope, subject: edited, sourceRevision: "new-R", captured: oldProof, visibilityPolicy: "timeline"))
        }
        XCTAssertTrue(try restart.authorize(scope: scope, subject: unknown, sourceRevision: "R",
            captured: restart.captureAccess(scope: scope), visibilityPolicy: "timeline"))
        let after = MediaContentGenerations(root: root)
        XCTAssertTrue(after.isCurrent(scope: scope, subject: unknown, sourceRevision: "R",
            generation: after.current(scope: scope, subject: unknown)!, visibilityPolicy: "timeline"))
        let stillDenied = blocked[0]
        XCTAssertFalse(after.isCurrent(scope: scope, subject: stillDenied, sourceRevision: "R",
            generation: after.current(scope: scope, subject: stillDenied)!, visibilityPolicy: "timeline"))
        let other = StableMediaScope.verified(server: "https://other.invalid", accountID: "other")
        XCTAssertTrue(after.isCurrent(scope: other, subject: unknown, sourceRevision: "R", generation: after.current(scope: other, subject: unknown)!))
    }

    func testPositivePolicyGrowthAlsoFoldsAtActualByteHighWater() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-positive-fold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let subjects = (0..<4_600).map { MediaDisplayKeyV1.Subject.remoteAsset("subject-\($0)") }
        try journal.retire(scope: scope, subjects: subjects, retiresSourceRevisions: false, blocksAccess: true)
        let unknown = MediaDisplayKeyV1.Subject.remoteAsset("unlisted")
        let old = try XCTUnwrap(journal.current(scope: scope, subject: unknown))
        var last: MediaDisplayKeyV1.Subject?
        for subject in subjects.prefix(1_000) {
            XCTAssertTrue(try journal.authorize(scope: scope, subject: subject, sourceRevision: "R",
                captured: journal.captureAccess(scope: scope), visibilityPolicy: "timeline"))
            last = subject
            if journal.current(scope: scope, subject: unknown) != old { break }
        }
        XCTAssertNotEqual(journal.current(scope: scope, subject: unknown), old, "Positive canonical policy growth must use the same bounded scope folding path")
        let bytes = try Data(contentsOf: root.appending(path: "content-generations.json")).count
        XCTAssertLessThan(bytes, 768 << 10)
        let restarted = MediaContentGenerations(root: root), lastSubject = try XCTUnwrap(last)
        XCTAssertTrue(restarted.isCurrent(scope: scope, subject: lastSubject, sourceRevision: "R", generation: restarted.current(scope: scope, subject: lastSubject)!, visibilityPolicy: "timeline"))
        XCTAssertFalse(restarted.isCurrent(scope: scope, subject: unknown, sourceRevision: "R", generation: restarted.current(scope: scope, subject: unknown)!))
    }

    #if DEBUG
    func testIsolatedFixtureRestoreRefusesToOverwriteUnrelatedJournalChanges() throws {
        for fresh in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "phase4-fixture-boundary-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = MediaContentGenerations(root: root)
            let owned = StableMediaScope.verified(server: "https://fixture.invalid", accountID: "owned")
            let other = StableMediaScope.verified(server: "https://fixture.invalid", accountID: "other")
            let restore = try journal.isolatedFixtureRestorer(scopes: [owned], freshCapacityNamespace: fresh)
            try journal.retire(scope: owned, subjects: [.remoteAsset("fixture")], retiresSourceRevisions: false, blocksAccess: true)
            let unrelated = key("unrelated", scope: other)
            try journal.retire(scope: other, subjects: [unrelated.subject], keys: [unrelated])
            let file = root.appending(path: "content-generations.json"), before = try Data(contentsOf: file)
            XCTAssertThrowsError(try restore())
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertTrue(MediaContentGenerations(root: root).isRetired(scope: other, subject: unrelated.subject, sourceRevision: unrelated.sourceRevision))
        }
    }

    func testIsolatedFixtureRestoresAbsentJournalAndPriorMemory() throws {
        for fresh in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "phase4-fixture-absence-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = MediaContentGenerations(root: root)
            let owned = StableMediaScope.verified(server: "https://fixture.invalid", accountID: "owned")
            let restore = try journal.isolatedFixtureRestorer(scopes: [owned], freshCapacityNamespace: fresh)
            try journal.retire(scope: owned, subjects: [.remoteAsset("fixture")], retiresSourceRevisions: false, blocksAccess: true)
            try restore()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "content-generations.json").path))
            XCTAssertEqual(journal.current(scope: owned, subject: .remoteAsset("fixture")), "")
        }
    }
    #endif

    func testRepresentableEditHistoryDoesNotInvalidateAnotherScopesSharedReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-scope-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let history = (0..<150).map { MediaDisplayKeyV1.Subject.remoteAsset("edited-asset-\($0)") }
        let revisions = (0..<180).map { Data(String(format: "revision-%010d", $0).utf8).base64EncodedString() }
        let oldKeys = history.flatMap { subject in
            revisions.map { revision in
                MediaDisplayKeyV1(scope: scope, subject: subject, sourceRevision: revision, presentationRevision: revision,
                    variant: .grid, pixelBucket: 64, fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB",
                    contentGeneration: "synthetic-old-producer")
            }
        }
        try journal.retire(scope: scope, subjects: history, keys: oldKeys)
        let bytes = try Data(contentsOf: root.appending(path: "content-generations.json")).count
        print("TASK17_FIX4 isolated journal bytes=\(bytes), synthetic retired revisions=\(oldKeys.count)")
        XCTAssertGreaterThan(bytes, 768 << 10)
        XCTAssertLessThan(bytes, (1 << 20) - 16_384)

        let healthy = StableMediaScope.verified(server: "https://healthy.invalid/api", accountID: "bob")
        let unrelated = MediaDisplayKeyV1.Subject.remoteAsset("already-visible")
        let unrelatedGeneration = try XCTUnwrap(journal.current(scope: healthy, subject: unrelated))
        func exercise(_ candidate: MediaContentGenerations, suffix: String) throws {
            let subjects = (0..<3).map { MediaDisplayKeyV1.Subject.remoteAsset("bucket-\(suffix)-\($0)") }
            let receipt = candidate.captureAccess(scope: healthy, requiringScopeProof: true)
            for subject in subjects {
                XCTAssertTrue(try candidate.authorize(scope: healthy, subject: subject, sourceRevision: "current",
                    captured: receipt, visibilityPolicy: "locked"), "A single authenticated bucket must grant each item")
            }
            for subject in subjects {
                let current = try XCTUnwrap(candidate.current(scope: healthy, subject: subject))
                XCTAssertTrue(candidate.isCurrent(scope: healthy, subject: subject, sourceRevision: "current",
                    generation: current, visibilityPolicy: "locked"), "A later grant must not revoke an earlier item")
            }
            let oldProducer = try XCTUnwrap(candidate.current(scope: healthy, subject: subjects[0]))
            try candidate.retire(scope: healthy, subjects: [subjects[0]], retiresSourceRevisions: false, blocksAccess: true)
            XCTAssertFalse(candidate.isCurrent(scope: healthy, subject: subjects[0], sourceRevision: "current",
                generation: oldProducer, visibilityPolicy: "locked"))
            XCTAssertTrue(candidate.isCurrent(scope: healthy, subject: unrelated, sourceRevision: "public",
                generation: unrelatedGeneration), "A negative in B cannot rotate unrelated B surfaces")
            let last = try XCTUnwrap(candidate.current(scope: healthy, subject: subjects[2]))
            XCTAssertTrue(candidate.isCurrent(scope: healthy, subject: subjects[2], sourceRevision: "current",
                generation: last, visibilityPolicy: "locked"))
            XCTAssertTrue(candidate.isRetired(scope: scope, subject: history[0], sourceRevision: revisions[0]))
            XCTAssertTrue(candidate.isRetired(scope: scope, subject: history[149], sourceRevision: revisions[179]))
        }
        try exercise(journal, suffix: "first")
        try exercise(MediaContentGenerations(root: root), suffix: "restart")
        let restarted = MediaContentGenerations(root: root)
        XCTAssertTrue(restarted.isRetired(scope: scope, subject: history[0], sourceRevision: revisions[0]))
        XCTAssertFalse(restarted.isCurrent(scope: healthy, subject: .remoteAsset("bucket-first-0"), sourceRevision: "current",
            generation: restarted.current(scope: healthy, subject: .remoteAsset("bucket-first-0")) ?? "missing", visibilityPolicy: "locked"))
        let many = (0..<2_500).map { MediaDisplayKeyV1.Subject.remoteAsset("real-pressure-\($0)") }
        try restarted.retire(scope: healthy, subjects: many, retiresSourceRevisions: false, blocksAccess: true)
        XCTAssertNotEqual(restarted.current(scope: healthy, subject: unrelated), unrelatedGeneration,
            "Scope B can still fold when its own recoverable records exhaust the actual write budget")
        let fresh = restarted.captureAccess(scope: healthy, requiringScopeProof: true)
        for subject in many.prefix(3) {
            XCTAssertTrue(try restarted.authorize(scope: healthy, subject: subject, sourceRevision: "current",
                captured: fresh, visibilityPolicy: "locked"))
        }
        for subject in many.prefix(3) {
            XCTAssertTrue(restarted.isCurrent(scope: healthy, subject: subject, sourceRevision: "current",
                generation: restarted.current(scope: healthy, subject: subject) ?? "missing", visibilityPolicy: "locked"))
        }
        XCTAssertTrue(restarted.isRetired(scope: scope, subject: history[0], sourceRevision: revisions[0]))
    }

    func testUnrepresentableEditHistoryKeepsDurableFactsAndDeniesOnlyAffectedScope() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-negative-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        let subject = MediaDisplayKeyV1.Subject.remoteAsset("edited")
        func revision(_ text: String) -> MediaDisplayKeyV1 {
            MediaDisplayKeyV1(scope: scope, subject: subject, sourceRevision: text, presentationRevision: text,
                variant: .grid, pixelBucket: 64, fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB")
        }
        let old = String(repeating: "a", count: 600_000)
        try journal.retire(scope: scope, subjects: [subject], keys: [revision(old)])
        XCTAssertThrowsError(try journal.retire(scope: scope, subjects: [subject], keys: [revision(String(repeating: "b", count: 600_000))]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "content-generations.json").path))
        for candidate in [journal, MediaContentGenerations(root: root)] {
            XCTAssertTrue(candidate.isRetired(scope: scope, subject: subject, sourceRevision: old))
            let unknown = MediaDisplayKeyV1.Subject.remoteAsset("unknown")
            XCTAssertFalse(candidate.isCurrent(scope: scope, subject: unknown, sourceRevision: "R", generation: candidate.current(scope: scope, subject: unknown) ?? "missing"))
            XCTAssertFalse(try candidate.authorize(scope: scope, subject: unknown, sourceRevision: "R", captured: candidate.captureAccess(scope: scope), visibilityPolicy: "timeline"))
            let other = StableMediaScope.verified(server: "https://other.invalid", accountID: "other")
            XCTAssertTrue(candidate.isCurrent(scope: other, subject: unknown, sourceRevision: "R", generation: candidate.current(scope: other, subject: unknown) ?? "missing"))
        }
    }

    func testRetirementIOFailurePreservesOldJournalAndRequiresCheckedCredentialRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-negative-io-\(UUID())")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let journal = MediaContentGenerations(root: root), subject = MediaDisplayKeyV1.Subject.remoteAsset("edited")
        try journal.ensureInitialized()
        try journal.retire(scope: scope, subjects: [subject], keys: [key("edited")])
        let file = root.appending(path: "content-generations.json"), durable = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try journal.retire(scope: scope, subjects: [.remoteAsset("new-block")], retiresSourceRevisions: false, blocksAccess: true)) { error in
            XCTAssertEqual((error as? MediaContentGenerations.RetirementFailure)?.journalRemovalSucceeded, false)
        }
        XCTAssertEqual(try Data(contentsOf: file), durable)
        XCTAssertNil(journal.current(scope: scope, subject: subject), "Until checked credential recovery, an unpersisted deny cannot publish")
        XCTAssertTrue(MediaContentGenerations(root: root).isRetired(scope: scope, subject: subject, sourceRevision: key("edited").sourceRevision))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try journal.ensureInitialized()
        let pendingSubject = MediaDisplayKeyV1.Subject.remoteAsset("new-block")
        XCTAssertFalse(journal.isCurrent(scope: scope, subject: pendingSubject, sourceRevision: "R",
            generation: journal.current(scope: scope, subject: pendingSubject) ?? "missing"), "Protected-data reinitialization must persist the pending scope deny, never restore pre-failure authority")
        try journal.recoverDurability(scope: scope)
        let recovered = MediaContentGenerations(root: root), unknown = MediaDisplayKeyV1.Subject.remoteAsset("new-block")
        XCTAssertTrue(recovered.isRetired(scope: scope, subject: subject, sourceRevision: key("edited").sourceRevision))
        XCTAssertFalse(recovered.isCurrent(scope: scope, subject: unknown, sourceRevision: "R", generation: recovered.current(scope: scope, subject: unknown)!))
        XCTAssertFalse(try recovered.authorize(scope: scope, subject: unknown, sourceRevision: "R", captured: recovered.captureAccess(scope: scope)))
        let other = StableMediaScope.verified(server: "https://other.invalid", accountID: "other")
        XCTAssertTrue(recovered.isCurrent(scope: other, subject: unknown, sourceRevision: "R", generation: recovered.current(scope: other, subject: unknown)!))
    }

    private func checkCapacityBoundary(count: Int, separateScopes: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MediaContentGenerations(root: root)
        try journal.ensureInitialized()
        var denied: [(StableMediaScope, MediaDisplayKeyV1.Subject)] = []
        var firstFailure: Int?
        let allowedScope = StableMediaScope.verified(server: "https://capacity.invalid/api", accountID: "capacity-0")
        let allowed = MediaDisplayKeyV1.Subject.remoteAsset("subject-0")
        for index in 0..<count {
            let account = separateScopes ? "capacity-\(index)" : "capacity-0"
            let scope = StableMediaScope.verified(server: "https://capacity.invalid/api", accountID: account)
            let subject = MediaDisplayKeyV1.Subject.remoteAsset("subject-\(index)")
            do {
                try journal.retire(scope: scope, subjects: [subject], retiresSourceRevisions: false, blocksAccess: true)
                if index == 0 {
                    XCTAssertTrue(try journal.authorize(scope: scope, subject: subject, sourceRevision: "current-R",
                        captured: journal.captureAccess(scope: scope), visibilityPolicy: "timeline"))
                } else {
                    denied.append((scope, subject))
                    if index == 1 {
                        let generation = try XCTUnwrap(journal.current(scope: scope, subject: subject))
                        let old = MediaDisplayKeyV1(scope: scope, subject: subject, sourceRevision: "old-R",
                            presentationRevision: "committed:old-R", variant: .grid, pixelBucket: 64,
                            fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB", contentGeneration: generation)
                        try journal.retire(scope: scope, subjects: [subject], keys: [old])
                    }
                }
            } catch { firstFailure = index; break }
        }
        XCTAssertNil(firstFailure, "Ordinary retained records fit the byte budget; arbitrary count saturation must not poison the global journal")
        func assertState(_ candidate: MediaContentGenerations, _ stage: String) {
            let available = candidate.current(scope: allowedScope, subject: allowed)
            XCTAssertNotNil(available, stage + ": unrelated allowed namespace remains available")
            XCTAssertTrue(candidate.isCurrent(scope: allowedScope, subject: allowed, sourceRevision: "current-R",
                generation: available ?? "unavailable", visibilityPolicy: "timeline"), stage)
            XCTAssertTrue(denied.allSatisfy { scope, subject in
                !candidate.isCurrent(scope: scope, subject: subject, sourceRevision: "R",
                    generation: candidate.current(scope: scope, subject: subject) ?? "unavailable", visibilityPolicy: "timeline")
            }, stage + ": prior access denials remain enforced")
            XCTAssertTrue(denied.allSatisfy { !candidate.canMigrateLegacy(scope: $0.0, subject: $0.1) }, stage + ": epoch0 imports remain excluded")
            if let first = denied.first {
                XCTAssertTrue(candidate.isRetired(scope: first.0, subject: first.1, sourceRevision: "old-R"), stage + ": true edit history survives")
            }
        }
        assertState(journal, "after boundary")
        XCTAssertNoThrow(try journal.ensureInitialized())
        XCTAssertNoThrow(try journal.rollover())
        assertState(journal, "after recovery/rollover")
        let restart = MediaContentGenerations(root: root)
        XCTAssertNoThrow(try restart.ensureInitialized())
        assertState(restart, "after restart")
    }
}
