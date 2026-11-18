#if BACKGROUND_VALIDATION
import CryptoKit
import Foundation
import SwiftUI
import UIKit

// Added only to an exported private candidate. Existing session and app delegate remain in control.
struct BackgroundValidationPanel: View {
    @Environment(SessionStore.self) private var session
    @State private var runner = BackgroundValidationRunner()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Synthetic transport only").font(.caption.bold())
            Text(runner.message).font(.caption)
            Button("Prepare Synthetic Transfer") { Task { await runner.prepare(session.client) } }
                .disabled(runner.busy || session.client == nil)
            Button("Run Prepared Transfer") { Task { await runner.run(session.client) } }
                .disabled(runner.busy || !runner.prepared)
            Button("Clean Up This Run") { Task { await runner.cleanup(session.client) } }
                .disabled(runner.busy || !runner.canClean)
        }
        .padding(8).background(.regularMaterial).clipShape(.rect(cornerRadius: 8))
        .frame(maxWidth: 260).padding()
        .accessibilityIdentifier("background-validation-panel")
    }
}

private nonisolated struct ValidationRequest: Decodable {
    let schemaVersion: Int
    let runID: String
    let scenario: String
    let sourceRevision: String
    let backendURL: URL
    let relayURL: URL
    let fixtureID: String
    let accountID: String
    let accountEmail: String
    let payloadBytes: Int64
}

