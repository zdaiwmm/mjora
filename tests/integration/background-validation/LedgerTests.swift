import Foundation

@main
struct LedgerTests {
    static let ref = String(repeating: "a", count: 64)
    static let binding = BackgroundValidationLedger.Binding(runID: "synthetic-run", sourceRevision: String(repeating: "b", count: 40),
        targetFingerprint: String(repeating: "c", count: 64), accountID: "synthetic-account", sha256: String(repeating: "d", count: 64),
        sha1: Data(repeating: 1, count: 20).base64EncodedString(), byteCount: 4096)
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool) {
        precondition(value()); checks += 1
    }
    static func restored(_ value: BackgroundValidationLedger) throws -> BackgroundValidationLedger {
        try .restore(JSONEncoder().encode(value), binding: binding)
    }
    static func owned() throws -> BackgroundValidationLedger {
        var value = BackgroundValidationLedger(binding: binding)
        try value.beginOpen(); try value.receivedOpen(uploadRef: ref, duplicateAssetID: nil)
        return try restored(value)
    }
    static func proof(_ id: String) -> BackgroundValidationLedger.AssetVerification {
        .init(assetID: id, ownerID: binding.accountID, originalFileName: binding.runID + ".mp4",
              byteCount: binding.byteCount, sha1: binding.sha1, sha256: binding.sha256)
    }
    static func main() throws {
        // An open response lost before its reference is persisted has no deletion authority.
        var unknown = BackgroundValidationLedger(binding: binding)
        try unknown.beginOpen(); unknown = try restored(unknown)
        expect(unknown.action == .manualRecovery); expect(!unknown.canClean)

        // A duplicate without a reference is never adopted, even after restart.
        var duplicate = BackgroundValidationLedger(binding: binding)
        try duplicate.beginOpen(); try duplicate.receivedOpen(uploadRef: nil, duplicateAssetID: "existing-unrelated")
        duplicate = try restored(duplicate)
        expect(duplicate.action == .manualRecovery); expect(duplicate.receipt == nil)
        do { try duplicate.beginCleanup(); preconditionFailure() } catch { checks += 1 }

        // Staging-only cancellation can complete without an asset.
        var staging = try owned()
        expect(staging.canClean); try staging.beginCleanup()
        expect(staging.action == .status(ref))
        try staging.receivedStatus(uploadRef: ref, offset: 1024, assetID: nil, resultStatus: "duplicate")
        expect(staging.action == .cancel(ref))
        try staging.cancellationAcknowledged(); staging = try restored(staging)
        expect(staging.isCleaned); expect(staging.receipt?.assetID == nil)

        // A lost final reply without any created receipt remains provisional, even for an owned ref.
        var finalReplyLost = try owned()
        finalReplyLost = try restored(finalReplyLost)
        expect(finalReplyLost.action == .status(ref))
        try finalReplyLost.receivedStatus(uploadRef: ref, offset: 4096, assetID: "unknown-duplicate", resultStatus: "duplicate")
        expect(finalReplyLost.receipt?.assetID == nil)
        expect(finalReplyLost.receipt?.provisionalAssetID == "unknown-duplicate")
        do { try finalReplyLost.verifyAsset(proof("unknown-duplicate")); preconditionFailure() } catch { checks += 1 }
        try finalReplyLost.beginCleanup()
        try finalReplyLost.receivedStatus(uploadRef: ref, offset: 4096, assetID: "unknown-duplicate", resultStatus: "duplicate")
        try finalReplyLost.cancellationAcknowledged()
        expect(finalReplyLost.action == .manualRecovery); expect(!finalReplyLost.isCleaned)
        expect(finalReplyLost.receipt?.assetID == nil)

        // A durable created receipt can be reverified after a crash, even if later status says duplicate.
        var crashBeforeAssetSave = try owned()
        try crashBeforeAssetSave.receivedStatus(uploadRef: ref, offset: 4096, assetID: "created-by-owned-stage", resultStatus: "created")
        crashBeforeAssetSave = try restored(crashBeforeAssetSave)
        expect(crashBeforeAssetSave.receipt?.assetID == nil)
        try crashBeforeAssetSave.receivedStatus(uploadRef: ref, offset: 4096, assetID: "created-by-owned-stage", resultStatus: "duplicate")
        try crashBeforeAssetSave.verifyAsset(proof("created-by-owned-stage"))
        expect(crashBeforeAssetSave.receipt?.assetID == "created-by-owned-stage")
        crashBeforeAssetSave = try restored(crashBeforeAssetSave)
        try crashBeforeAssetSave.receivedStatus(uploadRef: ref, offset: 4096, assetID: "created-by-owned-stage", resultStatus: "duplicate")
        expect(crashBeforeAssetSave.receipt?.assetID == "created-by-owned-stage")

        // Cleanup sees an asset imported before cancellation and removes only that acknowledged ID.
        var cleanup = try owned(); try cleanup.beginCleanup()
        try cleanup.receivedStatus(uploadRef: ref, offset: 4096, assetID: "owned-asset", resultStatus: "created")
        try cleanup.verifyAsset(proof("owned-asset"))
        cleanup = try restored(cleanup)
        try cleanup.cancellationAcknowledged()
        expect(cleanup.action == .removeAsset("owned-asset"))
        do { try cleanup.assetRemovalConfirmed("unrelated"); preconditionFailure() } catch { checks += 1 }
        cleanup = try restored(cleanup)
        try cleanup.assetRemovalConfirmed("owned-asset")
        expect(cleanup.isCleaned); expect(cleanup.action == .finished)

        // A lost cancellation reply is reconciled by reference. A regular missing status cannot claim cleanup.
        var cancelledReplyLost = try owned(); try cancelledReplyLost.beginCleanup()
        try cancelledReplyLost.receivedStatus(uploadRef: ref, offset: 1024, assetID: nil, resultStatus: "duplicate")
        try cancelledReplyLost.cancellationAmbiguous(); cancelledReplyLost = try restored(cancelledReplyLost)
        expect(cancelledReplyLost.action == .status(ref))
        try cancelledReplyLost.statusMissingAfterCancellation(); expect(cancelledReplyLost.isCleaned)
        var missing = try owned()
        do { try missing.statusMissingAfterCancellation(); preconditionFailure() } catch { checks += 1 }

        // If cancellation was not accepted and finalization happened, inspect the same reference again.
        var raced = try owned(); try raced.beginCleanup()
        try raced.receivedStatus(uploadRef: ref, offset: 2048, assetID: nil, resultStatus: "duplicate")
        try raced.cancellationAmbiguous()
        try raced.receivedStatus(uploadRef: ref, offset: 4096, assetID: "late-owned-asset", resultStatus: "created")
        expect(raced.receipt?.assetID == nil)
        try raced.verifyAsset(proof("late-owned-asset"))
        try raced.cancellationAcknowledged(); expect(raced.action == .removeAsset("late-owned-asset"))

        // Wrong reference, source/account binding or incomplete completion never grants ownership.
        var wrong = try owned()
        do { try wrong.receivedStatus(uploadRef: "wrong", offset: 4096, assetID: "other", resultStatus: "created"); preconditionFailure() } catch { checks += 1 }
        do { try wrong.receivedStatus(uploadRef: ref, offset: 1, assetID: "other", resultStatus: "created"); preconditionFailure() } catch { checks += 1 }
        let otherBinding = BackgroundValidationLedger.Binding(runID: binding.runID, sourceRevision: binding.sourceRevision,
            targetFingerprint: binding.targetFingerprint, accountID: "other-account", sha256: binding.sha256, sha1: binding.sha1, byteCount: binding.byteCount)
        do { _ = try BackgroundValidationLedger.restore(JSONEncoder().encode(wrong), binding: otherBinding); preconditionFailure() } catch { checks += 1 }
        let corrupted = String(data: try JSONEncoder().encode(wrong), encoding: .utf8)!.replacingOccurrences(of: "\"confirmedOffset\":0", with: "\"confirmedOffset\":-1")
        do { _ = try BackgroundValidationLedger.restore(Data(corrupted.utf8), binding: binding); preconditionFailure() } catch { checks += 1 }
        do { _ = try BackgroundValidationLedger.restore(Data("{".utf8), binding: binding); preconditionFailure() } catch { checks += 1 }
        let invalidBinding = BackgroundValidationLedger.Binding(runID: binding.runID, sourceRevision: binding.sourceRevision,
            targetFingerprint: binding.targetFingerprint, accountID: binding.accountID, sha256: "not-a-sha256", sha1: binding.sha1, byteCount: binding.byteCount)
        let invalid = BackgroundValidationLedger(binding: invalidBinding)
        do { _ = try BackgroundValidationLedger.restore(JSONEncoder().encode(invalid), binding: invalidBinding); preconditionFailure() } catch { checks += 1 }
        // Every metadata/hash gate is required, and failure retains provisional status.
        let correct = proof("new-asset")
        let badProofs = [
            BackgroundValidationLedger.AssetVerification(assetID: correct.assetID, ownerID: "foreign", originalFileName: correct.originalFileName, byteCount: correct.byteCount, sha1: correct.sha1, sha256: correct.sha256),
            .init(assetID: correct.assetID, ownerID: correct.ownerID, originalFileName: "foreign.mp4", byteCount: correct.byteCount, sha1: correct.sha1, sha256: correct.sha256),
            .init(assetID: correct.assetID, ownerID: correct.ownerID, originalFileName: correct.originalFileName, byteCount: 1, sha1: correct.sha1, sha256: correct.sha256),
            .init(assetID: correct.assetID, ownerID: correct.ownerID, originalFileName: correct.originalFileName, byteCount: correct.byteCount, sha1: "wrong", sha256: correct.sha256),
            .init(assetID: correct.assetID, ownerID: correct.ownerID, originalFileName: correct.originalFileName, byteCount: correct.byteCount, sha1: correct.sha1, sha256: "wrong")
        ]
        for bad in badProofs {
            var value = try owned()
            try value.receivedStatus(uploadRef: ref, offset: 4096, assetID: "new-asset", resultStatus: "created")
            do { try value.verifyAsset(bad); preconditionFailure() } catch { checks += 1 }
            expect(value.receipt?.assetID == nil)
        }
        var staleProof = try owned()
        try staleProof.receivedStatus(uploadRef: ref, offset: 4096, assetID: "new-asset", resultStatus: "created")
        try staleProof.verifyAsset(correct)
        try staleProof.beginCleanup(); try staleProof.receivedStatus(uploadRef: ref, offset: 4096, assetID: "new-asset", resultStatus: "duplicate")
        try staleProof.cancellationAcknowledged()
        try staleProof.invalidateAssetVerification()
        expect(staleProof.action == .verifyAsset("new-asset"))
        do { try staleProof.assetRemovalConfirmed("new-asset"); preconditionFailure() } catch { checks += 1 }
        try staleProof.verifyAsset(correct); expect(staleProof.action == .removeAsset("new-asset"))
        var unknownStatus = try owned()
        try unknownStatus.receivedStatus(uploadRef: ref, offset: 4096, assetID: "new-asset", resultStatus: "future-created-status")
        expect(unknownStatus.receipt?.assetID == nil)
        do { try unknownStatus.verifyAsset(correct); preconditionFailure() } catch { checks += 1 }
        print("Ledger behavior checks passed: \(checks)")
    }
}
