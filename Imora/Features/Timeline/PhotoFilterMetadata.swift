import Foundation
import Photos

nonisolated enum PhotoFilterMetadataError: LocalizedError {
    case incompletePagination, albumMembershipUnavailable, editStatusUnavailable
    var errorDescription: String? {
        switch self {
        case .incompletePagination: String(localized: "The server returned an incomplete library page. Retry to check album membership.")
        case .editStatusUnavailable: String(localized: "This server does not provide complete edit status for its photos.")
        case .albumMembershipUnavailable: String(localized: "App album membership could not be verified. Connect to your server and retry.")
        }
    }
}

/// Complete results only: a partial page must never become a negative membership claim.
nonisolated enum PhotoFilterMetadata {
    typealias Page = @Sendable (SearchPageToken?) async throws -> ([Asset], SearchPageToken?)

    static func collectAll(page: Page) async throws -> [Asset] {
        var token: SearchPageToken?
        var tokens = Set<SearchPageToken>()
        var seen = Set<String>()
        var result: [Asset] = []
        repeat {
            try Task.checkCancellation()
            let (assets, next) = try await page(token)
            result.append(contentsOf: assets.filter { seen.insert($0.id).inserted })
            guard let next else { return result }
            guard tokens.insert(next).inserted else { throw PhotoFilterMetadataError.incompletePagination }
            token = next
        } while true
    }

    static func albumMembership(remoteIDs: Set<String>,
                                lookup: @escaping @Sendable (String) async throws -> Bool) async throws -> [String: Bool] {
        try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var remaining = remoteIDs.makeIterator()
            for _ in 0..<min(4, remoteIDs.count) {
                if let id = remaining.next() { group.addTask { (id, try await lookup(id)) } }
            }
            var results: [String: Bool] = [:]
            for try await (id, hasAlbums) in group {
                try Task.checkCancellation()
                results[id] = hasAlbums
                if let next = remaining.next() { group.addTask { (next, try await lookup(next)) } }
            }
            return results
        }
    }

    @concurrent static func editedDeviceAssets(_ assets: [Asset]) async -> [Asset] {
        let ids = assets.compactMap(\.localIdentifier)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var edited = Set<String>()
        fetched.enumerateObjects { asset, _, _ in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.type == .adjustmentData }) {
                edited.insert(asset.localIdentifier)
            }
        }
        return assets.map { asset in
            var result = asset
            result.isEdited = asset.localIdentifier.map { edited.contains($0) }
            return result
        }
    }

    static func applyingAppAlbumMembership(to assets: [Asset], verifiedRemoteByLocal: [String: String],
                                          unfiledRemoteIDs: Set<String>, uncertainLocalIDs: Set<String>) throws -> [Asset] {
        guard uncertainLocalIDs.isDisjoint(with: Set(assets.compactMap(\.localIdentifier))) else {
            throw PhotoFilterMetadataError.albumMembershipUnavailable
        }
        return try assets.map { asset in
            var result = asset
            if let localID = asset.localIdentifier, let remoteID = verifiedRemoteByLocal[localID] {
                result.isInAppAlbum = !unfiledRemoteIDs.contains(remoteID)
            } else {
                guard asset.isLocal, !asset.isLocalBackedUp else { throw PhotoFilterMetadataError.albumMembershipUnavailable }
                result.isInAppAlbum = false
            }
            return result
        }
    }
}
