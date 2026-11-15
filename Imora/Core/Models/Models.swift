import Foundation

// MARK: - date parsing

/// the api mixes iso8601 with zone, without zone, and with variable fraction digits.
nonisolated enum APIDate {
    // both formatters are configured once here and only ever asked to parse or
    // format afterwards, which foundation supports from any thread.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    private static let naive: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = parseFixedWidth(raw) {
            return date
        }
        if let date = isoFractional.date(from: raw) ?? iso.date(from: raw) {
            return date
        }
        // no timezone designator: treat as utc wall clock, drop the fraction.
        return naive.date(from: String(raw.prefix(19)))
    }

    /// `yyyy-MM-ddTHH:mm:ss`, an optional fraction, then `Z`, `±hh:mm` or no
    /// zone, read straight from the bytes with the formatters' exact results.
    /// timeline buckets carry zone-less dates, which failed both iso formatters
    /// before the naive one matched: two seconds of a 6000 photo launch.
    /// anything else returns nil and goes through the formatters.
    private static func parseFixedWidth(_ raw: String) -> Date? {
        raw.utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            let count = bytes.count
            guard count >= 19,
                  bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
                  bytes[10] == UInt8(ascii: "T"),
                  bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":")
            else { return nil }

            func number(_ start: Int, _ end: Int) -> Int? {
                var value = 0
                for index in start..<end {
                    let digit = Int(bytes[index]) - 48
                    guard digit >= 0, digit <= 9 else { return nil }
                    value = value * 10 + digit
                }
                return value
            }

            guard let year = number(0, 4), let month = number(5, 7), let day = number(8, 10),
                  let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19),
                  (1...12).contains(month), day >= 1, hour < 24, minute < 60, second < 60
            else { return nil }
            let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let monthLengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard day <= monthLengths[month - 1] else { return nil }

            var index = 19
            var millis = 0
            var hasFraction = false
            if index < count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let start = index
                while index < count, bytes[index] >= 48, bytes[index] <= 57 {
                    if index - start < 3 { millis = millis * 10 + Int(bytes[index]) - 48 }
                    index += 1
                }
                guard index > start else { return nil }
                for _ in min(3, index - start)..<3 { millis *= 10 }
                hasFraction = true
            }

            var offset = 0
            var isZoned = false
            if index == count - 1, bytes[index] == UInt8(ascii: "Z") {
                isZoned = true
            } else if index == count - 6,
                      bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
                      bytes[index + 3] == UInt8(ascii: ":"),
                      let hours = number(index + 1, index + 3),
                      let minutes = number(index + 4, index + 6),
                      hours < 24, minutes < 60 {
                offset = (hours * 3600 + minutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
                isZoned = true
            } else if index != count {
                return nil
            }

            // days from the civil calendar, the proleptic gregorian count.
            let shiftedYear = month <= 2 ? year - 1 : year
            let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
            let yearOfEra = shiftedYear - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
            // the zone-less fallback drops the fraction, so this does too.
            guard isZoned, hasFraction else { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
            return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(millis) / 1000)
        } ?? nil
    }

    /// what the api expects back, matching javascript's toISOString.
    static func string(from date: Date) -> String {
        isoFractional.string(from: date)
    }
}

extension Date.FormatStyle {
    /// asset dates are utc wall-clock values already shifted to local time; render them without zone conversion.
    nonisolated func utc() -> Date.FormatStyle {
        var copy = self
        copy.timeZone = TimeZone(identifier: "UTC")!
        return copy
    }
}

// MARK: - auth

nonisolated struct LoginCredentials: Codable {
    let email: String
    let password: String
}

nonisolated struct LoginResponse: Codable {
    let accessToken: String
    let userId: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let profileImagePath: String
    let shouldChangePassword: Bool
}

nonisolated struct WellKnownImora: Codable {
    struct API: Codable { let endpoint: String }
    let api: API
}

// MARK: - user

