import Foundation

// noodle's gallery only. shared spaces are collaborative timelines with
// several owners; photos join by reference and stay in each owner's library.
// optional fields carry what differs between gallery releases, so a feature
// is offered when its field is there rather than by version.

nonisolated enum SharedSpaceRole: String, Codable, Hashable, Sendable {
    case owner
    case editor
    case viewer

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .viewer
    }

    var canAddAssets: Bool { self != .viewer }

    var title: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .editor: String(localized: "Editor")
        case .viewer: String(localized: "Viewer")
        }
    }
}

nonisolated struct SharedSpaceMember: Codable, Identifiable, Hashable, Sendable {
    let userId: String
    let name: String
    let email: String
    let role: SharedSpaceRole
    var avatarColor: String?
    var profileImagePath: String?
    var contributionCount: Int?
    /// whether this member mixes the space into their own main timeline.
    var showInTimeline: Bool?

    var id: String { userId }

    var user: User {
        User(id: userId, email: email, name: name, profileImagePath: profileImagePath, avatarColor: avatarColor)
    }
}

nonisolated struct SharedSpace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    let createdById: String
    var assetCount: Int?
    var memberCount: Int?
    /// gallery 5.2 and later, the release that linked albums into spaces.
    var albumCount: Int?
    var newAssetCount: Int?
    var thumbnailAssetId: String?
    var recentAssetIds: [String]?
    var members: [SharedSpaceMember]?
    /// gallery 5.10: what the signed-in member may do to the member list.
    var memberManagement: MemberManagement?

    struct MemberManagement: Codable, Hashable, Sendable {
        var canAddMembers: Bool?
        var canChangeRoles: Bool?
    }

    var supportsAlbums: Bool { albumCount != nil }

    var coverAssetID: String? { thumbnailAssetId ?? recentAssetIds?.first }

    func role(of userID: String?) -> SharedSpaceRole? {
        guard let userID else { return nil }
        return members?.first { $0.userId == userID }?.role
    }
}

/// an album linked into a space, gallery 5.2 and later.
nonisolated struct SharedSpaceAlbum: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let albumName: String
    var albumThumbnailAssetId: String?
    var assetCount: Int?
    var order: String?
}

nonisolated struct UserGroupMember: Codable, Identifiable, Hashable, Sendable {
    let userId: String
    let name: String
    let email: String
    var avatarColor: String?
    var profileImagePath: String?

    var id: String { userId }

    var user: User {
        User(id: userId, email: email, name: name, profileImagePath: profileImagePath, avatarColor: avatarColor)
    }
}

/// a named circle of users to share with at once, gallery only. groups
/// synced from an oidc provider carry an origin other than "manual".
nonisolated struct UserGroup: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var color: String?
    var origin: String?
    var members: [UserGroupMember]

    var isManual: Bool { origin == nil || origin == "manual" }
}
