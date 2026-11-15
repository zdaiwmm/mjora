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
}