nonisolated struct User: Codable, Identifiable, Hashable {
    let id: String
    let email: String
    let name: String
    let profileImagePath: String?
    let avatarColor: String?
}

nonisolated struct CurrentUser: Codable, Identifiable {
    let id: String
    let email: String
    let name: String
    let profileImagePath: String?
    let avatarColor: String?
    let isAdmin: Bool
    let quotaSizeInBytes: Int64?
    let quotaUsageInBytes: Int64?
    let storageLabel: String?
    /// set once the account is linked to the server's oauth provider.
    var oauthId: String? = nil
    /// the face recognition group the user belongs to, immich 3.2 and imora.
    var clusterGroupId: String? = nil

    var hasLinkedOAuth: Bool { oauthId?.isEmpty == false }
}

// MARK: - server

nonisolated struct ServerAbout: Codable {
    let version: String
    let versionUrl: String?
    let licensed: Bool?
    let build: String?
    let sourceRef: String?
    let sourceCommit: String?
    let nodejs: String?
}

nonisolated struct ServerFeatures: Codable {
    let smartSearch: Bool
    let facialRecognition: Bool
    let map: Bool
    let trash: Bool
    let oauth: Bool
    let oauthAutoLaunch: Bool
    let passwordLogin: Bool
    /// text recognition search, added server-side in v2.x.
    let ocr: Bool?
    /// job queue gates the admin panel reads; older servers omit them.
    let sidecar: Bool?
    let duplicateDetection: Bool?
    let email: Bool?
    /// `passkey.enabled` from /config, which /server/features never had.
    var passkey: Bool? = nil
}

/// GET /auth/status. pinCode and password say whether the account has one,
/// isElevated whether this session may read locked assets, and pinExpiresAt
/// when that elevation lapses.
nonisolated struct AuthStatus: Decodable, Sendable {
    let isElevated: Bool
    let pinCode: Bool
    let password: Bool
    let expiresAt: String?
    let pinExpiresAt: String?
}

nonisolated struct ServerConfig: Codable {
    let oauthButtonText: String?
    let loginPageMessage: String?
    let externalDomain: String?
    /// days a deleted account lingers before the server removes it.
    let userDeleteDelay: Int?
}

nonisolated struct OAuthAuthorizeResponse: Codable {
    let url: String
}

// MARK: - user preferences

nonisolated struct FeatureToggle: Codable, Hashable {
    let enabled: Bool
}

/// server-side email delivery switches. the album flags only matter while
/// `enabled` is on, which is how the web client gates them too.
nonisolated struct EmailNotificationPreferences: Codable, Hashable {
    var enabled: Bool
    var albumInvite: Bool
    var albumUpdate: Bool

    static let `default` = EmailNotificationPreferences(enabled: true, albumInvite: true, albumUpdate: true)
}

/// the people section: the feature switch, and where shared edits land.
nonisolated struct PeoplePreferences: Codable, Hashable {
    let enabled: Bool
    var updateStrategy: PersonUpdateStrategy? = nil
}

nonisolated struct UserPreferences: Codable, Hashable {
    let memories: FeatureToggle?
    let people: PeoplePreferences?
    let folders: FeatureToggle?
    let ratings: FeatureToggle?
    let tags: FeatureToggle?
    let sharedLinks: FeatureToggle?
    let emailNotifications: EmailNotificationPreferences?

    var memoriesEnabled: Bool { memories?.enabled ?? true }
    var peopleEnabled: Bool { people?.enabled ?? true }
    var peopleUpdateStrategy: PersonUpdateStrategy { people?.updateStrategy ?? .everyone }
    var tagsEnabled: Bool { tags?.enabled ?? true }
    var ratingsEnabled: Bool { ratings?.enabled ?? false }
    var email: EmailNotificationPreferences { emailNotifications ?? .default }
}

nonisolated struct ServerStorage: Codable {
    let diskAvailable: String
    let diskSize: String
    let diskUse: String
    let diskUsagePercentage: Double
    let diskSizeRaw: Int64?
}

