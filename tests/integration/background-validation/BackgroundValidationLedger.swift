import Foundation

/// A staging reference owns staging only. Asset deletion also requires an observed created receipt and verified bytes.
nonisolated struct BackgroundValidationLedger: Codable, Equatable, Sendable {
    struct Binding: Codable, Equatable, Sendable {
        let runID: String
        let sourceRevision: String
        let targetFingerprint: String
        let accountID: String
        let sha256: String
        let sha1: String
        let byteCount: Int64
    }
    struct AssetVerification: Codable, Equatable, Sendable {
        let assetID: String
        let ownerID: String
        let originalFileName: String
        let byteCount: Int64
        let sha1: String
        let sha256: String
    }
    enum Result: Codable, Equatable, Sendable {
        case createdProvisional(String)
        case duplicateProvisional(String)
        case verified(AssetVerification)
        var id: String {
            switch self {
            case .createdProvisional(let id), .duplicateProvisional(let id): id
            case .verified(let proof): proof.assetID
            }
        }
    }
    struct Receipt: Codable, Equatable, Sendable {
        let uploadRef: String
        var confirmedOffset: Int64
        var result: Result?
        var provisionalAssetID: String? { result?.id }
        var assetID: String? { if case .verified(let proof) = result { proof.assetID } else { nil } }
        var mayVerifyAsset: Bool {
            switch result {
            case .createdProvisional, .verified: true
            default: false
            }
        }
    }
    enum CleanupStep: String, Codable, Sendable { case inspect, cancelStaging, verifyCancellation, removeAsset }
    enum State: Codable, Equatable, Sendable {
        case ready
        case openingUnknown
        case unownedDuplicate(String)
        case owned(Receipt)
        case cleaning(Receipt, CleanupStep)
        case cleaned(Receipt)
        case stagingCancelled(Receipt)
    }
    enum Action: Equatable, Sendable {
        case open, manualRecovery, status(String), cancel(String), verifyAsset(String), removeAsset(String), finished
    }
    enum Failure: Error { case invalidTransition, wrongBinding, invalidReceipt, unconfirmedCompletion }
    let version: Int
    let binding: Binding
    private(set) var state: State

    init(binding: Binding) { version = 2; self.binding = binding; state = .ready }

    static func restore(_ data: Data, binding: Binding) throws -> Self {
        let ledger = try JSONDecoder().decode(Self.self, from: data)
        guard ledger.version == 2, ledger.binding == binding else { throw Failure.wrongBinding }
        guard binding.byteCount > 0, binding.sha256.count == 64,
              binding.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              Data(base64Encoded: binding.sha1)?.count == 20 else { throw Failure.wrongBinding }
        if let receipt = ledger.receipt {
            guard receipt.uploadRef.count == 64, receipt.uploadRef.allSatisfy({ "0123456789abcdef".contains($0) }),
                  receipt.confirmedOffset >= 0, receipt.confirmedOffset <= binding.byteCount else { throw Failure.invalidReceipt }
            if case .verified(let proof) = receipt.result, !ledger.validVerification(proof, receipt: receipt) { throw Failure.invalidReceipt }
        }
        return ledger
    }

    var receipt: Receipt? {
        switch state {
        case .owned(let value), .cleaning(let value, _), .cleaned(let value), .stagingCancelled(let value): value
        default: nil
        }
    }
    var isCleaned: Bool { if case .cleaned = state { true } else { false } }
    var canRun: Bool { if case .owned = state { true } else { false } }
    var canClean: Bool {
        if case .stagingCancelled = state { false } else { receipt != nil && !isCleaned }
    }

    var action: Action {
        switch state {
        case .ready: .open
        case .openingUnknown, .unownedDuplicate, .stagingCancelled: .manualRecovery
        case .owned(let value): .status(value.uploadRef)
        case .cleaning(let value, let step):
            switch step {
            case .inspect, .verifyCancellation: .status(value.uploadRef)
            case .cancelStaging: .cancel(value.uploadRef)
            case .removeAsset:
                if let id = value.assetID { .removeAsset(id) }
                else if value.mayVerifyAsset, let id = value.provisionalAssetID { .verifyAsset(id) }
                else { .manualRecovery }
            }
        case .cleaned: .finished
        }
    }

    mutating func beginOpen() throws {
        guard state == .ready else { throw Failure.invalidTransition }
        state = .openingUnknown
    }

    mutating func receivedOpen(uploadRef: String?, duplicateAssetID: String?) throws {
        guard state == .openingUnknown else { throw Failure.invalidTransition }
        if let ref = uploadRef {
            guard ref.count == 64, ref.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Failure.invalidReceipt }
            // Even if open contains a result, only a fresh authenticated status can bind an asset.
            state = .owned(Receipt(uploadRef: ref, confirmedOffset: 0, result: nil))
        } else if let duplicate = duplicateAssetID {
            state = .unownedDuplicate(duplicate)
        } else {
            throw Failure.invalidReceipt
        }
    }

    mutating func receivedStatus(uploadRef: String, offset: Int64, assetID: String?, resultStatus: String?) throws {
        let created = resultStatus == "created"
        guard var current = receipt, current.uploadRef == uploadRef,
              offset >= current.confirmedOffset, offset <= binding.byteCount else { throw Failure.invalidReceipt }
        guard !created || assetID == nil || offset == binding.byteCount else { throw Failure.unconfirmedCompletion }
        if let prior = current.provisionalAssetID, assetID != prior { throw Failure.invalidReceipt }
        current.confirmedOffset = offset
        if let assetID {
            switch current.result {
            case .createdProvisional, .verified: break
            default: current.result = created ? .createdProvisional(assetID) : .duplicateProvisional(assetID)
            }
        }
        switch state {
        case .owned: state = .owned(current)
        case .cleaning(_, .inspect), .cleaning(_, .verifyCancellation): state = .cleaning(current, .cancelStaging)
        default: throw Failure.invalidTransition
        }
    }

    private func validVerification(_ proof: AssetVerification, receipt: Receipt) -> Bool {
        receipt.mayVerifyAsset && receipt.provisionalAssetID == proof.assetID && receipt.confirmedOffset == binding.byteCount
            && proof.ownerID == binding.accountID && proof.originalFileName == binding.runID + ".mp4"
            && proof.byteCount == binding.byteCount && proof.sha1 == binding.sha1 && proof.sha256 == binding.sha256
    }

    mutating func verifyAsset(_ proof: AssetVerification) throws {
        guard var receipt, validVerification(proof, receipt: receipt) else { throw Failure.invalidReceipt }
        receipt.result = .verified(proof)
        switch state {
        case .owned: state = .owned(receipt)
        case .cleaning(_, let step): state = .cleaning(receipt, step)
        default: throw Failure.invalidTransition
        }
    }

    mutating func invalidateAssetVerification() throws {
        guard var receipt, case .verified(let proof) = receipt.result else { return }
        receipt.result = .createdProvisional(proof.assetID)
        switch state {
        case .owned: state = .owned(receipt)
        case .cleaning(_, let step): state = .cleaning(receipt, step)
        default: throw Failure.invalidTransition
        }
    }

    private func afterCancellation(_ receipt: Receipt) -> State {
        if receipt.assetID != nil { .cleaning(receipt, .removeAsset) }
        else if receipt.provisionalAssetID != nil { .stagingCancelled(receipt) }
        else { .cleaned(receipt) }
    }

    mutating func beginCleanup() throws {
        guard case .owned(let receipt) = state else { throw Failure.invalidTransition }
        state = .cleaning(receipt, .inspect)
    }

    mutating func cancellationAmbiguous() throws {
        guard case .cleaning(let receipt, .cancelStaging) = state else { throw Failure.invalidTransition }
        state = .cleaning(receipt, .verifyCancellation)
    }

    mutating func cancellationAcknowledged() throws {
        guard case .cleaning(let receipt, .cancelStaging) = state else { throw Failure.invalidTransition }
        state = afterCancellation(receipt)
    }

    mutating func statusMissingAfterCancellation() throws {
        guard case .cleaning(let receipt, .verifyCancellation) = state else { throw Failure.invalidTransition }
        state = afterCancellation(receipt)
    }

    mutating func assetRemovalConfirmed(_ assetID: String) throws {
        guard case .cleaning(let receipt, .removeAsset) = state, receipt.assetID == assetID else { throw Failure.invalidTransition }
        state = .cleaned(receipt)
    }
}
