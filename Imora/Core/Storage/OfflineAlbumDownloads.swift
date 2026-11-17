import AVFoundation
import Foundation
import ImageIO
import Observation

@MainActor @Observable
final class OfflineAlbumDownloads {
    static let shared = OfflineAlbumDownloads()
    private(set) var albums: [OfflineAlbum] = []
    private(set) var recoveryEntries: [OfflineAlbumRecovery] = []
    private(set) var workingIDs: Set<String> = []
    private(set) var error: String?
    @ObservationIgnored private var client: ImoraClient?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var operations: [String: UUID] = [:]
    @ObservationIgnored private var purgingScopes: Set<StableMediaScope> = []
    private struct Removal: Hashable {
        let scope: StableMediaScope
        let directoryKey: String
        init(scope: StableMediaScope, albumID: String) {
            self.scope = scope; directoryKey = OfflineAlbumStore.directoryKey(albumID: albumID)
        }
        init(scope: StableMediaScope, directoryKey: String) { self.scope = scope; self.directoryKey = directoryKey }
    }
    @ObservationIgnored private var removals: Set<Removal> = []
    #if DEBUG
    var beforeStorageRemoval: ((String?) async -> Void)?
    #endif

    func attach(_ client: ImoraClient?) async {
        if self.client !== client {
            pauseAll()
            tasks = [:]; operations = [:]; workingIDs = []
            self.client = client
            albums = []; recoveryEntries = []; error = nil
        }
        await reload(refresh: true)
    }

    func reload(refresh: Bool = false) async {
        guard let client, client.context.isActive else { albums = []; recoveryEntries = []; return }
        do {
            let snapshot = try await OfflineAlbumStore.shared.snapshot(scope: client.mediaDisplayScope, refresh: refresh)
            guard self.client === client, client.context.isActive else { return }
            albums = snapshot.albums; recoveryEntries = snapshot.recoveryEntries
            if refresh { error = nil }
        } catch {
            if self.client === client, client.context.isActive { self.error = error.localizedDescription }
        }
    }