// MARK: - assets

nonisolated enum AssetType: String, Codable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

nonisolated enum AssetVisibility: String, Codable, Sendable {
    case timeline
    case hidden
    case archive
    case locked
}

/// lightweight asset used across grids. built from timeline buckets or full
/// dtos. codable so fetched buckets can persist for offline browsing.
nonisolated struct Asset: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let ownerId: String
    let isImage: Bool
    var isFavorite: Bool
    var isTrashed: Bool
    var visibility: AssetVisibility
    var thumbhash: String?
    var fileCreatedAt: Date
    var localOffsetHours: Double
    /// milliseconds, nil for stills. a trim changes it.
    var duration: Int?
    let livePhotoVideoId: String?
    var ratio: Double
    let city: String?
    let country: String?
    /// server upload time, drives the recently-added ordering.
    var createdAt: Date?
    /// set for device-only assets merged into the timeline before backup.
    var localIdentifier: String? = nil
    /// snapshot of the backup index at merge time: true once every component
    /// of the device asset is confirmed on the server.
    var isLocalBackedUp = false
    /// device live photo whose motion half lives in photokit. the server pairs
    /// its two assets through `livePhotoVideoId`, but a device-only asset has
    /// no server ids yet and would otherwise look like a plain still.
    var hasLocalMotion = false
    /// carried opportunistically by full asset responses. timeline buckets
    /// omit these so opening a large share never waits on detail requests.
    var originalFileName: String? = nil
    var originalMimeType: String? = nil
    var isEdited: Bool? = nil
    /// the stack this asset leads. timelines asked for stacked assets only
    /// return each stack's primary, with how many photos it holds.
    var stackId: String? = nil
    var stackCount: Int? = nil
    /// Device content revision; independent of the server derivative thumbhash.
    var localImageVersion: String? = nil
    /// Exact PhotoKit subtype when known. Never inferred from a filename.
    var isScreenshot: Bool? = nil
    /// Membership in App cloud albums, not the device's Photos albums.
    var isInAppAlbum: Bool? = nil

    var isLocal: Bool { localIdentifier != nil }
    var isStacked: Bool { (stackCount ?? 0) > 1 }

    var isVideo: Bool { !isImage }

    /// a still with a motion half, from either source.
    var isLivePhoto: Bool { isImage && (livePhotoVideoId != nil || hasLocalMotion) }

    /// date shifted into the asset's local timezone for grouping and display.
    var localDate: Date { fileCreatedAt.addingTimeInterval(localOffsetHours * 3600) }

    /// upload time shifted into device-local wall clock, comparable in the
    /// same utc calendar space the grouping code uses.
    var uploadLocalDate: Date {
        (createdAt ?? fileCreatedAt).addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
    }

    var durationLabel: String? {
        guard let duration, isVideo else { return nil }
        let total = duration / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// columnar response from /timeline/bucket.
nonisolated struct TimeBucketAssets: Codable {
    let id: [String]
    let ownerId: [String]
    let isImage: [Bool]
    let isFavorite: [Bool]
    let isTrashed: [Bool]
    let visibility: [AssetVisibility]?
    let thumbhash: [String?]
    let fileCreatedAt: [String]
    let localOffsetHours: [Double]
    let duration: [Int?]
    let livePhotoVideoId: [String?]
    let ratio: [Double]
    let city: [String?]?
    let country: [String?]?
    let createdAt: [String]?
    /// `[stackId, assetCount]` per asset, nil when it is not stacked.
    let stack: [[String]?]?

    func assets() -> [Asset] {
        id.indices.map { i in
            let date = APIDate.parse(fileCreatedAt[i]) ?? .distantPast
            let stackPair = stack.flatMap { $0.indices.contains(i) ? $0[i] : nil }
            return Asset(
                id: id[i],
                ownerId: ownerId[i],
                isImage: isImage[i],
                isFavorite: isFavorite[i],
                isTrashed: isTrashed[i],
                visibility: visibility?[i] ?? .timeline,
                thumbhash: thumbhash[i],
                fileCreatedAt: date,
                localOffsetHours: localOffsetHours[i],
                duration: duration[i],
                livePhotoVideoId: livePhotoVideoId[i],
                ratio: ratio[i],
                city: city?[i] ?? nil,
                country: country?[i] ?? nil,
                createdAt: createdAt.flatMap { APIDate.parse($0[i]) },
                stackId: stackPair?.first,
                stackCount: stackPair.flatMap { $0.count > 1 ? Int($0[1]) : nil }
            )
        }
    }
}

nonisolated struct TimeBucket: Codable, Identifiable, Hashable {
    let timeBucket: String
    let count: Int
    var id: String { timeBucket }
}

// MARK: - full asset dto, used by viewer details and search results

nonisolated struct ExifInfo: Codable, Hashable {
    let make: String?
    let model: String?
    let exifImageWidth: Double?
    let exifImageHeight: Double?
    let fileSizeInByte: Int64?
    let lensModel: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Double?
    let exposureTime: String?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let dateTimeOriginal: String?
    let timeZone: String?
    let description: String?
    let rating: Double?
}

nonisolated struct AssetDetail: Codable, Identifiable, Hashable {
    let id: String
    let ownerId: String
    let type: AssetType
    let originalFileName: String
    let originalMimeType: String?
    let thumbhash: String?
    let fileCreatedAt: String
    let localDateTime: String
    /// server upload time.
    let createdAt: String?
    let isFavorite: Bool
    let isArchived: Bool?
    let isTrashed: Bool
    let visibility: AssetVisibility?
    let width: Int?
    let height: Int?
    /// milliseconds, nil for stills.
    let duration: Int?
    let exifInfo: ExifInfo?
    let livePhotoVideoId: String?
    let people: [Person]?
    let tags: [Tag]?
    let checksum: String?
    /// true once the asset has server-side edits applied.
    let isEdited: Bool?
    /// who uploaded it. only GET /assets/{id} loads it, partner and shared
    /// album assets included since 3.2.
    var owner: User? = nil
    var stack: AssetStackInfo? = nil
    /// whether the viewer may edit it, gallery and imora. absent elsewhere.
    var canEdit: Bool? = nil
    /// whether the viewer offers spatial scene on it, gallery and imora.
    var spatialScene: Bool? = nil

    func asAsset() -> Asset {
        let local = APIDate.parse(localDateTime) ?? .distantPast
        let created = APIDate.parse(fileCreatedAt) ?? .distantPast
        let ratio: Double
        if let w = width, let h = height, w > 0, h > 0 {
            ratio = Double(w) / Double(h)
        } else if let w = exifInfo?.exifImageWidth, let h = exifInfo?.exifImageHeight, w > 0, h > 0 {
            ratio = w / h
        } else {
            ratio = 1
        }
        return Asset(
            id: id,
            ownerId: ownerId,
            isImage: type == .image,
            isFavorite: isFavorite,
            isTrashed: isTrashed,
            visibility: visibility ?? (isArchived == true ? .archive : .timeline),
            thumbhash: thumbhash,
            fileCreatedAt: created,
            localOffsetHours: local.timeIntervalSince(created) / 3600,
            duration: duration,
            livePhotoVideoId: livePhotoVideoId,
            ratio: ratio,
            city: exifInfo?.city,
            country: exifInfo?.country,
            createdAt: createdAt.flatMap { APIDate.parse($0) },
            originalFileName: originalFileName,
            originalMimeType: originalMimeType,
            isEdited: isEdited,
            stackId: stack?.id,
            stackCount: stack?.assetCount
        )
    }
}

nonisolated struct AssetStackInfo: Codable, Hashable, Sendable {
    let id: String
    let primaryAssetId: String
    let assetCount: Int
}

/// GET /stacks/{id}.
nonisolated struct AssetStack: Decodable, Identifiable, Sendable {
    let id: String
    var primaryAssetId: String
    var assets: [AssetDetail]
}

// MARK: - asset edits

/// one step of the server-side non-destructive edit list. crop coordinates
/// are pixels in the original, orientation-corrected image. an action this
/// build does not know, such as `trim` or `adjust`, is kept as it came so a
/// save sends it back untouched.
nonisolated enum AssetEdit: Codable, Equatable, Sendable {
    case crop(x: Int, y: Int, width: Int, height: Int)
    case mirror(axis: String)
    case rotate(angle: Double)
    case other(action: String, parameters: JSONValue?)

    var isOther: Bool {
        if case .other = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case action, parameters }
    private enum ParameterKeys: String, CodingKey { case x, y, width, height, axis, angle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        guard ["crop", "mirror", "rotate"].contains(action) else {
            self = .other(action: action, parameters: try container.decodeIfPresent(JSONValue.self, forKey: .parameters))
            return
        }
        let parameters = try container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        switch action {
        case "crop":
            self = .crop(
                x: try parameters.decode(Int.self, forKey: .x),
                y: try parameters.decode(Int.self, forKey: .y),
                width: try parameters.decode(Int.self, forKey: .width),
                height: try parameters.decode(Int.self, forKey: .height)
            )
        case "mirror":
            self = .mirror(axis: try parameters.decode(String.self, forKey: .axis))
        case "rotate":
            self = .rotate(angle: try parameters.decode(Double.self, forKey: .angle))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: String(localized: "unknown edit action \(action)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if case .other(let action, let parameters) = self {
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(parameters, forKey: .parameters)
            return
        }
        var parameters = container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        switch self {
        case .crop(let x, let y, let width, let height):
            try container.encode("crop", forKey: .action)
            try parameters.encode(x, forKey: .x)
            try parameters.encode(y, forKey: .y)
            try parameters.encode(width, forKey: .width)
            try parameters.encode(height, forKey: .height)
        case .mirror(let axis):
            try container.encode("mirror", forKey: .action)
            try parameters.encode(axis, forKey: .axis)
        case .rotate(let angle):
            try container.encode("rotate", forKey: .action)
            try parameters.encode(angle, forKey: .angle)
        case .other:
            break
        }
    }
}

/// any json value, for payloads the app carries without reading.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - albums

nonisolated struct AlbumUser: Codable, Hashable {
    let role: String
    let user: User
}

nonisolated struct Album: Codable, Identifiable, Hashable {
    let id: String
    let albumName: String
    let description: String
    let albumThumbnailAssetId: String?
    let assetCount: Int
    let albumUsers: [AlbumUser]
    let shared: Bool
    let hasSharedLink: Bool
    let isActivityEnabled: Bool?
    let createdAt: String
    let updatedAt: String
    let startDate: String?
    let endDate: String?
    let order: String?

    /// spec guarantees the first album user is the owner.
    var owner: User? {
        albumUsers.first { $0.role == "owner" }?.user ?? albumUsers.first?.user
    }

    /// everyone except the owner, i.e. the people the album is shared with.
    var sharedUsers: [AlbumUser] {
        albumUsers.filter { $0.role != "owner" }
    }

    func role(of userID: String?) -> String? {
        guard let userID else { return nil }
        return albumUsers.first { $0.user.id == userID }?.role
    }
}

/// per-item result of album asset add and remove calls.
nonisolated struct BulkIdResult: Decodable {
    let id: String
    let success: Bool
    /// duplicate, no_permission, not_found, unknown or validation.
    let error: String?
}

// MARK: - shared links

nonisolated struct SharedLink: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let slug: String?
    let type: String
    let description: String?
    let password: String?
    let expiresAt: String?
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
    let createdAt: String
    /// populated for INDIVIDUAL links; used to find links containing an asset.
    let assets: [AssetDetail]?

    /// public path relative to the server web root.
    var sharePath: String {
        if let slug, !slug.isEmpty { return "s/\(slug)" }
        return "share/\(key)"
    }

    var expiryDate: Date? { expiresAt.flatMap { APIDate.parse($0) } }

    var isExpired: Bool {
        guard let expiryDate else { return false }
        return expiryDate < Date()
    }
}

// MARK: - people and search

nonisolated struct Person: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let thumbnailPath: String?
    var isHidden: Bool?
    /// date-only string, "yyyy-MM-dd".
    var birthDate: String?
    var isFavorite: Bool?
    /// last server-side edit. the portrait url is stable for life, so this is
    /// what busts it after a featured photo changed - on any device, which is
    /// why it has to ride along with the person rather than be observed live.
    var updatedAt: String?
    /// gallery only: "person" or "pet", with the species a pet was detected as.
    var type: String? = nil
    var species: String? = nil
    /// people sharing: the other owners' names for the same human, who shared
    /// this person with the user, and who the user shared it with.
    var otherPeople: [OtherPerson]? = nil
    var sharedBy: [PersonShareUser]? = nil
    var sharedWith: [PersonShareUser]? = nil

    var isPet: Bool { type == "pet" }
}

