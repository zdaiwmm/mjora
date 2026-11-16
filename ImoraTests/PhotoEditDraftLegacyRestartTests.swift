import XCTest
import Synchronization
@testable import Imora

/// Run the two phases in separate xcodebuild invocations on the owned native
/// simulator. Only this test's new metadata directory survives phase one.
@MainActor
final class PhotoEditDraftLegacyRestartTests: XCTestCase {
    private static var phase1RanHere = false
    private static var phase1SucceededHere = false
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PhotoEditDraftLegacyRestartFixture")
    }
    private nonisolated struct WireState: Codable, Sendable {
        var adjust = ImageAdjust.neutral
        var edits: [AssetEdit] = []
        var rejectEdits = true
    }
    private nonisolated final class WireStorage: Sendable {
        let value: Mutex<WireState>
        init(_ initial: WireState) { value = Mutex(initial) }
    }
    private nonisolated struct Witness: Codable {
        let process: Int32
        let port: UInt16
        let binding: PhotoEditDraft.Binding
        let state: WireState
    }
    private nonisolated struct Edits: Codable { let edits: [AssetEdit] }

    private func server(state: WireStorage, port: UInt16? = nil) throws -> LocalHTTPServer {
        try LocalHTTPServer(port: port) { request in
            do {
                if request.path.hasSuffix("/adjust") {
                    if request.method == "PUT" {
                        let adjust = try JSONDecoder().decode(ImageAdjust.self, from: request.body)
                        state.value.withLock { $0.adjust = adjust }
                    }
                    return .init(body: try JSONEncoder().encode(state.value.withLock { $0.adjust }))
                }
                if request.path.hasSuffix("/edits") {
                    if request.method == "PUT" {
                        guard !state.value.withLock({ $0.rejectEdits }) else { return .init(status: 503) }
                        let edits = try JSONDecoder().decode(Edits.self, from: request.body).edits
                        state.value.withLock { $0.edits = edits }
                    }
                    return .init(body: try JSONEncoder().encode(Edits(edits: state.value.withLock { $0.edits })))
                }
            } catch { return .init(status: 400) }
            return .init(status: 404)
        }
    }

    private func attach(_ value: some Encodable, name: String) throws {
        let attachment = XCTAttachment(data: try JSONEncoder().encode(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPhase1PersistsActualLegacyPartialCommitBeforeProcessExit() async throws {
        Self.phase1RanHere = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Preserve prior failure evidence; never overwrite another run")
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        let wire = WireStorage(WireState()), server = try server(state: wire)
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-legacy-draft")
        client.confirmMediaAccount("legacy-draft-restart")
        defer { client.invalidate() }
        let id = UUID().uuidString
        var photo = PhotoAdjust.neutral; photo.exposure = 31
        let snapshot = EditSnapshot(state: .init(rotation: 270), adjust: photo, disabledTools: [],
            aspect: .freeform, isPortrait: false, removesPreservedEdits: false)
        let binding = PhotoEditDraft.Binding(scope: client.mediaDisplayScope, subject: "remote:" + id,
            sourceRevision: "synthetic-original-r1", width: 400, height: 300, mode: "legacy")
        var draft = PhotoEditDraft(binding: binding, baseline: .init(edits: [], adjust: .neutral), snapshot: snapshot)
        draft.submission = .init(edits: [.rotate(angle: 270)], adjust: photo.legacy, snapshot: snapshot)
        let store = PhotoEditDraftStore(root: root)
        try store.write(draft)
        do {
            try await PhotoEditPersistence.saveLegacy(adjust: photo.legacy, edits: [.rotate(angle: 270)],
                writeAdjust: { try await client.setImageAdjust(id: id, $0) },
                writeEdits: { try await client.applyEdits(id: id, edits: $0) },
                readAdjust: { try await client.imageAdjust(id: id) }, readEdits: { try await client.assetEdits(id: id) })
            XCTFail("The second real HTTP mutation must fail")
        } catch let error as PhotoEditPersistence.SaveError { XCTAssertEqual(error, .partialOrUnconfirmed) }
        let partial = wire.value.withLock { $0 }
        XCTAssertEqual(partial.adjust.exposure, 31); XCTAssertTrue(partial.edits.isEmpty)
        XCTAssertEqual(server.received.filter { $0.method == "PUT" }.count, 2)
        XCTAssertEqual(try store.load(scope: binding.scope, subject: binding.subject), draft)
        let witness = Witness(process: ProcessInfo.processInfo.processIdentifier,
            port: UInt16(try XCTUnwrap(server.apiURL.port)), binding: binding, state: partial)
        try JSONEncoder().encode(witness).write(to: root.appending(path: "wire-state.json"), options: .atomic)
        try attach(witness, name: "legacy-partial-before-process-exit")
        try attach(draft, name: "legacy-pending-draft-before-process-exit")
        Self.phase1SucceededHere = testRun?.failureCount == 0
    }

    func testPhase2RecoversPartialCommitInNewProcessAndConfirmsExplicitRetry() async throws {
        // A normal whole-suite run is one process. It must neither claim a
        // restart nor leave a successful phase-one fixture to poison the next run.
        if Self.phase1RanHere {
            if Self.phase1SucceededHere { try FileManager.default.removeItem(at: root) }
            throw XCTSkip("Run phase two in a separate invocation to verify process restart.")
        }
        let witness = try JSONDecoder().decode(Witness.self, from: Data(contentsOf: root.appending(path: "wire-state.json")))
        XCTAssertNotEqual(witness.process, ProcessInfo.processInfo.processIdentifier, "Must run after the first test process exits")
        var restoredWire = witness.state; restoredWire.rejectEdits = false
        let wire = WireStorage(restoredWire), server = try server(state: wire, port: witness.port)
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-legacy-draft")
        client.confirmMediaAccount("legacy-draft-restart"); defer { client.invalidate() }
        XCTAssertEqual(client.mediaDisplayScope, witness.binding.scope)
        let store = PhotoEditDraftStore(root: root)
        let draft = try XCTUnwrap(store.load(scope: client.mediaDisplayScope, subject: witness.binding.subject))
        let id = String(witness.binding.subject.dropFirst("remote:".count))
        let current = PhotoEditDraft.Version(edits: try await client.assetEdits(id: id), adjust: try await client.imageAdjust(id: id))
        guard case .retry(let recovered) = try draft.recover(binding: witness.binding, current: current) else {
            return XCTFail("A partial commit must remain pending after process restart")
        }
        XCTAssertEqual(recovered.snapshot.adjust.exposure, 31)
        XCTAssertEqual(recovered.snapshot.state.rotation, 270)
        XCTAssertEqual(server.received.filter { $0.method == "PUT" }.count, 0, "Recovery itself must never write")
        let intent = try XCTUnwrap(recovered.submission)
        try await PhotoEditPersistence.saveLegacy(adjust: intent.adjust, edits: intent.edits,
            writeAdjust: { try await client.setImageAdjust(id: id, $0) },
            writeEdits: { try await client.applyEdits(id: id, edits: $0) },
            readAdjust: { try await client.imageAdjust(id: id) }, readEdits: { try await client.assetEdits(id: id) })
        let confirmed = PhotoEditDraft.Version(edits: try await client.assetEdits(id: id), adjust: try await client.imageAdjust(id: id))
        guard case .saved = try recovered.recover(binding: witness.binding, current: confirmed) else { return XCTFail() }
        XCTAssertEqual(server.received.filter { $0.method == "PUT" }.count, 2, "One explicit complete retry")
        try store.remove(scope: witness.binding.scope, subject: witness.binding.subject)
        XCTAssertNil(try store.load(scope: witness.binding.scope, subject: witness.binding.subject))
        try attach(["firstProcess": witness.process, "secondProcess": ProcessInfo.processInfo.processIdentifier], name: "legacy-cross-process-proof")
        try attach(confirmed, name: "legacy-confirmed-after-explicit-retry")
        try FileManager.default.removeItem(at: root)
    }
}
