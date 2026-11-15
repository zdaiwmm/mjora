import Foundation
import Photos

nonisolated enum LocalFavoriteWriter {
    static func isAccessible(_ localIdentifier: String) -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject != nil
    }

    @concurrent
    static func set(localIdentifier: String, value: Bool) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              asset.canPerform(.properties)
        else { throw ImoraError.http(0, String(localized: "This device photo cannot be changed. Check photo access.")) }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: asset).isFavorite = value
        }
    }
}
