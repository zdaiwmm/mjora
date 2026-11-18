import CryptoKit
import Foundation
import Photos
import Synchronization
import UIKit
import XCTest
@testable import Imora

@MainActor
final class PhotoEditTargetTests: XCTestCase {
    private struct SourceObservation {
        let epoch: Int
        let modification: Date?
        let editorModification: Date?
        let editorIsCurrent: Bool
        let authorization: Int

        var json: [String: Any] {
            ["epoch": epoch, "modification": modification.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
             "editorModification": editorModification.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
             "editorIsCurrent": editorIsCurrent, "authorization": authorization]
        }

        func versionChanged(since other: Self) -> Bool {
            epoch != other.epoch || modification != other.modification || editorModification != modification
        }
    }

    /// This wrapper observes the real reader; it never replaces a source,
    /// baseline or authorization decision made by the production implementation.
    private final class ObservedReader: PhotoEditTargetReading {
        let base: PhotoEditTargetReader
        let observe: @MainActor () -> SourceObservation
        let initial: SourceObservation
        var phase = "initial"
        var failedPhase: String?
        var events: [[String: Any]] = []
        var latest: SourceObservation

        init(base: PhotoEditTargetReader, observe: @escaping @MainActor () -> SourceObservation) {
            self.base = base; self.observe = observe
            initial = observe(); latest = initial
        }
        var context: PhotoEditTargetContext { base.context }
        var isCurrent: Bool { base.isCurrent }
        var observedVersionChange: Bool { latest.versionChanged(since: initial) }
        var observedLocalVersionFailure: Bool {
            ["localTarget", "original.local", "validate.local"].contains(failedPhase ?? "") && observedVersionChange
        }

        private func record<Value: Sendable>(_ phase: String, operation: @MainActor () async throws -> Value) async throws -> Value {
            self.phase = phase
            let before = observe()
            do {
                let value = try await operation()
                latest = observe()
                events.append(["phase": phase, "before": before.json, "after": latest.json, "completed": true])
                return value
            } catch {
                failedPhase = phase
                latest = observe()
                var event: [String: Any] = ["phase": phase, "before": before.json, "after": latest.json,
                    "completed": false, "errorType": String(reflecting: type(of: error))]
                if let issue = error as? PhotoEditTargetIssue { event["issue"] = String(describing: issue) }
                events.append(event)
                throw error
            }
        }
        func localTarget(id: String) async throws -> PhotoEditTargetSnapshot {
            try await record("localTarget") { try await self.base.localTarget(id: id) }
        }
        func cloudTarget(id: String, requiresElevation: Bool) async throws -> PhotoEditTargetSnapshot {
            try await record("cloudTarget") { try await self.base.cloudTarget(id: id, requiresElevation: requiresElevation) }
        }
        func original(for target: PhotoEditTargetSnapshot) async throws -> PhotoEditOriginalFingerprint {
            let phase = if case .local = target.id { "original.local" } else { "original.cloud" }
            return try await record(phase) { try await self.base.original(for: target) }
        }
        func validate(_ target: PhotoEditTargetSnapshot) async throws {
            let phase = if case .local = target.id { "validate.local" } else { "validate.cloud" }
            try await record(phase) { try await self.base.validate(target) }
        }
    }

    private final class Reader: PhotoEditTargetReading {
        let context: PhotoEditTargetContext
        var isCurrent = true
        var local: PhotoEditTargetSnapshot
        var cloud: PhotoEditTargetSnapshot
        var localOriginal: PhotoEditOriginalFingerprint
        var cloudOriginal: PhotoEditOriginalFingerprint
        var originalReads = 0
        var revokeAfterRead = false
        var revoked = false
        init(context: PhotoEditTargetContext, original: PhotoEditOriginalFingerprint) {
            self.context = context
            localOriginal = original
            cloudOriginal = .init(role: .serverOriginal, sha256: original.sha256, sha1: original.sha1,
                byteCount: original.byteCount, width: original.width, height: original.height, orientation: original.orientation)
            local = .init(id: .local("local"), context: context,
                baseline: .init(sourceRevision: original.sha256, edits: [], localModification: .distantPast), width: original.width, height: original.height)
            cloud = .init(id: .cloud("cloud"), context: context,
                baseline: .init(sourceRevision: original.sha1, edits: [], localModification: nil), width: original.width, height: original.height)
        }
        func localTarget(id: String) async throws -> PhotoEditTargetSnapshot { local }
        func cloudTarget(id: String, requiresElevation: Bool) async throws -> PhotoEditTargetSnapshot { cloud }
        func original(for target: PhotoEditTargetSnapshot) async throws -> PhotoEditOriginalFingerprint {
            originalReads += 1
            if revokeAfterRead { revoked = true }
            if case .local = target.id { return localOriginal }
            return cloudOriginal
        }
        func validate(_ target: PhotoEditTargetSnapshot) async throws {
            if revoked { throw PhotoEditTargetIssue.unavailable }
        }
    }

