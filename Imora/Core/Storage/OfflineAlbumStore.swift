import Foundation

nonisolated struct OfflineAlbum: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case downloading, paused, ready, needsUpdate, failed }
    struct Component: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case image, poster, video }
        let kind: Kind
        let asset: Asset
        let generation: String
        var parentAsset: Asset?
        var parentGeneration: String?
        var filename: String?
        var mime: String?
        var bytes: Int64 = 0
    }
    struct Item: Codable, Sendable {
        let asset: Asset
        var components: [Component]
    }
    let album: Album
    var items: [Item]
    var state: State
    var updatedAt: Date?
    var error: String?
    var id: String { album.id }
    var bytes: Int64 { items.flatMap(\.components).reduce(0) { $0 + $1.bytes } }
    var completedCount: Int { items.filter { $0.components.allSatisfy { $0.filename != nil } }.count }
}

nonisolated struct OfflineAlbumRecovery: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable { case missingManifest, invalidManifest, unavailable }
    let scope: StableMediaScope
    let id: String
    let reason: Reason
}

nonisolated struct OfflineAlbumSnapshot: Sendable {
    let albums: [OfflineAlbum]
    let recoveryEntries: [OfflineAlbumRecovery]
}

nonisolated struct OfflineMediaFile: Sendable {
    let url: URL
    let mime: String
    let bytes: Int64
    let isCurrent: @Sendable () -> Bool
}

