import Foundation

/// one comment or like in a shared album, GET /activities. an activity on a
/// photo carries its asset id, one on the album itself carries none.
nonisolated struct AlbumActivity: Decodable, Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Decodable, Hashable, Sendable {
        case comment
        case like
    }

    let id: String
    let createdAt: String
    let user: User
    let assetId: String?
    let type: Kind
    let comment: String?

    var date: Date? { APIDate.parse(createdAt) }
    var isLike: Bool { type == .like }
}

/// GET /activities/statistics. older servers only count comments.
nonisolated struct ActivityStatistics: Decodable, Hashable, Sendable {
    let comments: Int
    let likes: Int?
}
