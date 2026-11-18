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
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: options)
        var records: [LocalPhotoSearchRecord] = []
        for index in 0..<fetched.count {
            guard !Task.isCancelled else { return [] }
            let photo = fetched.object(at: index)
            guard !photo.isHidden, photo.mediaType == .image || photo.mediaType == .video else { continue }
            let snapshot = PhotoLibraryService.snapshot(of: photo)
            var asset = snapshot.asAsset(backedUp: backedUpLocalIDs.contains(snapshot.localIdentifier))
            let items = PHAssetResource.assetResources(for: photo)
            let primary = items.first { $0.type == .photo || $0.type == .video } ?? items.first
            let name = primary?.originalFilename ?? ""
            asset.originalFileName = name
            asset.isEdited = items.contains { $0.type == .adjustmentData }
            records.append(LocalPhotoSearchRecord(asset: asset, filename: name))
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == status else { return [] }
        return records
    }

    /// Re-check PhotoKit immediately before publishing. Cached backup snapshots
    /// are not authority for the current Limited Photos selection.
    @concurrent
    static func visibleIdentifiers(in identifiers: Set<String>) async -> Set<String> {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited, !Task.isCancelled else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: options)
        var visible: Set<String> = []
        for index in 0..<fetched.count {
            guard !Task.isCancelled else { return [] }
            let photo = fetched.object(at: index)
            if !photo.isHidden, photo.mediaType == .image || photo.mediaType == .video {
                visible.insert(photo.localIdentifier)
            }
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == status else { return [] }
        return visible
    }
}
