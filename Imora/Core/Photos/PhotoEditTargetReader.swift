import Foundation
import Photos

/// Read-only adapters for the future save-target UI. Existing save paths do not
/// call this reader, and a resolved baseline does not grant commit authority.
@MainActor
final class PhotoEditTargetReader: PhotoEditTargetReading {
    let context: PhotoEditTargetContext
    private let client: ImoraClient
    private var localEditors: [String: LocalPhotoEditor] = [:]
    private var localEpochs: [String: Int] = [:]
    private var remoteDetails: [String: AssetDetail] = [:]
    private var remoteElevation: [String: Bool] = [:]

    init(client: ImoraClient, localEditor: LocalPhotoEditor? = nil) {
        self.client = client
        context = .init(scope: client.mediaDisplayScope, session: client.context.id)
        if let localEditor { localEditors[localEditor.localIdentifier] = localEditor }
    }

    var isCurrent: Bool {
        client.context.isActive && client.context.id == context.session && client.mediaDisplayScope == context.scope
    }

    private func checkContext() throws {
        guard context.scope.accountID?.isEmpty == false else { throw PhotoEditTargetIssue.unverifiedAccount }
        guard isCurrent else { throw PhotoEditTargetIssue.changedContext }
    }

    private func checkLocal(_ id: String) throws {
        try checkContext()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              !asset.isHidden, asset.canPerform(.content) else { throw PhotoEditTargetIssue.unavailable }
        guard asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive) else {
            throw PhotoEditTargetIssue.unsupportedMedia
        }
    }

    func localTarget(id: String) async throws -> PhotoEditTargetSnapshot {
        try checkLocal(id)
        DeviceMediaFactsStore.shared.startObserving()
        let epoch = DeviceMediaFactsStore.shared.generation
        let editor: LocalPhotoEditor
        if let current = localEditors[id] { editor = current }
        else { editor = try await LocalPhotoEditor.open(localIdentifier: id) }
        try checkLocal(id)
        guard editor.isCurrent, epoch == DeviceMediaFactsStore.shared.generation else { throw PhotoEditTargetIssue.sourceChanged }
        localEditors[id] = editor; localEpochs[id] = epoch
        return .init(id: .local(id), context: context,
                     baseline: .init(sourceRevision: editor.sourceRevision, edits: editor.recipe.edits, localModification: editor.modificationDate),
                     width: editor.originalWidth, height: editor.originalHeight)
    }

    private func checkCloud(_ detail: AssetDetail, id: String, elevation: Bool) throws {
        try checkContext()
        guard detail.id == id, detail.ownerId == context.scope.accountID,
              !detail.isTrashed, detail.visibility != .hidden, detail.canEdit != false else {
            throw PhotoEditTargetIssue.unavailable
        }
        guard detail.type == .image, detail.livePhotoVideoId == nil else { throw PhotoEditTargetIssue.unsupportedMedia }
        guard !(elevation || detail.visibility == .locked) || client.lockedMediaLease?.isCurrent == true else {
            throw PhotoEditTargetIssue.unavailable
        }
    }

    private func dimension(_ value: Double?, fallback: Int?) -> Int? {
        guard let value else { return fallback }
        guard value.isFinite, value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    func cloudTarget(id: String, requiresElevation: Bool) async throws -> PhotoEditTargetSnapshot {
        try checkContext()
        guard !requiresElevation || client.lockedMediaLease?.isCurrent == true else { throw PhotoEditTargetIssue.unavailable }
        let detail = try await client.assetDetail(id: id)
        try checkCloud(detail, id: id, elevation: requiresElevation)
        let edits = try await client.assetEdits(id: id)
        try checkCloud(detail, id: id, elevation: requiresElevation)
        guard let checksum = detail.checksum, Data(base64Encoded: checksum)?.count == 20,
              let width = dimension(detail.exifInfo?.exifImageWidth, fallback: detail.width), width > 0,
              let height = dimension(detail.exifInfo?.exifImageHeight, fallback: detail.height), height > 0 else {
            throw PhotoEditTargetIssue.invalidOriginal
        }
        remoteDetails[id] = detail; remoteElevation[id] = requiresElevation || detail.visibility == .locked
        return .init(id: .cloud(id), context: context,
                     baseline: .init(sourceRevision: checksum, edits: edits, localModification: nil), width: width, height: height)
    }

    func original(for target: PhotoEditTargetSnapshot) async throws -> PhotoEditOriginalFingerprint {
        try checkContext()
        guard target.context == context else { throw PhotoEditTargetIssue.changedContext }
        switch target.id {
        case .local(let id):
            try checkLocal(id)
            guard let editor = localEditors[id] else { throw PhotoEditTargetIssue.unavailable }
            let original = try await editor.originalFingerprintForTargetBinding()
            try await validate(target)
            return original
        case .cloud(let id):
            guard let detail = remoteDetails[id] else { throw PhotoEditTargetIssue.unavailable }
            let elevation = remoteElevation[id] == true
            try checkCloud(detail, id: id, elevation: elevation)
            // .editInput cannot use retained playback; originalURL always has edited=false.
            let file = try await client.localMediaFile(client.originalURL(assetID: id), role: .editInput,
                contentRevision: target.baseline.sourceRevision, requiresElevation: elevation)
            let original = try await PhotoEditOriginalFingerprint.read(fileURL: file.url, role: .serverOriginal)
            _ = try file.url
            guard original.sha1 == target.baseline.sourceRevision else { throw PhotoEditTargetIssue.checksumMismatch }
            try await validate(target)
            return original
        }
    }

    func validate(_ target: PhotoEditTargetSnapshot) async throws {
        try checkContext()
        guard target.context == context else { throw PhotoEditTargetIssue.changedContext }
        switch target.id {
        case .local(let id):
            try checkLocal(id)
            guard let editor = localEditors[id], editor.isCurrent,
                  editor.sourceRevision == target.baseline.sourceRevision,
                  editor.recipe.edits == target.baseline.edits,
                  localEpochs[id] == DeviceMediaFactsStore.shared.generation else { throw PhotoEditTargetIssue.sourceChanged }
        case .cloud(let id):
            let current = try await client.assetDetail(id: id)
            try checkCloud(current, id: id, elevation: remoteElevation[id] == true)
            let edits = try await client.assetEdits(id: id)
            try checkCloud(current, id: id, elevation: remoteElevation[id] == true)
            guard current.checksum == target.baseline.sourceRevision, edits == target.baseline.edits,
                  dimension(current.exifInfo?.exifImageWidth, fallback: current.width) == target.width,
                  dimension(current.exifInfo?.exifImageHeight, fallback: current.height) == target.height else {
                throw PhotoEditTargetIssue.sourceChanged
            }
        }
    }
}