/// Explicitly retained media lives in Application Support, apart from purgeable
/// caches. Manifests contain no URLs, access tokens or locked-folder content.
actor OfflineAlbumStore {
    static let shared = OfflineAlbumStore()
    nonisolated static let rootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/retained-albums-v1")
    private let root: URL
    private struct IndexedComponent { let albumID: String; let component: OfflineAlbum.Component }
    private var records: [StableMediaScope: [OfflineAlbum]] = [:]
    private var recoveryRecords: [StableMediaScope: [OfflineAlbumRecovery]] = [:]
    private var mediaIndex: [StableMediaScope: [String: [IndexedComponent]]] = [:]
    init(root: URL = rootDirectory) { self.root = root }

    private func directory(_ scope: StableMediaScope, albumID: String? = nil) throws -> URL {
        guard scope.accountID != nil else { throw ServerTrustError.sessionExpired }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var result = root.appending(path: MediaDisplayKeyV1.digest(try encoder.encode(scope)))
        if let albumID { result.append(path: Self.directoryKey(albumID: albumID)) }
        return result
    }

    nonisolated static func directoryKey(albumID: String) -> String {
        MediaDisplayKeyV1.digest(Data(albumID.utf8))
    }

    func snapshot(scope: StableMediaScope, refresh: Bool = false) throws -> OfflineAlbumSnapshot {
        if refresh { records[scope] = nil; recoveryRecords[scope] = nil; mediaIndex[scope] = nil }
        return try OfflineAlbumSnapshot(albums: albums(scope: scope), recoveryEntries: recoveryRecords[scope] ?? [])
    }

    func albums(scope: StableMediaScope) throws -> [OfflineAlbum] {
        if let cached = records[scope] { return cached }
        let directory = try directory(scope)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            cache([], scope: scope); recoveryRecords[scope] = []; return []
        }
        var albums: [OfflineAlbum] = [], recovery: [OfflineAlbumRecovery] = []
        for child in children {
            let key = child.lastPathComponent
            guard key.count == 64, key.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    recovery.append(.init(scope: scope, id: key, reason: .invalidManifest)); continue
                }
                let album = try JSONDecoder().decode(OfflineAlbum.self, from: Data(contentsOf: child.appending(path: "manifest.json")))
                guard Self.directoryKey(albumID: album.id) == key else {
                    recovery.append(.init(scope: scope, id: key, reason: .invalidManifest)); continue
                }
                albums.append(album)
            } catch is DecodingError {
                recovery.append(.init(scope: scope, id: key, reason: .invalidManifest))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                recovery.append(.init(scope: scope, id: key, reason: .missingManifest))
            } catch {
                recovery.append(.init(scope: scope, id: key, reason: .unavailable))
            }
        }
        cache(albums, scope: scope)
        recoveryRecords[scope] = recovery.sorted { $0.id < $1.id }
        return records[scope] ?? []
    }

    func removeRecovery(_ entry: OfflineAlbumRecovery, scope: StableMediaScope) throws {
        guard entry.scope == scope else { throw ServerTrustError.sessionExpired }
        let current = try snapshot(scope: scope, refresh: true)
        guard current.recoveryEntries.contains(entry) else { return }
        let directory = try directory(scope).appending(path: entry.id)
        try FileManager.default.removeItem(at: directory)
        recoveryRecords[scope]?.removeAll { $0.id == entry.id }
    }

    private func cache(_ albums: [OfflineAlbum], scope: StableMediaScope) {
        records[scope] = albums.sorted { $0.album.albumName.localizedStandardCompare($1.album.albumName) == .orderedAscending }
        var index: [String: [IndexedComponent]] = [:]
        for album in albums {
            for component in album.items.flatMap(\.components) where component.filename != nil {
                index[component.asset.id, default: []].append(.init(albumID: album.id, component: component))
            }
        }
        mediaIndex[scope] = index
    }

    func album(scope: StableMediaScope, id: String) throws -> OfflineAlbum? {
        try albums(scope: scope).first { $0.id == id }
    }

    private func write(_ album: OfflineAlbum, scope: StableMediaScope) throws {
        let data = try JSONEncoder().encode(album)
        let directory = try directory(scope, albumID: album.id)
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        try data.write(to: directory.appending(path: "manifest.json"), options: .atomic)
        try ProtectedTemporaryFiles.protect(directory.appending(path: "manifest.json"))
        var albums = try self.albums(scope: scope)
        albums.removeAll { $0.id == album.id }; albums.append(album)
        cache(albums, scope: scope)
        recoveryRecords[scope]?.removeAll { $0.id == directory.lastPathComponent }
    }

    func prepare(album: Album, items: [OfflineAlbum.Item], scope: StableMediaScope) throws {
        let previous = try self.album(scope: scope, id: album.id)
        var next = OfflineAlbum(album: album, items: items, state: .downloading)
        for index in next.items.indices {
            let item = next.items[index]
            if let old = previous?.items.first(where: { $0.asset == item.asset }),
               old.components.map(\.generation) == item.components.map(\.generation) {
                next.items[index] = old
                for componentIndex in old.components.indices where file(old.components[componentIndex], albumID: album.id, scope: scope) == nil {
                    next.items[index].components[componentIndex].filename = nil
                    next.items[index].components[componentIndex].bytes = 0
                }
            }
        }
        try write(next, scope: scope)
        try prune(next, scope: scope)
    }

    func setState(_ state: OfflineAlbum.State, scope: StableMediaScope, id: String, error: String? = nil) throws {
        guard var album = try album(scope: scope, id: id) else { return }
        album.state = state; album.error = error
        if state == .ready {
            guard availableAssets(album, scope: scope).count == album.items.count else { throw CocoaError(.fileReadCorruptFile) }
            album.updatedAt = Date()
        }
        try write(album, scope: scope)
    }

    /// A component enters the durable manifest only after a complete file has
    /// passed status/MIME/length checks and an atomic same-volume rename.
    func install(temporary: URL, mime: String, expectedBytes: Int64, scope: StableMediaScope,
                 albumID: String, itemID: String, componentIndex: Int, context: AccountRequestContext) throws {
        try Task.checkCancellation()
        guard context.isActive, var album = try album(scope: scope, id: albumID),
              let index = album.items.firstIndex(where: { $0.asset.id == itemID }),
              album.state == .downloading else { throw CancellationError() }
        let component = album.items[index].components[componentIndex]
        guard Self.isCurrent(component, scope: scope) else { throw CancellationError() }
        let bytes = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0, expectedBytes <= 0 || bytes == expectedBytes,
              component.kind == .video ? mime.hasPrefix("video/") || mime == "application/octet-stream" : mime.hasPrefix("image/")
        else { throw CocoaError(.fileReadCorruptFile) }
        let directory = try directory(scope, albumID: albumID)
        let name = UUID().uuidString + (component.kind == .video ? ".mov" : ".image")
        let file = directory.appending(path: name)
        try FileManager.default.moveItem(at: temporary, to: file)
        do {
            try ProtectedTemporaryFiles.protect(file)
            try Task.checkCancellation()
            guard context.isActive, Self.isCurrent(component, scope: scope) else { throw CancellationError() }
            album.items[index].components[componentIndex].filename = name
            album.items[index].components[componentIndex].mime = mime
            album.items[index].components[componentIndex].bytes = bytes
            try write(album, scope: scope)
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    private nonisolated static func isCurrent(_ component: OfflineAlbum.Component, scope: StableMediaScope) -> Bool {
        let asset = component.asset
        let visible = asset.visibility == .timeline || asset.visibility == .archive
        let parentCurrent: Bool
        if component.kind == .video, let parent = component.parentAsset,
           let generation = component.parentGeneration {
            parentCurrent = !parent.isTrashed && (parent.visibility == .timeline || parent.visibility == .archive)
                && parent.livePhotoVideoId == asset.id
                && MediaContentGenerations.shared.isCurrent(scope: scope, subject: .remoteAsset(parent.id),
                    sourceRevision: parent.thumbhash ?? "", generation: generation, visibilityPolicy: parent.visibility.rawValue)
        } else { parentCurrent = component.parentAsset == nil && component.parentGeneration == nil }
        let pairedMotion = component.kind == .video && component.parentAsset != nil && parentCurrent
        return !asset.isTrashed && parentCurrent && (visible || (asset.visibility == .hidden && pairedMotion))
            && MediaContentGenerations.shared.isCurrent(scope: scope, subject: .remoteAsset(asset.id),
                sourceRevision: asset.thumbhash ?? "", generation: component.generation, visibilityPolicy: asset.visibility.rawValue)
    }

    private func file(_ component: OfflineAlbum.Component, albumID: String, scope: StableMediaScope) -> OfflineMediaFile? {
        guard Self.isCurrent(component, scope: scope), let name = component.filename,
              name == URL(fileURLWithPath: name).lastPathComponent,
              let directory = try? directory(scope, albumID: albumID) else { return nil }
        let file = directory.appending(path: name)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == component.bytes else { return nil }
        return OfflineMediaFile(url: file, mime: component.mime ?? "application/octet-stream", bytes: component.bytes,
            isCurrent: { Self.isCurrent(component, scope: scope) && FileManager.default.isReadableFile(atPath: file.path) })
    }

    func availableAssets(_ album: OfflineAlbum, scope: StableMediaScope) -> [Asset] {
        album.items.filter { item in
            !item.components.isEmpty && item.components.allSatisfy { file($0, albumID: album.id, scope: scope) != nil }
        }.map(\.asset).sorted { first, second in
            guard first.localDate != second.localDate else { return first.id < second.id }
            return album.album.order == "asc" ? first.localDate < second.localDate : first.localDate > second.localDate
        }
    }

    func componentAvailable(scope: StableMediaScope, albumID: String, itemID: String, index: Int) throws -> Bool {
        guard let album = try album(scope: scope, id: albumID),
              let item = album.items.first(where: { $0.asset.id == itemID }), item.components.indices.contains(index) else { return false }
        return file(item.components[index], albumID: albumID, scope: scope) != nil
    }

    func media(scope: StableMediaScope, url: URL) throws -> OfflineMediaFile? {
        let path = url.pathComponents
        guard let index = path.lastIndex(of: "assets"), path.count == index + 3 || path.count == index + 4 else { return nil }
        let id = path[index + 1], resource = path[index + 2]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !query.contains(where: { $0.name == "edited" && $0.value == "false" }) else { return nil }
        let revision = query.first { $0.name == "c" }?.value
        _ = try albums(scope: scope)
        for entry in mediaIndex[scope]?[id] ?? [] {
            let component = entry.component
            let matches = resource == "thumbnail" ? component.kind != .video
                : resource == "original" ? component.kind == .image
                : resource == "video" && path.last == "playback" && component.kind == .video
            guard matches, revision == nil || revision == component.asset.thumbhash else { continue }
            if let file = file(component, albumID: entry.albumID, scope: scope) { return file }
        }
        return nil
    }

    func invalidate(scope: StableMediaScope, ids: Set<String>?, remove: Bool = false) throws {
        for var album in try albums(scope: scope) {
            guard ids == nil || album.items.contains(where: { $0.components.contains { ids!.contains($0.asset.id) } }) else { continue }
            for index in album.items.indices {
                guard ids == nil || album.items[index].components.contains(where: { ids!.contains($0.asset.id) }) else { continue }
                for component in album.items[index].components {
                    if let name = component.filename { try? FileManager.default.removeItem(at: directory(scope, albumID: album.id).appending(path: name)) }
                }
                album.items[index].components = album.items[index].components.map { component in
                    var copy = component; copy.filename = nil; copy.bytes = 0; return copy
                }
            }
            if remove, let ids { album.items.removeAll { ids.contains($0.asset.id) || $0.components.contains { ids.contains($0.asset.id) } } }
            album.state = .needsUpdate
            try write(album, scope: scope)
        }
    }

    @discardableResult
    func observe(_ asset: Asset, scope: StableMediaScope) throws -> Bool {
        let changed = try albums(scope: scope).contains { album in
            album.items.flatMap(\.components).contains { stored in
                stored.asset.id == asset.id && (stored.asset.thumbhash != asset.thumbhash
                    || stored.asset.isEdited != asset.isEdited || stored.asset.livePhotoVideoId != asset.livePhotoVideoId
                    || stored.asset.visibility != asset.visibility || asset.isTrashed)
            }
        }
        if changed { try invalidate(scope: scope, ids: [asset.id], remove: !OfflineAlbumDownloads.canRetain(asset)) }
        return changed
    }

    func remove(scope: StableMediaScope, id: String? = nil) throws {
        let directory = try directory(scope, albumID: id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if let id { cache((try albums(scope: scope)).filter { $0.id != id }, scope: scope) }
        else { cache([], scope: scope) }
        if let id { recoveryRecords[scope]?.removeAll { $0.id == Self.directoryKey(albumID: id) } }
        else { recoveryRecords[scope] = [] }
    }

    private func prune(_ album: OfflineAlbum, scope: StableMediaScope) throws {
        let directory = try directory(scope, albumID: album.id)
        let retained = Set(album.items.flatMap(\.components).compactMap(\.filename) + ["manifest.json"])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !retained.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