nonisolated struct Tag: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    /// full hierarchical path, e.g. "travel/asia".
    let value: String
    let parentId: String?
}

nonisolated struct PeopleResponse: Codable {
    let people: [Person]
    let total: Int
    let hidden: Int?
    let hasNextPage: Bool?
}

nonisolated struct PersonStatistics: Codable {
    let assets: Int
}

/// one detected or manual face region on an asset. person stays nil while
/// the face is unassigned.
nonisolated struct AssetFace: Codable, Identifiable, Hashable {
    let id: String
    let person: Person?
    let boundingBoxX1: Int?
    let boundingBoxY1: Int?
    let boundingBoxX2: Int?
    let boundingBoxY2: Int?
    let imageWidth: Int?
    let imageHeight: Int?
}

nonisolated struct SearchAssetPage: Codable {
    let count: Int
    let items: [AssetDetail]
    /// page numbers for the flat request shape, deprecated in 3.2.
    let nextPage: String?
    /// search v2 cursor, 3.2 and later.
    let nextCursor: String?
}

nonisolated struct SearchResponse: Codable {
    struct Albums: Codable { let items: [Album] }
    let albums: Albums?
    let assets: SearchAssetPage
}

nonisolated struct ExploreItem: Codable {
    let value: String
    let data: AssetDetail
}

