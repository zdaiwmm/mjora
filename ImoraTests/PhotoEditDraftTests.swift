import XCTest
@testable import Imora

@MainActor
final class PhotoEditDraftTests: XCTestCase {
    private let scope = StableMediaScope.verified(server: "https://draft.invalid/api", accountID: "account-a")
    private func binding(revision: String = "original-r1", mode: String = "unified") -> PhotoEditDraft.Binding {
        .init(scope: scope, subject: "remote:photo-a", sourceRevision: revision, width: 400, height: 300, mode: mode)
    }
    private func snapshot() -> EditSnapshot {
        var state = EditTransform.State()
        state.crop = .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        state.rotation = 270; state.flipV = true
        var adjust = PhotoAdjust.neutral
        adjust.exposure = 31; adjust.highlights = -20; adjust.straighten = 9
        return .init(state: state, adjust: adjust, disabledTools: [.highlights], aspect: .ratio(4, 3),
            isPortrait: true, removesPreservedEdits: true)
    }
    private func store() -> PhotoEditDraftStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-tests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(root: root)
    }

    func testEditingIntentSurvivesNewStoreAndExplicitDiscard() throws {
        let store = store()
        let draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        try store.write(draft)
        let reopened = PhotoEditDraftStore(root: store.root)
        let stored = try XCTUnwrap(reopened.load(scope: scope, subject: draft.binding.subject))
        guard case .editing(let recovered) = try stored.recover(binding: binding(), current: draft.baseline) else {
            return XCTFail("An unfinished edit must remain editable")
        }
        XCTAssertEqual(recovered.snapshot, snapshot())
        XCTAssertEqual(recovered.id, draft.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).count, 1)
        try reopened.remove(scope: scope, subject: draft.binding.subject)
        XCTAssertNil(try store.load(scope: scope, subject: draft.binding.subject))
    }

    func testAccountServerAndPhotoIsolationAndNoCredentialFallback() throws {
        let store = store(), draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        try store.write(draft)
        for other in [StableMediaScope.verified(server: scope.serverIdentity, accountID: "account-b"),
                      .verified(server: "https://other.invalid/api", accountID: "account-a")] {
            XCTAssertNil(try store.load(scope: other, subject: draft.binding.subject))
        }
        XCTAssertNil(try store.load(scope: scope, subject: "remote:photo-b"))
        XCTAssertThrowsError(try store.load(scope: .credential("secret", server: scope.serverIdentity), subject: draft.binding.subject))
        XCTAssertEqual(try store.load(scope: scope, subject: draft.binding.subject), draft)
    }

    func testSourceProtocolAndConcurrentEditChangesKeepDraftWithoutApplyingIt() throws {
        let store = store(), draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        try store.write(draft)
        for changed in [binding(revision: "original-r2"), binding(mode: "legacy")] {
            XCTAssertThrowsError(try draft.recover(binding: changed, current: draft.baseline))
        }
        XCTAssertThrowsError(try draft.recover(binding: binding(), current: .init(edits: [.rotate(angle: 90)], adjust: nil)))
        XCTAssertEqual(try store.load(scope: scope, subject: draft.binding.subject), draft)
    }

    func testCommittedAtomicIntentAfterProcessDeathIsConfirmedWithoutAnotherWrite() async throws {
        let store = store(), intent: [AssetEdit] = [.rotate(angle: 270), try .photo(snapshot().adjust)]
        var draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        draft.submission = .init(edits: intent, adjust: nil, snapshot: draft.snapshot)
        try store.write(draft) // process dies after the server commits, before cleanup
        var writes = 0
        try await PhotoEditPersistence.saveAtomic(intent: intent, write: { _ in writes += 1; throw URLError(.networkConnectionLost) }, read: { intent })
        let restored = try XCTUnwrap(PhotoEditDraftStore(root: store.root).load(scope: scope, subject: draft.binding.subject))
        guard case .saved = try restored.recover(binding: binding(), current: .init(edits: intent, adjust: nil)) else {
            return XCTFail("Authoritative full intent must confirm the interrupted save")
        }
        XCTAssertEqual(writes, 1)
        try store.remove(scope: scope, subject: draft.binding.subject)
        XCTAssertNil(try store.load(scope: scope, subject: draft.binding.subject))
    }

    func testUnsubmittedIntentAndLegacyPartialCommitRemainExplicitlyRetryable() throws {
        let store = store(), baseline = PhotoEditDraft.Version(edits: [], adjust: .neutral)
        var desired = ImageAdjust.neutral; desired.exposure = 31
        var draft = PhotoEditDraft(binding: binding(mode: "legacy"), baseline: baseline, snapshot: snapshot())
        draft.submission = .init(edits: [.rotate(angle: 270)], adjust: desired, snapshot: draft.snapshot)
        try store.write(draft)
        let restored = try XCTUnwrap(PhotoEditDraftStore(root: store.root).load(scope: scope, subject: draft.binding.subject))
        for current in [baseline, .init(edits: [], adjust: desired), .init(edits: [.rotate(angle: 270)], adjust: .neutral)] {
            guard case .retry(let recovered) = try restored.recover(binding: draft.binding, current: current) else {
                return XCTFail("An absent or partial commit must preserve its complete intent")
            }
            XCTAssertEqual(recovered, draft)
        }
        guard case .saved = try restored.recover(binding: draft.binding, current: .init(edits: [.rotate(angle: 270)], adjust: desired)) else {
            return XCTFail("Both legacy components must match")
        }
        XCTAssertThrowsError(try restored.recover(binding: draft.binding, current: .init(edits: [.rotate(angle: 90)], adjust: desired)))
    }

    func testNewerEditingIntentIsNotErasedWhenPreviousSubmissionIsConfirmed() throws {
        var draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        draft.submission = .init(edits: [.rotate(angle: 270)], adjust: nil, snapshot: draft.snapshot)
        draft.snapshot.adjust.exposure = 47
        let current = PhotoEditDraft.Version(edits: [.rotate(angle: 270)], adjust: nil)
        guard case .editing(let recovered) = try draft.recover(binding: binding(), current: current) else {
            return XCTFail("Later edits must survive confirmation of an earlier submission")
        }
        XCTAssertEqual(recovered.snapshot.adjust.exposure, 47)
        XCTAssertEqual(recovered.baseline, current)
        XCTAssertNil(recovered.submission)
    }

    func testLocalVersionChangeRequiresConfirmedRecipeAndSameOriginal() throws {
        let original = Date(timeIntervalSince1970: 100), edited = Date(timeIntervalSince1970: 200)
        var draft = PhotoEditDraft(binding: binding(mode: "local"), baseline: .init(edits: [], adjust: nil, localModification: original), snapshot: snapshot())
        let changed = PhotoEditDraft.Version(edits: [], adjust: nil, localModification: edited)
        XCTAssertThrowsError(try draft.recover(binding: draft.binding, current: changed))
        draft.submission = .init(edits: [.rotate(angle: 270)], adjust: nil, snapshot: draft.snapshot)
        XCTAssertThrowsError(try draft.recover(binding: draft.binding, current: changed))
        let committed = PhotoEditDraft.Version(edits: [.rotate(angle: 270)], adjust: nil, localModification: edited)
        guard case .saved = try draft.recover(binding: draft.binding, current: committed) else { return XCTFail() }
        XCTAssertThrowsError(try draft.recover(binding: binding(revision: "different-original", mode: "local"), current: committed))
    }

    func testCloudDraftSurvivesAndRejectsEditionReturningToSameRecipe() throws {
        let store = store(), original = PhotoEditDraft.Version(edits: [], adjust: nil, cloudRevision: "opening-revision")
        var draft = PhotoEditDraft(binding: binding(), baseline: original, snapshot: snapshot())
        draft.submission = .init(edits: [.rotate(angle: 90)], adjust: nil, snapshot: draft.snapshot)
        try store.write(draft)
        let reopened = try XCTUnwrap(store.load(scope: scope, subject: draft.binding.subject))
        XCTAssertEqual(reopened.baseline.cloudRevision, original.cloudRevision)
        for alternate in ["after-an-edit-and-reset", nil] as [String?] {
            XCTAssertThrowsError(try reopened.recover(binding: draft.binding, current: .init(edits: [], adjust: nil, cloudRevision: alternate)))
        }
        XCTAssertEqual(try store.load(scope: scope, subject: draft.binding.subject), draft)
        guard case .retry = try reopened.recover(binding: draft.binding, current: original) else { return XCTFail() }
    }

    func testOldCloudDraftCanAdoptRevisionOnlyWithMatchingRecipe() throws {
        let draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        let oldJSON = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PhotoEditDraft.self, from: oldJSON)
        XCTAssertNil(decoded.baseline.cloudRevision)
        let current = PhotoEditDraft.Version(edits: [], adjust: nil, cloudRevision: "new-server-revision")
        guard case .editing(let recovered) = try decoded.recover(binding: draft.binding, current: current) else { return XCTFail() }
        XCTAssertEqual(recovered.baseline, current)
        XCTAssertThrowsError(try decoded.recover(binding: draft.binding,
            current: .init(edits: [.rotate(angle: 90)], adjust: nil, cloudRevision: "new-server-revision")))
    }

    func testCorruptDraftIsRetainedUntilExplicitDiscard() throws {
        let store = store(), draft = PhotoEditDraft(binding: binding(), baseline: .init(edits: [], adjust: nil), snapshot: snapshot())
        try store.write(draft)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil).first)
        try Data("incomplete-json".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(scope: scope, subject: draft.binding.subject))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.remove(scope: scope, subject: draft.binding.subject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
