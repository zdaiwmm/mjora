import Foundation
import Photos

nonisolated enum PhotoSearchSource: String, CaseIterable, Identifiable {
    case cloud
    case device = "local"
    var id: String { rawValue }
    init(librarySource: String) { self = Self(rawValue: librarySource) ?? .cloud }
    var title: String {
        self == .device ? String(localized: "On Device") : String(localized: "Cloud Photos")
    }
    var prompt: String {
        self == .device ? String(localized: "Search On Device") : String(localized: "Search Cloud Photos")
    }
    var symbol: String { self == .device ? "iphone" : "icloud" }
}

nonisolated struct LocalPhotoSearchRecord: Sendable {
    var asset: Asset
    let filename: String
}

nonisolated enum LocalPhotoSearch {
    static func matches(_ record: LocalPhotoSearchRecord, query: String) -> Bool {
        let terms = folded(query).split(whereSeparator: \.isWhitespace)
        let haystack = folded(([record.filename] + PhotoDatePresentation.searchDates(wallClock: record.asset.localDate))
            .joined(separator: " "))
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func results(_ records: [LocalPhotoSearchRecord], query: String) -> [Asset] {
        records.filter { matches($0, query: query) }.map(\.asset)
            .sorted { $0.fileCreatedAt > $1.fileCreatedAt }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Metadata only: no image export, iCloud download or server request.
    @concurrent
    static func records(backedUpLocalIDs: Set<String> = []) async -> [LocalPhotoSearchRecord] {
        let snapshots = await PhotoLibraryService.browsableAssets()
        guard !Task.isCancelled else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: snapshots.map(\.localIdentifier), options: nil)
        var resources: [String: [PHAssetResource]] = [:]
        fetched.enumerateObjects { asset, _, _ in resources[asset.localIdentifier] = PHAssetResource.assetResources(for: asset) }
        return snapshots.map { snapshot in
            var asset = snapshot.asAsset(backedUp: backedUpLocalIDs.contains(snapshot.localIdentifier))
            let items = resources[snapshot.localIdentifier] ?? []
            let primary = items.first { $0.type == .photo || $0.type == .video } ?? items.first
            let name = primary?.originalFilename ?? ""
            asset.originalFileName = name
            asset.isEdited = items.contains { $0.type == .adjustmentData }
            return LocalPhotoSearchRecord(asset: asset, filename: name)
        }
    }
}