nonisolated struct ExploreResponse: Codable {
    let fieldName: String
    let items: [ExploreItem]
}

// MARK: - map

/// one geotagged asset as returned by GET /map/markers.
nonisolated struct MapMarker: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?

    /// city, state or country, whichever the server knows first.
    var placeName: String? {
        [city, state, country].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}

// MARK: - memories

nonisolated struct Memory: Codable, Identifiable {
    struct MemoryData: Codable {
        /// the year the photos were taken, or the birth year for a birthday.
        /// gallery's rule memories, trips and the like, carry none.
        var year: Int? = nil
        /// birthday memories only, 3.3. the name is the one the person had
        /// when the memory was generated.
        var personId: String? = nil
        var personName: String? = nil
        /// imora and gallery store their generated memories as `rule` with the
        /// rule's id and the facts its title is built from, and no title.
        var ruleId: String? = nil
        var context: RuleContext? = nil
    }

    /// the facts gallery's rules keep in `data.context`. every field is read
    /// on its own, so an unexpected value only loses that field.
    struct RuleContext: Codable {
        var personName: String?
        var placeLabel: String?
        var year: Int?
        var month: Int?
        var season: String?
        var seasonYear: Int?
        var theme: String?
        var city: String?
        var personAName: String?
        var personBName: String?

        private enum CodingKeys: String, CodingKey {
            case personName, placeLabel, year, month, season, seasonYear, theme, city, personAName, personBName
        }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            func string(_ key: CodingKeys) -> String? {
                (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            }
            func int(_ key: CodingKeys) -> Int? {
                if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
                return ((try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil).map { Int($0) }
            }
            personName = string(.personName)
            placeLabel = string(.placeLabel)
            year = int(.year)
            month = int(.month)
            season = string(.season)
            seasonYear = int(.seasonYear)
            theme = string(.theme)
            city = string(.city)
            personAName = string(.personAName)
            personBName = string(.personBName)
        }
    }
    let id: String
    let type: String
    let memoryAt: String
    let data: MemoryData
    /// gallery only: display text the server wrote for its rule memories.
    var title: String? = nil
    var subtitle: String? = nil
    let assets: [AssetDetail]
    /// saved memories are kept for good, the rest expire after 30 days.
    var isSaved: Bool? = nil

    var isBirthday: Bool { type == "birthday" || (type == "rule" && data.ruleId == "birthday") }

    /// the title of a rule memory in the words of gallery's mobile app, nil
    /// for an unknown rule or missing facts.
    var ruleTitle: String? {
        guard type == "rule", let ruleId = data.ruleId, let context = data.context else { return nil }
        let monthYear: String? = context.year.flatMap { year in
            context.month.flatMap { month in
                Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
            }
        }
        .map { $0.formatted(.dateTime.month(.wide).year()) }
        switch ruleId {
        case "birthday":
            return context.personName.map { String(localized: "Happy birthday, \($0)") }
        case "recent_trip":
            return context.placeLabel.map { String(localized: "Recent trip to \($0)") }
        case "trip_anniversary":
            return context.placeLabel.map { String(localized: "Your trip to \($0)") }
        case "month_recap":
            return monthYear
        case "favorites_throwback":
            return monthYear.map { String(localized: "Favorite moments from \($0)") }
        case "video_moments":
            return monthYear.map { String(localized: "Video moments from \($0)") }
        case "season_recap":
            let seasons = ["spring": String(localized: "Spring"), "summer": String(localized: "Summer"), "autumn": String(localized: "Autumn"), "winter": String(localized: "Winter")]
            guard let season = context.season.flatMap({ seasons[$0] }), let year = context.seasonYear else { return nil }
            return String(localized: "\(season) \(String(year))")
        case "themed":
            let themes = [
                "sunset": String(localized: "Sunsets"), "beach": String(localized: "Beach days"), "food": String(localized: "Food"),
                "mountains": String(localized: "Mountains"), "snow": String(localized: "Snow days"), "city_night": String(localized: "City lights"),
            ]
            guard let theme = context.theme.flatMap({ themes[$0] }), let year = context.year else { return nil }
            return String(localized: "\(theme) from \(String(year))")
        case "on_this_day_place":
            return context.city.map { String(localized: "On this day in \($0)") }
        case "people_together":
            guard let nameA = context.personAName, let nameB = context.personBName else { return nil }
            return String(localized: "\(nameA) & \(nameB)")
        case "person_throwback":
            return context.personName.map { String(localized: "Times with \($0)") }
        default:
            return nil
        }
    }
}

// MARK: - notifications

nonisolated enum NotificationLevel: String, Decodable, Hashable, Sendable {
    case success
    case error
    case warning
    case info

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .info
    }
}