    private let owner = "00000000-0000-4000-8000-000000000001"
    private let remoteID = "00000000-0000-4000-8000-000000000002"

    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: .init(width: 64, height: 32), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                UIColor.systemTeal.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 32))
            }
    }

    private func fingerprint() -> PhotoEditOriginalFingerprint {
        let data = jpeg()
        return .init(role: .photoKitOriginal, sha256: Data(SHA256.hash(data: data)).base64EncodedString(),
            sha1: Data(Insecure.SHA1.hash(data: data)).base64EncodedString(), byteCount: Int64(data.count), width: 64, height: 32, orientation: 1)
    }

    private func candidate(_ context: PhotoEditTargetContext) -> PhotoEditTargetCandidate {
        .init(context: context, localIdentifier: "local", remoteIdentifier: "cloud")
    }

    private func fixture() -> Reader {
        Reader(context: .init(scope: .verified(server: "https://edit-target.invalid/api", accountID: owner), session: UUID()), original: fingerprint())
    }

    private func assertIssue(_ expected: PhotoEditTargetIssue, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? PhotoEditTargetIssue, expected) }
    }

    func testPairRequiresExactOriginalsAndKeepsBothTargetBaselines() async throws {
        let reader = fixture()
        let resolved = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader)
        guard case .both(let local, let cloud, let original) = resolved else { return XCTFail("Missing both targets") }
        XCTAssertEqual(local.id, .local("local")); XCTAssertEqual(cloud.id, .cloud("cloud"))
        XCTAssertEqual(local.baseline.localModification, .distantPast)
        XCTAssertNil(cloud.baseline.localModification)
        XCTAssertEqual(original.byteCount, reader.localOriginal.byteCount)
        XCTAssertEqual(reader.originalReads, 2)
    }

    func testSingleTargetDoesNotReadAnyAdditionalOriginalOrMissingOtherTarget() async throws {
        let reader = fixture()
        let request = PhotoEditTargetCandidate(context: reader.context, localIdentifier: nil, remoteIdentifier: "cloud")
        guard case .cloud = try await PhotoEditTargetResolver.resolve(.cloud, candidate: request, reader: reader) else { return XCTFail() }
        XCTAssertEqual(reader.originalReads, 0)
        await assertIssue(.missingTarget(.local)) {
            _ = try await PhotoEditTargetResolver.resolve(.both, candidate: request, reader: reader)
        }
    }

    func testSameBytesWithDifferentOrientationCannotBind() async {
        let reader = fixture(), old = reader.cloudOriginal
        reader.cloudOriginal = .init(role: .serverOriginal, sha256: old.sha256, sha1: old.sha1,
            byteCount: old.byteCount, width: old.width, height: old.height, orientation: 3)
        await assertIssue(.sourceMismatch) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
    }

    func testOriginalFingerprintCannotBorrowAnotherBaselineRevision() async {
        for target in [PhotoEditTargetSelection.local, .cloud] {
            let reader = fixture()
            if target == .local {
                reader.local = .init(id: reader.local.id, context: reader.context,
                    baseline: .init(sourceRevision: Data(repeating: 1, count: 32).base64EncodedString(), edits: [], localModification: .distantPast),
                    width: 64, height: 32)
            } else {
                reader.cloud = .init(id: reader.cloud.id, context: reader.context,
                    baseline: .init(sourceRevision: Data(repeating: 1, count: 20).base64EncodedString(), edits: [], localModification: nil),
                    width: 64, height: 32)
            }
            await assertIssue(.sourceChanged) {
                _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader)
            }
        }
    }

    func testDifferentBytesAndMetadataDimensionsCannotBind() async {
        let reader = fixture(), old = reader.cloudOriginal
        reader.cloudOriginal = .init(role: .serverOriginal, sha256: Data(repeating: 1, count: 32).base64EncodedString(), sha1: old.sha1,
            byteCount: old.byteCount, width: old.width, height: old.height, orientation: old.orientation)
        await assertIssue(.sourceMismatch) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
        reader.cloudOriginal = old
        reader.cloud = .init(id: reader.cloud.id, context: reader.context, baseline: reader.cloud.baseline, width: 32, height: 64)
        await assertIssue(.sourceMismatch) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
    }

    func testEditedPreviewAndOfflinePlaybackCannotClaimOriginalIdentity() async {
        for role in [PhotoEditOriginalFingerprint.Role.preview, .editedResult, .offlinePlayback] {
            let reader = fixture(), old = reader.cloudOriginal
            reader.cloudOriginal = .init(role: role, sha256: old.sha256, sha1: old.sha1, byteCount: old.byteCount,
                width: old.width, height: old.height, orientation: old.orientation)
            await assertIssue(.nonOriginalInput) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
        }
    }

    func testDifferentAccountServerOrSessionCannotBorrowTarget() async {
        for scope in [StableMediaScope.verified(server: "https://other.invalid", accountID: owner),
                      .verified(server: "https://edit-target.invalid/api", accountID: "other")] {
            let reader = fixture()
            let request = candidate(.init(scope: scope, session: reader.context.session))
            await assertIssue(.changedContext) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: request, reader: reader) }
            XCTAssertEqual(reader.originalReads, 0)
        }
        let reader = fixture()
        await assertIssue(.changedContext) {
            _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(.init(scope: reader.context.scope, session: UUID())), reader: reader)
        }
    }

    func testRecipeConflictAndUnknownActionsKeepPairUnavailable() async {
        let reader = fixture()
        reader.cloud = .init(id: reader.cloud.id, context: reader.context,
            baseline: .init(sourceRevision: reader.cloud.baseline.sourceRevision, edits: [.rotate(angle: 90)], localModification: nil), width: 64, height: 32)
        await assertIssue(.recipeConflict) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
        XCTAssertEqual(reader.originalReads, 0)
        reader.cloud = .init(id: reader.cloud.id, context: reader.context,
            baseline: .init(sourceRevision: reader.cloud.baseline.sourceRevision, edits: [.other(action: "future", parameters: nil)], localModification: nil), width: 64, height: 32)
        await assertIssue(.unsupportedRecipe) { _ = try await PhotoEditTargetResolver.resolve(.cloud, candidate: candidate(reader.context), reader: reader) }
    }

    func testRevokedLimitedAccessDuringComparisonDoesNotPublishBinding() async {
        let reader = fixture(); reader.revokeAfterRead = true
        await assertIssue(.unavailable) { _ = try await PhotoEditTargetResolver.resolve(.both, candidate: candidate(reader.context), reader: reader) }
    }

    private func metadata(_ bytes: Data, checksum: String? = nil, owner: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": remoteID, "ownerId": owner ?? self.owner, "type": "IMAGE",
            "originalFileName": "synthetic.jpg", "fileCreatedAt": "2026-11-18T00:00:00Z", "localDateTime": "2026-11-18T00:00:00Z",
            "isFavorite": false, "isTrashed": false, "visibility": "timeline", "width": 64, "height": 32,
            "checksum": checksum ?? Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()])
    }

    private func makeServer(bytes: Data, metadata: Data) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            guard request.method == "GET" else { return .init(status: 405) }
            if request.path.contains("/original?") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            if request.path.hasSuffix("/edits") { return .init(body: Data(#"{"edits":[]}"#.utf8)) }
            return .init(body: metadata)
        }
    }

    func testControlledHTTPOriginalUsesRawEndpointAndStreamedDigest() async throws {
        let data = jpeg(), server = try makeServer(bytes: data, metadata: metadata(data))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1")
        client.confirmMediaAccount(owner); defer { client.invalidate() }
        let reader = PhotoEditTargetReader(client: client)
        let target = try await reader.cloudTarget(id: remoteID, requiresElevation: false)
        let original = try await reader.original(for: target)
        XCTAssertEqual(original.sha256, Data(SHA256.hash(data: data)).base64EncodedString())
        XCTAssertEqual(original.byteCount, Int64(data.count))
        XCTAssertEqual(original.width, 64); XCTAssertEqual(original.height, 32)
        XCTAssertEqual(server.received.filter { $0.path.contains("/original?") }.count, 1)
        XCTAssertTrue(server.received.filter { $0.path.contains("/original?") }.allSatisfy { $0.path.contains("edited=false") })
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" && !$0.path.contains("/thumbnail") })
    }

    func testCloudOnlyResolutionDoesNotDownloadTheOriginal() async throws {
        let data = jpeg(), server = try makeServer(bytes: data, metadata: metadata(data))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-single")
        client.confirmMediaAccount(owner); defer { client.invalidate() }
        let reader = PhotoEditTargetReader(client: client)
        _ = try await PhotoEditTargetResolver.resolve(.cloud,
            candidate: .init(context: reader.context, localIdentifier: nil, remoteIdentifier: remoteID), reader: reader)
        XCTAssertTrue(server.received.allSatisfy { !$0.path.contains("/original") && !$0.path.contains("/thumbnail") })
    }

    func testWrongCloudOriginalChecksumCannotBecomeInputProof() async throws {
        let data = jpeg(), server = try makeServer(bytes: data, metadata: metadata(data, checksum: Data(repeating: 0, count: 20).base64EncodedString()))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-mismatch")
        client.confirmMediaAccount(owner); defer { client.invalidate() }
        let reader = PhotoEditTargetReader(client: client)
        let target = try await reader.cloudTarget(id: remoteID, requiresElevation: false)
        await assertIssue(.checksumMismatch) { _ = try await reader.original(for: target) }
    }

    func testWrongOwnerAndMissingPINCannotReadOriginal() async throws {
        let data = jpeg(), server = try makeServer(bytes: data, metadata: metadata(data, owner: "other"))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-private")
        client.confirmMediaAccount(owner); defer { client.invalidate() }
        let reader = PhotoEditTargetReader(client: client)
        await assertIssue(.unavailable) { _ = try await reader.cloudTarget(id: remoteID, requiresElevation: true) }
        XCTAssertTrue(server.received.isEmpty)
        await assertIssue(.unavailable) { _ = try await reader.cloudTarget(id: remoteID, requiresElevation: false) }
        XCTAssertTrue(server.received.allSatisfy { !$0.path.contains("/original") })
    }

    func testRetiredClientCannotResolveOrReadAnything() async throws {
        let data = jpeg(), server = try makeServer(bytes: data, metadata: metadata(data))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-retired")
        client.confirmMediaAccount(owner)
        let reader = PhotoEditTargetReader(client: client)
        client.invalidate()
        await assertIssue(.changedContext) { _ = try await reader.cloudTarget(id: remoteID, requiresElevation: false) }
        XCTAssertTrue(server.received.isEmpty)
    }

    func testPINRevocationWhileReadingBaselineInvalidatesTheTarget() async throws {
        let data = jpeg(), metadata = try metadata(data)
        let editsRead = Mutex(0), holder = Mutex<ImoraClient?>(nil)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/auth/status" {
                return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
            }
            if request.path.hasSuffix("/edits") {
                let read = editsRead.withLock { $0 += 1; return $0 }
                if read == 2 { holder.withLock { $0 }?.revokeLockedMediaLease() }
                return .init(body: Data(#"{"edits":[]}"#.utf8))
            }
            return .init(body: metadata)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-pin-race")
        client.confirmMediaAccount(owner); holder.withLock { $0 = client }
        defer { holder.withLock { $0 = nil }; client.invalidate() }
        _ = try await client.authStatus()
        let reader = PhotoEditTargetReader(client: client)
        let target = try await reader.cloudTarget(id: remoteID, requiresElevation: true)
        await assertIssue(.unavailable) { try await reader.validate(target) }
        XCTAssertTrue(server.received.allSatisfy { !$0.path.contains("/original") })
    }

    func testRetainedDisplayCannotReplaceUnavailableHTTPOriginal() async throws {
        let data = jpeg(), metadata = try metadata(data)
        let server = try LocalHTTPServer { request in
            if request.path.contains("/original?") { return .init(status: 503) }
            if request.path.hasSuffix("/edits") { return .init(body: Data(#"{"edits":[]}"#.utf8)) }
            return .init(body: metadata)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-offline")
        client.confirmMediaAccount(owner); defer { client.invalidate() }
        let scope = client.mediaDisplayScope
        let detail = try JSONDecoder().decode(AssetDetail.self, from: metadata), asset = detail.asAsset()
        try MediaContentGenerations.shared.ensureInitialized()
        let generation = try XCTUnwrap(MediaContentGenerations.shared.current(scope: scope, subject: .remoteAsset(remoteID)))
        let albumID = UUID().uuidString
        let album = try JSONDecoder().decode(Album.self, from: JSONSerialization.data(withJSONObject: [
            "id": albumID, "albumName": "E1 synthetic display", "description": "Synthetic only", "albumThumbnailAssetId": remoteID,
            "assetCount": 1, "albumUsers": [], "shared": false, "hasSharedLink": false,
            "createdAt": "2026-11-18", "updatedAt": "2026-11-18", "order": "desc"]))
        let part = OfflineAlbum.Component(kind: .image, asset: asset, generation: generation)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "e1-display-" + UUID().uuidString)
        try data.write(to: temporary); defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await OfflineAlbumStore.shared.prepare(album: album, items: [.init(asset: asset, components: [part])], scope: scope)
            try await OfflineAlbumStore.shared.install(temporary: temporary, mime: "image/jpeg", expectedBytes: Int64(data.count),
                scope: scope, albumID: albumID, itemID: remoteID, componentIndex: 0, context: client.context)
            try await OfflineAlbumStore.shared.setState(.ready, scope: scope, id: albumID)
            let display = try await client.retainedMediaFile(client.editedOriginalURL(assetID: remoteID))
            XCTAssertNotNil(display)
            let reader = PhotoEditTargetReader(client: client)
            let target = try await reader.cloudTarget(id: remoteID, requiresElevation: false)
            do { _ = try await reader.original(for: target); XCTFail("Retained edited display substituted for the raw original") }
            catch { guard case ImoraError.http(503, _) = error else { throw error } }
            XCTAssertEqual(server.received.filter { $0.path.contains("/original?") }.count, 1)
            XCTAssertTrue(server.received.filter { $0.path.contains("/original?") }.allSatisfy { $0.path.contains("edited=false") })
            try await OfflineAlbumStore.shared.remove(scope: scope, id: albumID)
        } catch {
            try? await OfflineAlbumStore.shared.remove(scope: scope, id: albumID)
            throw error
        }
    }

    /// Old run receipts remain intact for the parent's task-owned simulator reset.
    /// PhotoKit deletion prompts are outside this source-binding unit test.
    private func validateOwnedManifests(device: String) throws -> [String] {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == device else { throw PhotoEditTargetIssue.unavailable }
        var validated: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.lastPathComponent.hasPrefix("batch2-e1-") {
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", UUID(uuidString: String(stem.dropFirst("batch2-e1-".count))) != nil,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  manifest["runID"] as? String == stem, manifest["ownedSimulator"] as? String == device,
                  let created = manifest["createdIDs"] as? [String], created.count <= 1,
                  created.allSatisfy({ !$0.isEmpty }), Set(created).count == created.count else { continue }
            let cleaned = manifest["cleanedIDs"] as? [String] ?? []
            guard Set(cleaned).isSubset(of: Set(created)) else { throw PhotoEditTargetIssue.unavailable }
            validated.append(url.lastPathComponent)
        }
        return validated.sorted()
    }

    private func observeOwnedSource(_ id: String, editor: LocalPhotoEditor) -> SourceObservation {
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        return .init(epoch: DeviceMediaFactsStore.shared.generation, modification: asset?.modificationDate,
            editorModification: editor.modificationDate, editorIsCurrent: editor.isCurrent,
            authorization: PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)
    }

    func testOwnedSyntheticPhotoKitAndHTTPOriginalBindWithoutSavingEitherTarget() async throws {
        let ownedDevice = "4E132CEA-B752-4CA6-8365-BF595B32A390"
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == ownedDevice else {
            throw XCTSkip("This test owns only the batch2 stage1 simulator.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("The parent must grant Photos access on the owned synthetic simulator.")
        }
        DeviceMediaFactsStore.shared.startObserving()
        let priorManifests = try validateOwnedManifests(device: ownedDevice)
        let runID = "batch2-e1-" + UUID().uuidString
        let manifestURL = FileManager.default.temporaryDirectory.appending(path: runID + ".json")
        let created = Mutex<String?>(nil), data = jpeg()
        var manifest: [String: Any] = ["schemaVersion": 2, "runID": runID, "ownedSimulator": ownedDevice,
            "createdIDs": [], "verificationComplete": false, "cleanupPending": false,
            "cleanupStrategy": "task-owned-simulator-reset", "priorManifestsValidated": priorManifests]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            created.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        let id = try XCTUnwrap(created.withLock { $0 })
        manifest["createdIDs"] = [id]; manifest["cleanupPending"] = true
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        do {
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
            let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
            let received = Mutex(Data())
            let raw: Data = try await withCheckedThrowingContinuation { continuation in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
                PHAssetResourceManager.default().requestData(for: resource, options: options) { @Sendable chunk in
                    received.withLock { $0.append(chunk) }
                } completionHandler: { @Sendable error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: received.withLock { $0 }) }
                }
            }
            let server = try makeServer(bytes: raw, metadata: metadata(raw))
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-e1-photokit")
            client.confirmMediaAccount(owner); defer { client.invalidate() }
            var attempts: [[String: Any]] = []
            var resolution: PhotoEditResolvedTargets?
            for attempt in 1...3 {
                // A retry is a completely new observation, not reuse of a
                // rejected editor, reader, candidate, fingerprint or baseline.
                let editor = try await LocalPhotoEditor.open(localIdentifier: id)
                let reader = ObservedReader(base: PhotoEditTargetReader(client: client, localEditor: editor)) {
                    self.observeOwnedSource(id, editor: editor)
                }
                do {
                    let value = try await PhotoEditTargetResolver.resolve(.both,
                        candidate: .init(context: reader.context, localIdentifier: id, remoteIdentifier: remoteID), reader: reader)
                    attempts.append(["attempt": attempt, "initial": reader.initial.json, "final": reader.latest.json,
                        "events": reader.events, "resolved": true, "retried": false])
                    manifest["attempts"] = attempts
                    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
                    resolution = value
                    break
                } catch {
                    let canRetry = (error as? PhotoEditTargetIssue) == .sourceChanged && reader.observedLocalVersionFailure && attempt < 3
                    var evidence: [String: Any] = ["attempt": attempt, "initial": reader.initial.json, "final": reader.latest.json,
                        "events": reader.events, "failedPhase": reader.failedPhase ?? "resolver.after.\(reader.phase)", "resolved": false,
                        "observedVersionChange": reader.observedVersionChange, "retried": canRetry,
                        "errorType": String(reflecting: type(of: error))]
                    if let issue = error as? PhotoEditTargetIssue { evidence["issue"] = String(describing: issue) }
                    attempts.append(evidence)
                    manifest["attempts"] = attempts
                    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
                    guard canRetry else { throw error }
                }
            }
            guard let resolved = resolution else { throw PhotoEditTargetIssue.sourceChanged }
            guard case .both(let local, let cloud, let original) = resolved else { throw PhotoEditTargetIssue.unavailable }
            XCTAssertEqual(local.id, .local(id)); XCTAssertEqual(cloud.id, .cloud(remoteID))
            XCTAssertEqual(original.sha256, Data(SHA256.hash(data: raw)).base64EncodedString())
            XCTAssertEqual(original.byteCount, Int64(raw.count))
            XCTAssertTrue(local.baseline.edits.isEmpty); XCTAssertTrue(cloud.baseline.edits.isEmpty)
            XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" })
            guard local.id == .local(id), cloud.id == .cloud(remoteID),
                  original.sha256 == Data(SHA256.hash(data: raw)).base64EncodedString(), original.byteCount == Int64(raw.count),
                  local.baseline.edits.isEmpty, cloud.baseline.edits.isEmpty,
                  server.received.allSatisfy({ $0.method == "GET" }) else { throw PhotoEditTargetIssue.sourceMismatch }
            manifest["verificationComplete"] = true
            manifest["verifiedAt"] = Date().ISO8601Format()
            manifest["sourceSha256"] = original.sha256
            manifest["sourceByteCount"] = original.byteCount
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        } catch {
            manifest["verificationComplete"] = false
            manifest["verificationFailedAt"] = Date().ISO8601Format()
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
            throw error
        }
    }
}
