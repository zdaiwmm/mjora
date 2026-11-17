import Photos
import XCTest
@testable import Imora

final class BackupFailureDiagnosticTests: XCTestCase {
    func testLegacyFailuresRemainUnknownUntilANewFailureProvidesEvidence() throws {
        let old = Data(#"{"entries":[{"account":"owner","localIdentifier":"photo","isVideo":false,"count":126,"kind":"other","lastFailedAt":123}]}"#.utf8)
        var ledger = try JSONDecoder().decode(RepeatedBackupFailures.self, from: old)
        XCTAssertEqual(ledger.failures(account: "owner").first?.count, 126)
        XCTAssertNil(ledger.failures(account: "owner").first?.diagnostic)
        let diagnostic = BackupFailureDiagnostic(error: ImoraError.http(503, "private response"), stage: .uploading)
        ledger.recordFailure(account: "owner", localIdentifier: "photo", modificationDate: nil,
            isVideo: false, kind: .other, diagnostic: diagnostic)
        let latest = try XCTUnwrap(ledger.failures(account: "owner").first)
        XCTAssertEqual(latest.count, 127)
        XCTAssertEqual(latest.diagnostic?.code, 503)
        XCTAssertEqual(latest.diagnostic?.category, .http)
    }

    func testNumericCodesAndVerificationCausesSurviveWithoutPrivateErrorContext() throws {
        let secret = "private-response-url-filename-and-asset-marker"
        let errors: [(any Error, BackupFailureDiagnostic.Stage, BackupFailureDiagnostic.Category, Int?)] = [
            (ImoraError.http(503, secret), .uploading, .http, 503),
            (NSError(domain: NSURLErrorDomain, code: -1004,
                userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret]), .verifying, .urlSession, -1004),
            (NSError(domain: PHPhotosErrorDomain, code: 3169,
                userInfo: [NSLocalizedDescriptionKey: secret]), .uploading, .photoKit, 3169),
            (NSError(domain: NSCocoaErrorDomain, code: 257,
                userInfo: [NSLocalizedDescriptionKey: secret]), .uploading, .cocoa, 257),
            (NSError(domain: NSPOSIXErrorDomain, code: 13,
                userInfo: [NSLocalizedDescriptionKey: secret]), .verifying, .posix, 13),
            (NSError(domain: secret, code: 999, userInfo: [NSLocalizedDescriptionKey: secret]), .preparing, .other, nil)
        ]
        for (error, stage, category, code) in errors {
            let diagnostic = BackupFailureDiagnostic(error: error, stage: stage)
            XCTAssertEqual(diagnostic.category, category)
            XCTAssertEqual(diagnostic.code, code)
            XCTAssertEqual(diagnostic.stage, category == .photoKit ? .preparing : stage)
            let encoded = try JSONEncoder().encode(diagnostic)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
            XCTAssertEqual(try JSONDecoder().decode(BackupFailureDiagnostic.self, from: encoded), diagnostic)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertTrue(Set(payload.keys).isSubset(of: ["stage", "category", "code", "verificationState"]))
        }
        let pair = BackupFailureDiagnostic(error: BackupVerificationError.component(secret, .pairConflict), stage: .uploading)
        XCTAssertEqual(pair.stage, .verifying)
        XCTAssertEqual(pair.verificationState, .pairConflict)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(pair), as: UTF8.self).contains(secret))
        let mismatch = BackupFailureDiagnostic(error: BackupVerificationError.mismatch, stage: .uploading)
        XCTAssertEqual(mismatch.verificationState, .mismatch)
        XCTAssertEqual(mismatch.category, .verification)
    }

    func testOriginalReadFailureKeepsItsSafeCodeAndPreparationStage() throws {
        let marker = "private-original-\(UUID()).heic"
        let missing = FileManager.default.temporaryDirectory.appending(path: marker)
        do {
            let _: Data = try BackupPreparationBoundary.perform { try Data(contentsOf: missing) }
            XCTFail("The absent original must fail preparation")
        } catch {
            let diagnostic = BackupFailureDiagnostic(error: error, stage: .uploading)
            XCTAssertEqual(diagnostic.stage, .preparing)
            XCTAssertEqual(diagnostic.category, .cocoa)
            XCTAssertEqual(diagnostic.code, NSFileReadNoSuchFileError)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains(marker))
        }
    }

    func testChunkPreparationAndNetworkConsumptionKeepDifferentFailureStages() async throws {
        do {
            try await BackupPreparationBoundary.stream(produce: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: 13)
            }, consume: { (_: Int) in })
            XCTFail("A producer failure must propagate")
        } catch {
            let diagnostic = BackupFailureDiagnostic(error: error, stage: .uploading)
            XCTAssertEqual(diagnostic.stage, .preparing)
            XCTAssertEqual(diagnostic.category, .posix)
            XCTAssertEqual(diagnostic.code, 13)
        }
        do {
            try await BackupPreparationBoundary.stream(produce: { consume in
                try await consume(0)
            }, consume: { _ in throw URLError(.timedOut) })
            XCTFail("A failed transport must propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            let diagnostic = BackupFailureDiagnostic(error: error, stage: .uploading)
            XCTAssertEqual(diagnostic.stage, .uploading)
            XCTAssertEqual(diagnostic.category, .urlSession)
        }
        do {
            try await BackupPreparationBoundary.stream(produce: { consume in
                try await consume(0)
            }, consume: { _ in throw ImoraError.http(409, "private response") })
            XCTFail("A chunk conflict must remain available to its retry policy")
        } catch ImoraError.http(let status, _) {
            XCTAssertEqual(status, 409)
        }
    }

    func testPreparationAnnotationPreservesCancellationQuotaSizeAndChunkFallbackPolicies() {
        do {
            try BackupPreparationBoundary.perform { throw CancellationError() }
            XCTFail()
        } catch is CancellationError { }
        catch { XCTFail("Cancellation changed type") }
        do {
            try BackupPreparationBoundary.perform { throw PhotoLibraryError.unexpectedSize }
            XCTFail()
        } catch PhotoLibraryError.unexpectedSize { }
        catch { XCTFail("The multipart fallback changed type") }
        do {
            try BackupPreparationBoundary.perform { throw ChunkedAssetUpload.Unavailable() }
            XCTFail()
        } catch is ChunkedAssetUpload.Unavailable { }
        catch { XCTFail("The unknown-resource fallback changed type") }
        do {
            try BackupPreparationBoundary.perform { throw UploadSizeLimit.exceeded(actualBytes: 12, maximumBytes: 10) }
            XCTFail()
        } catch UploadSizeLimit.exceeded(let actual, let limit) {
            XCTAssertEqual(actual, 12); XCTAssertEqual(limit, 10)
        } catch { XCTFail("Size exclusion changed type") }
        do {
            try BackupPreparationBoundary.perform { throw ImoraError.http(400, "private quota response") }
            XCTFail()
        } catch ImoraError.http(let status, _) {
            XCTAssertEqual(status, 400)
        } catch { XCTFail("The confirmed-quota check lost its HTTP status") }
    }

    func testLatestAttemptReplacesTheDiagnosticAndVerifiedSuccessClearsIt() throws {
        let name = "backup-diagnostic-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var ledger = RepeatedBackupFailures()
        ledger.recordFailure(account: "owner", localIdentifier: "photo", modificationDate: nil, isVideo: false,
            kind: .other, diagnostic: .init(error: ImoraError.http(503, "private"), stage: .uploading))
        ledger.recordFailure(account: "owner", localIdentifier: "photo", modificationDate: nil, isVideo: false,
            kind: .other, diagnostic: .init(error: BackupVerificationError.mismatch, stage: .verifying))
        ledger.save(to: defaults)
        var restored = RepeatedBackupFailures.load(from: defaults)
        let failure = try XCTUnwrap(restored.failures(account: "owner").first)
        XCTAssertEqual(failure.count, 2)
        XCTAssertEqual(failure.diagnostic?.verificationState, .mismatch)
        XCTAssertNil(failure.diagnostic?.code)
        restored.clearBackedUp(account: "owner", revisions: ["photo": nil])
        XCTAssertTrue(restored.failures(account: "owner").isEmpty)
    }

    func testAddingDiagnosticsDoesNotGrowAnUnboundedAttemptHistory() {
        var ledger = RepeatedBackupFailures()
        let diagnostic = BackupFailureDiagnostic(error: ImoraError.http(503, "private"), stage: .uploading)
        for index in 0..<260 {
            ledger.recordFailure(account: "owner", localIdentifier: "photo-\(index)", modificationDate: nil,
                isVideo: false, kind: .other, diagnostic: diagnostic)
        }
        for _ in 0..<100 {
            ledger.recordFailure(account: "owner", localIdentifier: "photo-0", modificationDate: nil,
                isVideo: false, kind: .other, diagnostic: diagnostic)
        }
        XCTAssertEqual(ledger.entries.count, 250)
        XCTAssertEqual(ledger.entries.first { $0.localIdentifier == "photo-0" }?.count, 101)
    }
}