nonisolated enum NotificationKind: String, Decodable, Hashable, Sendable {
    case jobFailed = "JobFailed"
    case backupFailed = "BackupFailed"
    case systemMessage = "SystemMessage"
    case albumInvite = "AlbumInvite"
    case albumUpdate = "AlbumUpdate"
    /// an invite to share face recognition with another user's group, 3.2.
    case clusterGroupRequest = "ClusterGroupRequest"
    case custom = "Custom"

    /// a server newer than this build can name kinds we do not know; they still
    /// belong in the inbox, just without a dedicated icon.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .custom
    }
}

/// one entry of the server-side inbox, GET /notifications.
nonisolated struct ServerNotification: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String?
    let level: NotificationLevel
    let kind: NotificationKind
    let createdAt: Date
    var readAt: Date?
    /// album the entry points at, lifted out of the free-form data payload.
    let albumID: String?
    /// cluster group an invite names. the payload carries no request id, so
    /// the request itself is looked up by group when acted on.
    let clusterGroupID: String?

    var isUnread: Bool { readAt == nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, level, type, createdAt, readAt, data
    }

    private struct Payload: Decodable {
        let albumId: String?
        let clusterGroupId: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .description)
        level = try container.decodeIfPresent(NotificationLevel.self, forKey: .level) ?? .info
        kind = try container.decodeIfPresent(NotificationKind.self, forKey: .type) ?? .custom
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            .flatMap(APIDate.parse) ?? Date()
        readAt = try container.decodeIfPresent(String.self, forKey: .readAt).flatMap(APIDate.parse)
        let payload = Self.payload(in: container)
        albumID = payload?.albumId
        clusterGroupID = payload?.clusterGroupId
    }

    /// the server stringifies the payload before storing it, so the field comes
    /// back as json text; an object is accepted too in case that ever changes.
    private static func payload(in container: KeyedDecodingContainer<CodingKeys>) -> Payload? {
        if let raw = try? container.decode(String.self, forKey: .data) {
            return try? JSONDecoder().decode(Payload.self, from: Data(raw.utf8))
        }
        return try? container.decode(Payload.self, forKey: .data)
    }
}

