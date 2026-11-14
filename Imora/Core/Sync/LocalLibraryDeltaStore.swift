import Foundation
#if canImport(Photos)
import Photos
#endif

nonisolated struct LocalLibraryDelta: Sendable {
    let upserts: [DeviceAsset]
    let deletedIDs: Set<String>
    /// Opaque archived token actually consumed, never the post-scan current token.
    let nextToken: Data
}
nonisolated enum LocalLibraryDeltaError: Error { case permissionRequired, invalidToken }
nonisolated protocol LocalLibraryDeltaSource: Sendable {
    func permissionScope() async -> String
    func currentToken() async throws -> Data
    func fullScan() async throws -> [DeviceAsset]
    func changes(since token: Data) async throws -> LocalLibraryDelta
}

actor LocalLibraryDeltaStore {
    #if canImport(Photos) && !SWIFT_PACKAGE
    static let shared = LocalLibraryDeltaStore(fileURL: SyncStateStore.defaultFileURL, source: PhotoKitDeltaSource())
    #endif
    private var store: SyncStateStore?
    private var fileURL: URL?
    private let source: any LocalLibraryDeltaSource
    private var inFlight: Task<LocalLibraryDelta, Error>?
    init(store: SyncStateStore, source: any LocalLibraryDeltaSource) { self.store = store; self.source = source }
    init(fileURL: URL, source: any LocalLibraryDeltaSource) { self.fileURL = fileURL; self.source = source }
    private func database() throws -> SyncStateStore {
        if let store { return store }
        let store = try SyncStateStore(fileURL: fileURL!); self.store = store; return store
    }
    func loadChanges() async throws -> LocalLibraryDelta {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.consume() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
    func snapshot() async throws -> [DeviceAsset] { try await database().localSnapshot()?.assets ?? [] }
    private func consume() async throws -> LocalLibraryDelta {
        let store = try database()
        let permission = await source.permissionScope()
        let previous = try await store.localSnapshot()
        guard permission == "authorized" else {
            if let previous {
                try await store.commitLocalSnapshot(LocalLibraryStoredSnapshot(assets: previous.assets, token: previous.token, permission: permission))
            }
            throw LocalLibraryDeltaError.permissionRequired
        }
        if let previous, previous.permission == permission {
            do {
                let delta = try await source.changes(since: previous.token)
                try await commit(delta, old: previous.assets, permission: permission, store: store)
                return delta
            } catch LocalLibraryDeltaError.invalidToken {
                // Exactly one metadata-only rebuild; never hash or upload in this layer.
            }
        }
        let boundary = try await source.currentToken()
        let scanned = try await source.fullScan()
        let catchUp = try await source.changes(since: boundary)
        var map = Dictionary(uniqueKeysWithValues: scanned.map { ($0.localIdentifier, $0) })
        for asset in catchUp.upserts { map[asset.localIdentifier] = asset }
        for id in catchUp.deletedIDs { map[id] = nil }
        guard await source.permissionScope() == permission else { throw LocalLibraryDeltaError.permissionRequired }
        let assets = map.values.sorted { $0.localIdentifier < $1.localIdentifier }
        let removed = Set(previous?.assets.map(\.localIdentifier) ?? []).subtracting(map.keys)
        try await store.commitLocalSnapshot(LocalLibraryStoredSnapshot(assets: assets, token: catchUp.nextToken, permission: permission))
        return LocalLibraryDelta(upserts: assets, deletedIDs: removed, nextToken: catchUp.nextToken)
    }
    private func commit(_ delta: LocalLibraryDelta, old: [DeviceAsset], permission: String, store: SyncStateStore) async throws {
        var assets = Dictionary(uniqueKeysWithValues: old.map { ($0.localIdentifier, $0) })
        for asset in delta.upserts { assets[asset.localIdentifier] = asset }
        for id in delta.deletedIDs { assets[id] = nil }
        guard await source.permissionScope() == permission else { throw LocalLibraryDeltaError.permissionRequired }
        try await store.commitLocalSnapshot(LocalLibraryStoredSnapshot(assets: assets.values.sorted { $0.localIdentifier < $1.localIdentifier }, token: delta.nextToken, permission: permission))
    }
}

#if canImport(Photos) && !SWIFT_PACKAGE
/// No original-resource reads. All PhotoKit object access stays within the worker call.
nonisolated struct PhotoKitDeltaSource: LocalLibraryDeltaSource {
    func permissionScope() async -> String { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ? "authorized" : "restricted" }
    @concurrent func currentToken() async throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    }
    @concurrent func fullScan() async throws -> [DeviceAsset] { Self.read(PHAsset.fetchAssets(with: nil)) }
    @concurrent func changes(since token: Data) async throws -> LocalLibraryDelta {
        guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else { throw LocalLibraryDeltaError.invalidToken }
        let changes: PHPersistentChangeFetchResult
        do { changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: decoded) }
        catch let error as NSError {
            if error.domain == PHPhotosErrorDomain && [3105, 3210].contains(error.code) { throw LocalLibraryDeltaError.invalidToken }
            throw error
        }
        var changed: Set<String> = [], deleted: Set<String> = []
        var next = decoded
        for change in changes {
            do {
                let details = try change.changeDetails(for: .asset)
                changed.formUnion(details.insertedLocalIdentifiers)
                changed.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
                next = change.changeToken
            } catch let error as NSError {
                if error.domain == PHPhotosErrorDomain && [3105, 3210].contains(error.code) { throw LocalLibraryDeltaError.invalidToken }
                throw error
            }
        }
        changed.subtract(deleted)
        let assets = Self.read(PHAsset.fetchAssets(withLocalIdentifiers: Array(changed), options: nil))
        return LocalLibraryDelta(upserts: assets, deletedIDs: deleted, nextToken: try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true))
    }
    private static func read(_ result: PHFetchResult<PHAsset>) -> [DeviceAsset] {
        nonisolated(unsafe) var assets: [DeviceAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(DeviceAsset(localIdentifier: asset.localIdentifier, isVideo: asset.mediaType == .video,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive), isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                creationDate: asset.creationDate, modificationDate: asset.modificationDate, isFavorite: asset.isFavorite,
                durationMs: Int(asset.duration * 1000), pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight))
        }
        return assets
    }
}
#endif
