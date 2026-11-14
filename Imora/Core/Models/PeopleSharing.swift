import Foundation

/// what another member of the cluster group may do with a person they were given.
nonisolated enum PersonShareRole: String, Codable, CaseIterable, Hashable, Sendable {
    case read
    case write
    case admin

    /// a role this build does not know reads as the most limited one.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .read
    }

    var title: String {
        switch self {
        case .read: String(localized: "Can View")
        case .write: String(localized: "Can Edit")
        case .admin: String(localized: "Can Manage")
        }
    }

    var hint: String {
        switch self {
        case .read: String(localized: "Sees the person, their name and birthday.")
        case .write: String(localized: "Can also rename them and set their birthday.")
        case .admin: String(localized: "Can also merge and delete them.")
        }
    }
}

/// a user a person is shared with or by, with the role of that share.
nonisolated struct PersonShareUser: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
    let profileImagePath: String?
    let avatarColor: String?
    let role: PersonShareRole

    var user: User {
        User(id: id, email: email, name: name, profileImagePath: profileImagePath, avatarColor: avatarColor)
    }
}

/// another owner's person of the same human, shared with the viewer. the
/// server folds them into one card and lists their names here.
nonisolated struct OtherPerson: Codable, Hashable, Sendable {
    let sharedById: String
    let name: String
    let birthDate: String?
    let role: PersonShareRole
}

/// one share, GET /people/users.
nonisolated struct PersonUserShare: Decodable, Hashable, Identifiable, Sendable {
    let personId: String
    let sharedById: String
    let sharedWithId: String
    let role: PersonShareRole
    let sharedBy: User
    let sharedWith: User

    var id: String { "\(personId):\(sharedById):\(sharedWithId)" }
}

/// which person rows a name or birthday edit changes: every owner's copy the
/// user may edit, or only their own.
nonisolated enum PersonUpdateStrategy: String, Codable, Hashable, Sendable {
    case everyone
    case onlyMe = "self"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .everyone
    }
}