    func download(_ album: Album, client: ImoraClient, allowsCellular: Bool = false) {
        guard client.context.isActive, client.mediaDisplayScope.accountID != nil, tasks[album.id] == nil,
              !removals.contains(.init(scope: client.mediaDisplayScope, albumID: album.id)),
              !purgingScopes.contains(client.mediaDisplayScope) else { return }
        self.client = client; error = nil
        let operation = UUID(), scope = client.mediaDisplayScope
        operations[album.id] = operation; workingIDs.insert(album.id)
        tasks[album.id] = Task {
            do {
                let fresh = try await client.album(id: album.id)
                let ids = try await client.albumAssetIDs(id: album.id)
                var items: [OfflineAlbum.Item] = []
                for id in ids.sorted() {
                    try Task.checkCancellation()
                    let read = try await client.authenticatedAsset(id: id)
                    guard read.explicitVisibility, let asset = read.assets.first, Self.canRetain(asset) else {
                        throw ImoraError.decoding(String(localized: "This album contains locked, hidden or unavailable media. Remove those items before downloading the album."))
                    }
                    read.authorizePresented([asset], visibility: asset.visibility, using: client)
                    var components = [try Self.component(asset, kind: asset.isImage ? .image : .video, scope: scope)]
                    if asset.isVideo { components.append(try Self.component(asset, kind: .poster, scope: scope)) }
                    if let motionID = asset.livePhotoVideoId {
                        let motionRead = try await client.authenticatedAsset(id: motionID)
                        guard let motion = motionRead.assets.first,
                              try motionRead.authorizeLinkedMotion(parent: asset, parentGeneration: components[0].generation,
                                  parentRead: read, using: client) else {
                            throw ImoraError.decoding(String(localized: "The Live Photo motion file is unavailable."))
                        }
                        var motionComponent = try Self.component(motion, kind: .video, scope: scope)
                        motionComponent.parentAsset = asset
                        motionComponent.parentGeneration = components[0].generation
                        components.append(motionComponent)
                    }
                    items.append(.init(asset: asset, components: components))
                }
                try Task.checkCancellation()
                guard client.context.isActive, self.client === client else { throw CancellationError() }
                try await OfflineAlbumStore.shared.prepare(album: fresh, items: items, scope: scope)
                await reload()
                for item in items {
                    for index in item.components.indices {
                        try Task.checkCancellation()
                        if try await OfflineAlbumStore.shared.componentAvailable(scope: scope, albumID: album.id, itemID: item.asset.id, index: index) { continue }
                        let component = item.components[index]
                        let url: URL = switch component.kind {
                        case .image: client.editedOriginalURL(assetID: component.asset.id)
                        case .poster: client.thumbnailURL(assetID: component.asset.id, size: "preview", cacheKey: component.asset.thumbhash)
                        case .video: client.playbackURL(assetID: component.asset.id)
                        }
                        var request = try client.authorizedRequest(url: url)
                        request.allowsCellularAccess = allowsCellular
                        request.allowsExpensiveNetworkAccess = allowsCellular
                        request.allowsConstrainedNetworkAccess = false
                        let (download, response) = try await client.transportSession(for: request).download(for: request)
                        let temporary = component.kind == .video ? download.appendingPathExtension("mov") : download
                        defer { try? FileManager.default.removeItem(at: temporary); try? FileManager.default.removeItem(at: download) }
                        if temporary != download { try FileManager.default.moveItem(at: download, to: temporary) }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                            await client.rejectMediaResponse(url: url, statusCode: code)
                            throw ImoraError.http(code, "")
                        }
                        try await Self.validateMedia(at: temporary, kind: component.kind)
                        try await OfflineAlbumStore.shared.install(temporary: temporary,
                            mime: response.mimeType?.lowercased() ?? "", expectedBytes: response.expectedContentLength,
                            scope: scope, albumID: album.id, itemID: item.asset.id, componentIndex: index, context: client.context)
                        await reload()
                    }
                }
                try Task.checkCancellation()
                try await OfflineAlbumStore.shared.setState(.ready, scope: scope, id: album.id)
            } catch {
                if operations[album.id] == operation {
                    let cancelled = Task.isCancelled || error is CancellationError
                    try? await OfflineAlbumStore.shared.setState(cancelled ? .paused : .failed,
                        scope: scope, id: album.id, error: cancelled ? nil : error.localizedDescription)
                    if !cancelled, self.client === client { self.error = error.localizedDescription }
                }
            }
            guard operations[album.id] == operation else { return }
            operations[album.id] = nil; tasks[album.id] = nil; workingIDs.remove(album.id)
            await reload()
        }
    }

    nonisolated static func canRetain(_ asset: Asset) -> Bool {
        !asset.isLocal && !asset.isTrashed && (asset.visibility == .timeline || asset.visibility == .archive)
    }

    nonisolated static func validateMedia(at url: URL, kind: OfflineAlbum.Component.Kind) async throws {
        if kind != .video {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                throw ImoraError.decoding(String(localized: "The downloaded photo could not be read."))
            }
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            let header = try handle.read(upToCount: 8) ?? Data()
            try handle.close()
            guard !header.starts(with: Data("#EXTM3U".utf8)),
                  !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty else {
                throw ImoraError.decoding(String(localized: "The downloaded video is not a self-contained playable file."))
            }
        }
    }

    private static func component(_ asset: Asset, kind: OfflineAlbum.Component.Kind, scope: StableMediaScope) throws -> OfflineAlbum.Component {
        guard let generation = MediaContentGenerations.shared.current(scope: scope, subject: .remoteAsset(asset.id)) else {
            throw ServerTrustError.sessionExpired
        }
        return .init(kind: kind, asset: asset, generation: generation)
    }

    func pause(_ id: String) { tasks[id]?.cancel() }
    func pauseAll() { tasks.values.forEach { $0.cancel() } }

    func remove(_ id: String) async {
        guard let client else { return }
        let removal = Removal(scope: client.mediaDisplayScope, albumID: id)
        guard removals.insert(removal).inserted else { return }
        defer { removals.remove(removal) }
        tasks[id]?.cancel()
        // Await cancellation before deleting files, so a late component cannot
        // recreate an explicitly removed album.
        await tasks[id]?.value
        #if DEBUG
        await beforeStorageRemoval?(id)
        #endif
        do { try await OfflineAlbumStore.shared.remove(scope: client.mediaDisplayScope, id: id) }
        catch { if self.client === client { self.error = error.localizedDescription } }
        await reload()
    }

    func removeRecovery(_ entry: OfflineAlbumRecovery) async {
        guard let client, entry.scope == client.mediaDisplayScope else { return }
        let removal = Removal(scope: entry.scope, directoryKey: entry.id)
        guard removals.insert(removal).inserted else { return }
        defer { removals.remove(removal) }
        let pending = tasks.filter { OfflineAlbumStore.directoryKey(albumID: $0.key) == entry.id }.map(\.value)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        #if DEBUG
        await beforeStorageRemoval?(entry.id)
        #endif
        do { try await OfflineAlbumStore.shared.removeRecovery(entry, scope: entry.scope) }
        catch { if self.client === client { self.error = error.localizedDescription } }
        await reload()
    }

    func signOut(_ client: ImoraClient) async {
        let scope = client.mediaDisplayScope
        purgingScopes.insert(scope)
        defer { purgingScopes.remove(scope) }
        var pending: [Task<Void, Never>] = []
        if self.client === client {
            pauseAll()
            pending = Array(tasks.values)
            self.client = nil; albums = []; recoveryEntries = []; tasks = [:]; operations = [:]; workingIDs = []
        }
        for task in pending { await task.value }
        #if DEBUG
        await beforeStorageRemoval?(nil)
        #endif
        try? await OfflineAlbumStore.shared.remove(scope: scope)
        if self.client?.mediaDisplayScope == scope { await reload() }
    }
}