private final class ValidationNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable
private final class BackgroundValidationRunner {
    var message = "Sign in to the isolated synthetic account, then prepare."
    var busy = false
    var prepared = false
    var canClean = false
    private var request: ValidationRequest?
    private var manifest: [String: Any] = [:]
    private var record: [String: Any] = [:]
    private var state: BackgroundUploadState?
    private var ledger: BackgroundValidationLedger?
    private var events: [[String: Any]] = []
    private var assetIDs: [String] = []
    private var freshlyVerifiedAssetID: String?
    private var digest: (sha1: String, sha256: String, bytes: Int64)?
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "BackgroundValidationV2", directoryHint: .isDirectory)

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    private func validate(_ client: ImoraClient?) async throws -> (ImoraClient, ValidationRequest) {
        guard let client, client.context.isActive,
              let path = Bundle.main.url(forResource: "BackgroundValidationRequest", withExtension: "json"),
              let value = try? JSONDecoder().decode(ValidationRequest.self, from: Data(contentsOf: path)),
              value.schemaVersion == 2, value.sourceRevision == "__VALIDATION_SOURCE_REVISION__",
              value.runID.range(of: #"^b2-bg-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"#, options: .regularExpression) != nil,
              ["transport-stable", "transport-interrupted"].contains(value.scenario),
              value.payloadBytes >= 4096, value.payloadBytes <= 512 * 1024 * 1024,
              value.backendURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == client.apiURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              validEndpoint(value.backendURL), validEndpoint(value.relayURL),
              value.accountEmail.hasSuffix("@background-fixture.invalid"), UUID(uuidString: value.accountID) != nil,
              UUID(uuidString: value.fixtureID) != nil,
              Bundle.main.bundleIdentifier?.hasPrefix("org.imora.validation.") == true else { throw URLError(.userAuthenticationRequired) }
        let check = URLSession(configuration: .ephemeral, delegate: ValidationNoRedirect(), delegateQueue: nil)
        defer { check.invalidateAndCancel() }
        let (data, response) = try await check.data(from: value.backendURL.appending(path: "__background_validation__/identity"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              identity["schemaVersion"] as? Int == 2, identity["syntheticOnly"] as? Bool == true,
              identity["fixtureID"] as? String == value.fixtureID, identity["accountID"] as? String == value.accountID else {
            throw URLError(.userAuthenticationRequired)
        }
        let user = try await client.currentUser()
        guard user.id == value.accountID, user.email == value.accountEmail, !user.isAdmin, client.context.isActive else {
            throw URLError(.userAuthenticationRequired)
        }
        request = value
        return (client, value)
    }

    private func validEndpoint(_ url: URL) -> Bool {
        guard url.path == "/api", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "::1"].contains(url.host ?? ""))
    }

    private func fingerprint(_ value: ValidationRequest) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["backendURL": value.backendURL.absoluteString,
            "fixtureID": value.fixtureID, "accountID": value.accountID], options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ value: [String: Any], name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let target = directory.appending(path: name)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private func event(_ phase: String, offset: Int64 = 0, authenticated: Bool = false) throws {
        events.append(["phase": phase, "mediaID": "transport-video", "at": timestamp(),
            "confirmedOffset": offset, "authenticated": authenticated,
            "locked": !UIApplication.shared.isProtectedDataAvailable])
        record["events"] = events
        try save(record, name: "record.json")
    }

    private func persistLedger() throws {
        guard let ledger else { throw BackgroundValidationLedger.Failure.invalidTransition }
        record["ledger"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger))
        if let receipt = ledger.receipt {
            let prior = (record["uploads"] as? [[String: Any]])?.first
            let ids = receipt.assetID.map { [$0] } ?? []
            var exported: [String: Any] = ["mediaID": "transport-video", "uploadRef": receipt.uploadRef,
                "createdAssetIDs": ids, "finalOffset": receipt.confirmedOffset]
            if receipt.assetID == nil, let provisional = receipt.provisionalAssetID { exported["provisionalAssetID"] = provisional }
            if prior?["uploadRef"] as? String == receipt.uploadRef,
               prior?["createdAssetIDs"] as? [String] == ids, let readback = prior?["readback"] {
                exported["readback"] = readback
            }
            if ledger.isCleaned { exported["cleanup"] = ["complete": true, "assetIDs": ids, "uploadRef": receipt.uploadRef] }
            record["uploads"] = [exported]
            assetIDs = ids
        }
        try save(record, name: "record.json")
        prepared = ledger.canRun
        canClean = ledger.canClean
    }

    private func acceptStatus(_ value: BackgroundUploadState, reference: String) throws {
        guard let request, value.uploadId == reference, value.size == request.payloadBytes,
              let offset = value.offset else { throw URLError(.cannotParseResponse) }
        try ledger?.receivedStatus(uploadRef: reference, offset: offset, assetID: value.result?.id, resultStatus: value.result?.status)
        state = value
        try persistLedger()
    }

    private func verifyCandidateAsset(_ client: ImoraClient) async throws {
        guard let ledger, let receipt = ledger.receipt, receipt.mayVerifyAsset,
              let asset = receipt.provisionalAssetID else { throw BackgroundValidationLedger.Failure.invalidReceipt }
        guard let savedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "manifest.json"))) as? [String: Any],
              savedManifest["runID"] as? String == ledger.binding.runID,
              savedManifest["sourceRevision"] as? String == ledger.binding.sourceRevision,
              savedManifest["targetFingerprint"] as? String == ledger.binding.targetFingerprint,
              let media = savedManifest["media"] as? [[String: Any]], media.count == 1,
              media[0]["filename"] as? String == ledger.binding.runID + ".mp4",
              media[0]["sha1"] as? String == ledger.binding.sha1,
              media[0]["sha256"] as? String == ledger.binding.sha256,
              media[0]["byteCount"] as? Int64 == ledger.binding.byteCount else { throw BackgroundValidationLedger.Failure.wrongBinding }
        let detail = try await client.assetDetail(id: asset)
        // A failed read retains existing historical qualification, but never starts deletion.
        // A returned mismatch or failed original readback revokes it before further work.
        try self.ledger?.invalidateAssetVerification()
        try persistLedger()
        guard detail.id == asset, detail.ownerId == ledger.binding.accountID,
              detail.originalFileName == ledger.binding.runID + ".mp4", detail.type == .video,
              detail.checksum == ledger.binding.sha1 else { throw BackgroundValidationLedger.Failure.invalidReceipt }
        let file = try await client.downloadOriginal(assetID: asset, to: directory.appending(path: "readback"), fileExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let actual = try await Self.hashes(file)
        guard client.context.isActive else { throw ServerTrustError.sessionExpired }
        let proof = BackgroundValidationLedger.AssetVerification(assetID: asset, ownerID: detail.ownerId,
            originalFileName: detail.originalFileName, byteCount: actual.bytes, sha1: actual.sha1, sha256: actual.sha256)
        try self.ledger?.verifyAsset(proof)
        try persistLedger()
        var uploads = record["uploads"] as? [[String: Any]] ?? []
        guard uploads.count == 1 else { throw BackgroundValidationLedger.Failure.invalidReceipt }
        uploads[0]["readback"] = ["authenticated": true, "assetID": asset, "byteCount": actual.bytes,
            "sha1": actual.sha1, "sha256": actual.sha256]
        record["uploads"] = uploads
        try save(record, name: "record.json")
        freshlyVerifiedAssetID = asset
    }

    private func restoreSavedRun(_ value: ValidationRequest, target: String) throws -> Bool {
        let file = directory.appending(path: "record.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              previous["runID"] as? String == value.runID,
              previous["sourceRevision"] as? String == value.sourceRevision,
              previous["targetFingerprint"] as? String == target,
              previous["scenario"] as? String == value.scenario,
              let savedLedger = previous["ledger"], let priorEvents = previous["events"] as? [[String: Any]] else {
            throw BackgroundValidationLedger.Failure.wrongBinding
        }
        let data = try JSONSerialization.data(withJSONObject: savedLedger)
        let saved = try JSONDecoder().decode(BackgroundValidationLedger.self, from: data)
        let binding = BackgroundValidationLedger.Binding(runID: value.runID, sourceRevision: value.sourceRevision,
            targetFingerprint: target, accountID: value.accountID, sha256: saved.binding.sha256, sha1: saved.binding.sha1, byteCount: value.payloadBytes)
        ledger = try .restore(data, binding: binding)
        record = previous; events = priorEvents
        try persistLedger()
        return true
    }

    func prepare(_ input: ImoraClient?) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let (client, value) = try await validate(input)
            let video = directory.appending(path: value.runID + ".mp4")
            let target = try fingerprint(value)
            let restoring = try restoreSavedRun(value, target: target)
            if !restoring, FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path) {
                throw BackgroundValidationLedger.Failure.wrongBinding
            }
            if restoring {
                guard ledger?.canRun == true else {
                    message = ledger?.canClean == true ? "Saved cleanup is pending. Resume Clean Up This Run." : "This run is finished or has no owned reference. Keep its receipt; do not open or delete another upload."
                    return
                }
                guard FileManager.default.fileExists(atPath: video.path) else {
                    prepared = false
                    message = "Original synthetic file is missing. Use the saved staging receipt only to clean up; do not regenerate this run."
                    return
                }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: video.path) {
                try await SyntheticValidationVideo.make(video, size: value.payloadBytes, marker: value.runID)
            }
            try ProtectedTemporaryFiles.protect(video)
            try await SyntheticValidationVideo.verifyDecodes(video)
            let hash = try await Self.hashes(video)
            guard hash.bytes == value.payloadBytes else { throw URLError(.cannotDecodeContentData) }
            digest = hash
            if restoring {
                guard ledger?.binding.sha256 == hash.sha256 else { throw BackgroundValidationLedger.Failure.wrongBinding }
            }
            let generatedManifest: [String: Any] = ["schemaVersion": 2, "runID": value.runID, "scenario": value.scenario,
                "sourceRevision": value.sourceRevision, "targetFingerprint": target, "createdAt": timestamp(), "syntheticOnly": true,
                "media": [["mediaID": "transport-video", "role": "transportVideo", "filename": video.lastPathComponent,
                    "byteCount": hash.bytes, "sha1": hash.sha1, "sha256": hash.sha256]]]
            let manifestFile = directory.appending(path: "manifest.json")
            if FileManager.default.fileExists(atPath: manifestFile.path) {
                guard let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any],
                      previous["runID"] as? String == value.runID, previous["targetFingerprint"] as? String == target,
                      previous["sourceRevision"] as? String == value.sourceRevision,
                      previous["scenario"] as? String == value.scenario,
                      let media = (previous["media"] as? [[String: Any]])?.first,
                      media["sha256"] as? String == hash.sha256 else { throw BackgroundValidationLedger.Failure.wrongBinding }
                manifest = previous
            } else {
                manifest = generatedManifest
                try save(manifest, name: "manifest.json")
            }
            if !restoring {
                #if targetEnvironment(simulator)
                let physical = false
                #else
                let physical = true
                #endif
                record = ["schemaVersion": 2, "runID": value.runID, "scenario": value.scenario,
                    "sourceRevision": value.sourceRevision, "targetFingerprint": target, "appLifecycle": "unaltered",
                    "physicalDevice": physical, "events": [], "uploads": []]
                events = []; assetIDs = []; canClean = false
                ledger = BackgroundValidationLedger(binding: .init(runID: value.runID, sourceRevision: value.sourceRevision,
                    targetFingerprint: target, accountID: value.accountID, sha256: hash.sha256, sha1: hash.sha1, byteCount: hash.bytes))
            }
            try persistLedger()
            let upload = uploadRequest(value, checksum: hash.sha1)
            if ledger?.action == .open {
                try ledger?.beginOpen()
                try persistLedger()
                let opened = try await client.openBackgroundUpload(upload, filename: video.lastPathComponent, size: value.payloadBytes)
                try ledger?.receivedOpen(uploadRef: opened.uploadId, duplicateAssetID: opened.result?.id)
                // Durable before the first subsequent status or upload request.
                try persistLedger()
            }
            guard let ledger, ledger.canRun, let id = ledger.receipt?.uploadRef else {
                message = self.ledger?.canClean == true ? "Saved cleanup is pending. Resume Clean Up This Run." : "No owned staging reference. Keep this record for manual recovery; do not open or delete another upload."
                return
            }
            let opened = try await client.backgroundUploadStatus(id)
            try acceptStatus(opened, reference: id)
            guard let capability = opened.capability else { throw URLError(.cannotParseResponse) }
            let capabilityHash = SHA256.hash(data: Data(capability.utf8)).map { String(format: "%02x", $0) }.joined()
            let dropOffset: Any = value.scenario == "transport-interrupted" ? (opened.partBytes ?? 8 * 1024 * 1024) : NSNull()
            try save(["runID": value.runID, "mediaID": "transport-video", "uploadRef": id,
                "capabilitySHA256": capabilityHash, "dropOffset": dropOffset], name: "relay-registration.json")
            try event("prepared", offset: opened.offset ?? 0, authenticated: true)
            prepared = true
            message = "Prepared. Export relay-registration.json and start this run's relay before Run."
        } catch {
            prepared = false
            message = "Preparation stopped (\((error as NSError).code)). Keep the saved receipt; no credentials were exported."
        }
    }

    private func uploadRequest(_ value: ValidationRequest, checksum: String) -> AssetUploadRequest {
        AssetUploadRequest(checksum: checksum, deviceAssetId: "synthetic-" + value.runID, deviceId: "background-validation-v2",
            fileCreatedAt: Date(timeIntervalSince1970: 1_794_873_600), fileModifiedAt: Date(timeIntervalSince1970: 1_794_873_600),
            isFavorite: false, durationMs: 1000)
    }

    func run(_ input: ImoraClient?) async {
        guard !busy, prepared else { return }
        busy = true; defer { busy = false }
        do {
            let (client, value) = try await validate(input)
            guard let hash = digest, ledger?.canRun == true, let id = ledger?.receipt?.uploadRef else { throw URLError(.cannotParseResponse) }
            let relay = ImoraClient(apiURL: value.relayURL, accessToken: "unused-validation-placeholder")
            defer { relay.invalidate() }
            let upload = uploadRequest(value, checksum: hash.sha1)
            let account = client.serverKey + "|" + value.accountID
            let time = Date(timeIntervalSince1970: 1_794_873_600)
            let source = BackupEntry(modificationDate: time, isLivePhoto: false, primaryChecksum: hash.sha1)
            defer { BackgroundUploader.shared.finishedPreparing(account: account, localId: upload.deviceAssetId) }
            let video = directory.appending(path: value.runID + ".mp4")
            var current = try await client.backgroundUploadStatus(id)
            try acceptStatus(current, reference: id)
            try event("resumed-from-server", offset: current.offset ?? 0, authenticated: true)
            while current.result == nil {
                try Task.checkCancellation()
                guard client.context.isActive, input === client, let offset = current.offset,
                      let part = current.partBytes, part > 0, part <= 8 * 1024 * 1024,
                      let key = current.key, let capability = current.capability, offset < hash.bytes else {
                    throw URLError(.cannotParseResponse)
                }
                let bytes = try await Self.read(video, offset: offset, length: min(part, hash.bytes - offset))
                let sealed = try SealedUploadPart.seal(bytes, key: key, id: id, offset: offset)
                try ProtectedTemporaryFiles.prepareDirectory(BackgroundUploader.bodyDirectory)
                let body = BackgroundUploader.bodyDirectory.appending(path: "validation-" + UUID().uuidString)
                try sealed.write(to: body, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var send = true, attempts = 0
                while true {
                    do {
                        if send {
                            if !FileManager.default.fileExists(atPath: body.path) {
                                try sealed.write(to: body, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                            }
                            send = false
                            try await relay.uploadBackgroundPart(id: id, capability: capability, offset: offset, bodyURL: body,
                                upload: upload, account: account, source: source, lifetime: nil, onByteProgress: nil, onProgress: { _ in })
                        }
                        current = try await client.backgroundUploadStatus(id)
                        try acceptStatus(current, reference: id)
                        try event("resumed-from-server", offset: current.offset ?? 0, authenticated: true)
                        guard current.result != nil || (current.offset ?? -1) >= offset + Int64(bytes.count) else {
                            send = true; throw URLError(.cannotParseResponse)
                        }
                        break
                    } catch {
                        guard attempts < 3, client.context.isActive else { throw error }
                        attempts += 1
                        try await Task.sleep(for: .seconds(attempts))
                    }
                }
                try? FileManager.default.removeItem(at: body)
                state = current
                try event("committed-part", offset: current.offset ?? hash.bytes, authenticated: true)
            }
            guard let result = current.result else { throw URLError(.cannotParseResponse) }
            guard ledger?.receipt?.provisionalAssetID == result.id, ledger?.receipt?.mayVerifyAsset == true else {
                message = "Only a duplicate result was observed. Its asset is provisional; manual recovery is required. The owned staging reference can still be cancelled."
                return
            }
            try await verifyCandidateAsset(client)
            try event("verified-original", offset: hash.bytes, authenticated: true)
            canClean = true; message = "Readback verified. Export evidence, then clean up this run. Physical lock observation is still required."
        } catch { message = "Transfer paused (\((error as NSError).code)). Reconcile by preparing this same run; never guess its offset." }
    }

    func cleanup(_ input: ImoraClient?) async {
        guard !busy, canClean else { return }
        busy = true; defer { busy = false }
        freshlyVerifiedAssetID = nil
        do {
            let (client, _) = try await validate(input)
            if ledger?.canRun == true { try ledger?.beginCleanup(); try persistLedger() }
            // Single actor owns status/finalization and cancellation for this isolated run.
            for _ in 0..<8 {
                guard let action = ledger?.action else { throw BackgroundValidationLedger.Failure.invalidTransition }
                switch action {
                case .status(let ref):
                    do {
                        let status = try await client.backgroundUploadStatus(ref)
                        try acceptStatus(status, reference: ref)
                        if ledger?.receipt?.mayVerifyAsset == true {
                            do { try await verifyCandidateAsset(client) }
                            catch { /* No verified asset authority. Only owned staging may be cancelled. */ }
                        }
                    } catch ImoraError.http(let status, _) where status == 404 {
                        // Only a previously persisted cancellation intent may interpret absence as cancellation.
                        try ledger?.statusMissingAfterCancellation()
                        try persistLedger()
                    }
                case .cancel(let ref):
                    do {
                        try await client.cancelBackgroundValidationUpload(ref)
                        try ledger?.cancellationAcknowledged()
                        try persistLedger()
                    } catch {
                        try ledger?.cancellationAmbiguous()
                        try persistLedger()
                        throw error
                    }
                case .removeAsset(let asset):
                    var exists = true
                    do { if freshlyVerifiedAssetID != asset { try await verifyCandidateAsset(client) } }
                    catch ImoraError.http(let status, _) where status == 404 { exists = false }
                    if exists {
                        guard ledger?.receipt?.assetID == asset else { throw BackgroundValidationLedger.Failure.invalidReceipt }
                        try await client.trashAssets(ids: [asset], force: true)
                    }
                    try ledger?.assetRemovalConfirmed(asset)
                    try persistLedger()
                case .verifyAsset:
                    try await verifyCandidateAsset(client)
                case .finished: break
                case .open, .manualRecovery: throw BackgroundValidationLedger.Failure.invalidTransition
                }
                if ledger?.isCleaned == true { break }
            }
            guard ledger?.isCleaned == true else { throw BackgroundValidationLedger.Failure.invalidTransition }
            try event("cleaned-up-synthetic-video", authenticated: true)
            await client.invalidateMediaCache(assetIDs: assetIDs)
            if let request { try? FileManager.default.removeItem(at: directory.appending(path: request.runID + ".mp4")) }
            canClean = false; message = "Created asset cleaned. Export manifest/record and add external lock observation before review."
        } catch {
            if let ledger, case .stagingCancelled = ledger.state {
                message = "Owned staging was cancelled. The provisional asset was not deleted and needs manual recovery."
            } else {
                message = "Cleanup incomplete (\((error as NSError).code)). Keep the exact staging and result receipts."
            }
        }
    }

    @concurrent private static func hashes(_ url: URL) async throws -> (sha1: String, sha256: String, bytes: Int64) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var sha1 = Insecure.SHA1(), sha256 = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); sha1.update(data: data); sha256.update(data: data); count += Int64(data.count)
        }
        return (Data(sha1.finalize()).base64EncodedString(), sha256.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    @concurrent private static func read(_ url: URL, offset: Int64, length: Int64) async throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        guard let bytes = try file.read(upToCount: Int(length)), bytes.count == length else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}
#endif