// MARK: - account security

/// a signed-in device, GET /sessions.
nonisolated struct ServerSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: String
    let updatedAt: String
    var expiresAt: String?
    let current: Bool
    let deviceType: String
    let deviceOS: String
    var appVersion: String?
}

nonisolated struct APIKey: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: String
    let permissions: [String]
}

/// the secret is only ever returned here, once.
nonisolated struct APIKeyCreated: Decodable, Sendable {
    let apiKey: APIKey
    let secret: String
}

/// GET /passkeys, immich 3.4 and imora.
nonisolated struct Passkey: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    let createdAt: String
    let usedAt: String?
}

// MARK: - utilities

nonisolated struct DuplicateGroup: Decodable, Identifiable, Sendable {
    let duplicateId: String
    var assets: [AssetDetail]
    let suggestedKeepAssetIds: [String]

    var id: String { duplicateId }
}

nonisolated struct DuplicateResolution: Encodable, Sendable {
    let duplicateId: String
    let keepAssetIds: [String]
    let trashAssetIds: [String]
}

// MARK: - face suggestions, gallery and imora

/// an unassigned face that looks like a person, best match first.
nonisolated struct FaceSuggestion: Decodable, Identifiable, Hashable, Sendable {
    let assetFaceId: String
    let assetId: String
    let boundingBoxX1: Int
    let boundingBoxY1: Int
    let boundingBoxX2: Int
    let boundingBoxY2: Int
    let imageWidth: Int
    let imageHeight: Int
    let distance: Double

    var id: String { assetFaceId }
}

nonisolated struct FaceSuggestionPage: Decodable, Sendable {
    let items: [FaceSuggestion]
    let total: Int
}

/// one line of text the ocr job read in a photo, its box in normalized
/// corners from the top left.
nonisolated struct AssetTextLine: Decodable, Sendable {
    let text: String
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double
    let x3: Double
    let y3: Double
    let x4: Double
    let y4: Double

    var top: Double { min(y1, y2, y3, y4) }
    var left: Double { min(x1, x2, x3, x4) }
}

// MARK: - server statistics, admins only

nonisolated struct ServerStatistics: Decodable, Sendable {
    nonisolated struct UserUsage: Decodable, Identifiable, Sendable {
        let userId: String
        let userName: String
        let photos: Int
        let videos: Int
        let usage: Int64
        let quotaSizeInBytes: Int64?

        var id: String { userId }
    }

    let photos: Int
    let videos: Int
    let usage: Int64
    let usageByUser: [UserUsage]
}
