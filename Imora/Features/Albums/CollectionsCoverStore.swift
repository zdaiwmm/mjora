import Foundation
import Observation

/// One request and one prepared cover per shortcut for the current session.
@MainActor @Observable
final class CollectionsCoverStore {
    nonisolated struct Cover: Sendable {
        let url: URL
        let thumbhash: String?
    }
    nonisolated private struct Key: Hashable, Sendable {
        let id: String
        let favoritesAcrossSpaces: Bool
        init(_ id: String, favoritesAcrossSpaces: Bool) {
            self.id = id
            self.favoritesAcrossSpaces = id == "favorites" && favoritesAcrossSpaces
        }
    }

    private var contextID: UUID?
    private var covers: [Key: Cover] = [:]
    @ObservationIgnored private var loadedAt: [Key: Date] = [:]
    @ObservationIgnored private var requests: [Key: Task<Result<Cover?, Error>, Never>] = [:]
    @ObservationIgnored private var prefetchOwner = UUID()

    func cached(_ id: String, client: ImoraClient, favoritesAcrossSpaces: Bool = false) -> Cover? {
        contextID == client.context.id ? covers[Key(id, favoritesAcrossSpaces: favoritesAcrossSpaces)] : nil
    }

    func reset(client: ImoraClient?) {
        guard contextID != client?.context.id else { return }
        for task in requests.values { task.cancel() }
        requests.removeAll()
        covers.removeAll()
        loadedAt.removeAll()
        ImageLoader.shared.releasePrefetchOwner(prefetchOwner)
        prefetchOwner = UUID()
        contextID = client?.context.id
    }

    func prewarm(client: ImoraClient, layout: CollectionsLayout, favoritesAcrossSpaces: Bool) async {
        guard client.context.isActive else { return }
        reset(client: client)
        guard layout.previewSize != .none, !layout.collapsed.contains(.pinned) else { return }
        // Only the first strip's likely visible covers compete for resources.
        await withTaskGroup(of: Void.self) { group in
            for id in layout.pinnedIDs.prefix(3) {
                group.addTask { await self.load(id, client: client, favoritesAcrossSpaces: favoritesAcrossSpaces) }
            }
        }
    }

    func load(_ id: String, client: ImoraClient, favoritesAcrossSpaces: Bool) async {
        guard client.context.isActive else { return }
        reset(client: client)
        let key = Key(id, favoritesAcrossSpaces: favoritesAcrossSpaces)
        if let date = loadedAt[key], Date().timeIntervalSince(date) < 60 { return }
        let request: Task<Result<Cover?, Error>, Never>
        if let pending = requests[key] { request = pending }
        else {
            request = Task {
                do { return .success(try await Self.fetch(id, client: client, favoritesAcrossSpaces: favoritesAcrossSpaces)) }
                catch { return .failure(error) }
            }
            requests[key] = request
        }
        let result = await request.value
        guard contextID == client.context.id, client.context.isActive, !request.isCancelled else { return }
        requests[key] = nil
        guard case .success(let cover) = result else { return }
        loadedAt[key] = Date()
        covers[key] = cover
        if let cover {
            ImageLoader.shared.startPrefetching(urls: [cover.url], targetPixelSize: 400, ownerID: prefetchOwner)
        }
    }

    private static func fetch(_ id: String, client: ImoraClient, favoritesAcrossSpaces: Bool) async throws -> Cover? {
        if id == "places" {
            guard let asset = try await client.cities().first else { return nil }
            return Cover(url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), thumbhash: asset.thumbhash)
        }
        if id == "people" {
            guard let person = try await client.people().people.first else { return nil }
            return Cover(url: client.personThumbnailURL(personID: person.id, cacheKey: person.updatedAt), thumbhash: nil)
        }
        let filter: TimelineFilter
        switch id {
        case "recent": filter = TimelineFilter(orderBy: "createdAt")
        case "archive": filter = TimelineFilter(visibility: .archive)
        case "favorites":
            filter = favoritesAcrossSpaces
                ? TimelineFilter(visibility: nil, withPartners: true, withSharedSpaces: true, isFavorite: true)
                : TimelineFilter(isFavorite: true)
        default: return nil
        }
        guard let bucket = try await client.timeBuckets(filter).first,
              let asset = try await client.timeBucket(bucket.timeBucket, filter: filter).assets.first else { return nil }
        return Cover(url: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), thumbhash: asset.thumbhash)
    }
}
