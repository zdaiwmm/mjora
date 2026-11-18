import Foundation

nonisolated enum PhotoEditTargetSelection: String, Codable, Sendable { case local, cloud, both }

nonisolated enum PhotoEditTargetID: Codable, Equatable, Sendable {
    case local(String)
    case cloud(String)
}

nonisolated struct PhotoEditTargetContext: Equatable, Sendable {
    let scope: StableMediaScope
    let session: UUID
}

/// An observation of each editor's baseline. A server recipe observation is not
/// a CAS revision, and neither this value nor its source binding is backup proof.
nonisolated struct PhotoEditTargetBaseline: Equatable, Sendable {
    let sourceRevision: String
    let edits: [AssetEdit]
    let localModification: Date?
}

nonisolated struct PhotoEditTargetSnapshot: Equatable, Sendable {
    let id: PhotoEditTargetID
    let context: PhotoEditTargetContext
    let baseline: PhotoEditTargetBaseline
    let width: Int
    let height: Int
}

nonisolated enum PhotoEditTargetIssue: Error, Equatable, Sendable {
    case missingTarget(PhotoEditTargetSelection)
    case unverifiedAccount, changedContext, unavailable, unsupportedMedia, unsupportedRecipe
    case sourceChanged, sourceMismatch, recipeConflict, nonOriginalInput, invalidOriginal, checksumMismatch
}

nonisolated struct PhotoEditTargetCandidate: Sendable {
    let context: PhotoEditTargetContext
    let localIdentifier: String?
    /// A historical pairing is only a candidate, never an original-input proof.
    let remoteIdentifier: String?
    var requiresElevation = false
}

nonisolated enum PhotoEditResolvedTargets: Sendable {
    case local(PhotoEditTargetSnapshot)
    case cloud(PhotoEditTargetSnapshot)
    case both(local: PhotoEditTargetSnapshot, cloud: PhotoEditTargetSnapshot, original: PhotoEditOriginalFingerprint)
}

@MainActor
protocol PhotoEditTargetReading {
    var context: PhotoEditTargetContext { get }
    var isCurrent: Bool { get }
    func localTarget(id: String) async throws -> PhotoEditTargetSnapshot
    func cloudTarget(id: String, requiresElevation: Bool) async throws -> PhotoEditTargetSnapshot
    func original(for target: PhotoEditTargetSnapshot) async throws -> PhotoEditOriginalFingerprint
    func validate(_ target: PhotoEditTargetSnapshot) async throws
}

/// Resolves only explicitly selected targets. It has no mutation, upload,
/// commit-store or backup-index dependency. Original comparison is opt-in .both.
@MainActor
enum PhotoEditTargetResolver {
    static func resolve(_ selection: PhotoEditTargetSelection, candidate: PhotoEditTargetCandidate,
                        reader: any PhotoEditTargetReading) async throws -> PhotoEditResolvedTargets {
        func checkContext() throws {
            try Task.checkCancellation()
            guard candidate.context.scope.accountID?.isEmpty == false else { throw PhotoEditTargetIssue.unverifiedAccount }
            guard reader.isCurrent, reader.context == candidate.context else { throw PhotoEditTargetIssue.changedContext }
        }
        func check(_ target: PhotoEditTargetSnapshot, expected: PhotoEditTargetID) throws {
            try checkContext()
            guard target.id == expected, target.context == candidate.context else { throw PhotoEditTargetIssue.changedContext }
            guard !target.baseline.sourceRevision.isEmpty, target.width > 0, target.height > 0 else {
                throw PhotoEditTargetIssue.invalidOriginal
            }
            let recipe = LocalPhotoEditRecipe(edits: target.baseline.edits, originalWidth: target.width, originalHeight: target.height)
            guard let data = try? recipe.adjustmentData(), LocalPhotoEditRecipe.canHandle(data) else {
                throw PhotoEditTargetIssue.unsupportedRecipe
            }
        }
        try checkContext()
        var local: PhotoEditTargetSnapshot?
        var cloud: PhotoEditTargetSnapshot?
        if selection != .cloud {
            guard let id = candidate.localIdentifier, !id.isEmpty else { throw PhotoEditTargetIssue.missingTarget(.local) }
            let value = try await reader.localTarget(id: id)
            try check(value, expected: .local(id)); local = value
        }
        if selection != .local {
            guard let id = candidate.remoteIdentifier, !id.isEmpty else { throw PhotoEditTargetIssue.missingTarget(.cloud) }
            let value = try await reader.cloudTarget(id: id, requiresElevation: candidate.requiresElevation)
            try check(value, expected: .cloud(id)); cloud = value
        }
        if let local, let cloud {
            guard local.baseline.edits == cloud.baseline.edits else { throw PhotoEditTargetIssue.recipeConflict }
            let localOriginal = try await reader.original(for: local)
            try checkContext()
            let cloudOriginal = try await reader.original(for: cloud)
            try checkContext()
            guard localOriginal.role == .photoKitOriginal, cloudOriginal.role == .serverOriginal else {
                throw PhotoEditTargetIssue.nonOriginalInput
            }
            guard localOriginal.sha256 == local.baseline.sourceRevision,
                  cloudOriginal.sha1 == cloud.baseline.sourceRevision else { throw PhotoEditTargetIssue.sourceChanged }
            guard localOriginal.matches(cloudOriginal),
                  local.width == localOriginal.width, local.height == localOriginal.height,
                  cloud.width == cloudOriginal.width, cloud.height == cloudOriginal.height else {
                throw PhotoEditTargetIssue.sourceMismatch
            }
            try await reader.validate(local)
            try await reader.validate(cloud)
            try checkContext()
            return .both(local: local, cloud: cloud, original: localOriginal)
        }
        if let local {
            try await reader.validate(local); try checkContext()
            return .local(local)
        }
        if let cloud {
            try await reader.validate(cloud); try checkContext()
            return .cloud(cloud)
        }
        throw PhotoEditTargetIssue.unavailable
    }
}
