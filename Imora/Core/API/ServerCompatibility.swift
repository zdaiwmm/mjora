import Foundation

/// GET /server/version. public, and the only reliable way to tell which api
/// shapes a server accepts since immich ships no capability flags.
nonisolated struct ServerVersion: Codable, Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// the oldest api the app speaks.
    static let v3_0 = ServerVersion(major: 3, minor: 0, patch: 0)
    /// date-only `for` on /memories, 3.0 wants a full datetime.
    static let v3_1 = ServerVersion(major: 3, minor: 1, patch: 0)
    /// search v2 filters and cursors on immich, /config, /public/config.
    static let v3_2 = ServerVersion(major: 3, minor: 2, patch: 0)
    /// POST /people/merge, 3.2.0 only has /people/{id}/merge.
    static let v3_2_1 = ServerVersion(major: 3, minor: 2, patch: 1)
    /// sharing people with partners on immich.
    static let v3_3 = ServerVersion(major: 3, minor: 3, patch: 0)

    static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var supportsDateOnlyMemoryQuery: Bool { self >= .v3_1 }
    var supportsConfigEndpoints: Bool { self >= .v3_2 }
    var supportsPeopleMerge: Bool { self >= .v3_2_1 }
}

/// which server software answers. noodle's gallery is an immich fork that
/// reports its own releases where immich puts its version, and imora, a
/// reimplementation of gallery's api, reports its own. so the product is
/// detected on its own and features are gated on what the server exposes,
/// never on version numbers.
nonisolated enum ServerProduct: String, Codable, Hashable, Sendable {
    case immich
    case gallery
    case imora

    var displayName: String {
        switch self {
        case .immich: "Immich"
        case .gallery: "Noodle Gallery"
        case .imora: "Imora"
        }
    }
}

/// the product, plus what the server says it serves.
nonisolated struct ServerIdentity: Codable, Hashable, Sendable {
    var product: ServerProduct
    /// imora only, from `ServerVersionReport.features`.
    var features: Set<String>? = nil
    /// imora and immich 3.4, from `ServerVersionReport.featureLevel`.
    var featureLevel: Int? = nil
    /// GET /server/features, nil when it did not answer.
    var serverFeatures: ServerFeaturesFingerprint? = nil
    /// the version /server/version reported when this was read, so a
    /// different one announced on the socket means it is stale.
    var reportedVersion: ServerVersion? = nil
    /// gallery only: GET /cleanup/calendar answered. nil when the probe failed.
    var hasCleanup: Bool? = nil
    /// gallery only: the 5.9 adjust and trim routes exist. nil when the probe failed.
    var hasAdjustAndTrim: Bool? = nil
}

/// GET /server/version with what imora adds after the version: its name
/// and the optional api areas it implements, e.g. `albums`, `stacks`. an area
/// gallery has that is missing from `features` is one imora leaves out.
/// gallery and immich stop at the version.
nonisolated struct ServerVersionReport: Decodable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let product: String?
    let features: [String]?
    /// imora, and immich from 3.4.
    let featureLevel: Int?

    var version: ServerVersion { ServerVersion(major: major, minor: minor, patch: patch) }
}

/// GET /server/features, read for the keys gallery adds. every gallery 5.x
/// build reports `peopleStatistics`, which immich never had. imora reports it
/// too, which is why /server/version is read first. the rest are capability
/// flags an older server leaves out.
nonisolated struct ServerFeaturesFingerprint: Codable, Hashable, Sendable {
    var backgroundUploadsV1: Bool? = nil
    var peopleStatistics: Bool? = nil
    /// Explicit unified photo action capability; never inferred from a server version.
    var photoEditsV1: Bool? = nil
    /// The edit list has an authoritative revision and supports conditional writes.
    var photoEditsCASV1: Bool? = nil
    /// takenAfter and takenBefore compare the local taken time, end exclusive.
    var localTakenRange: Bool? = nil
    /// POST /search/options exists.
    var searchOptions: Bool? = nil
    /// spatial scene is on in the machine learning config.
    var spatialScene: Bool? = nil
    /// a favorites browse may add partners and spaces with no visibility.
    var searchFavoritesAcrossSpaces: Bool? = nil
    /// the /sync/stream request types the server accepts.
    var syncRequestTypes: [String]? = nil

    var product: ServerProduct { peopleStatistics == nil ? .immich : .gallery }
}

/// what the app may send and offer, from both detections. an unknown product
/// keeps the immich behavior the app always had and offers nothing gallery.
nonisolated struct ServerCapabilities: Hashable, Sendable {
    var identity: ServerIdentity?
    var version: ServerVersion?
    /// `passkey.enabled` from /config, nil where the server has no such key.
    var passkeyEnabled: Bool? = nil

    var product: ServerProduct? { identity?.product }
    var isGallery: Bool { product == .gallery }
    var isImora: Bool { product == .imora }
    /// imora answers like gallery 5.7.0 on every route it implements.
    var speaksGalleryAPI: Bool { isGallery || isImora }

    /// on imora, whether it lists the area. gallery and immich serve theirs whole.
    private func imoraServes(_ area: String) -> Bool {
        identity?.features?.contains(area) == true
    }

    private var serverFeatures: ServerFeaturesFingerprint? { identity?.serverFeatures }

    /// immich 3.2 and imora when it lists them. gallery never shipped them, even on a 3.2 base.
    var supportsClusterGroups: Bool {
        if isImora { return imoraServes("clusterGroups") }
        return !isGallery && version.map { $0 >= .v3_2 } == true
    }
    var supportsSharedSpaces: Bool { isGallery || (isImora && imoraServes("sharedSpaces")) }
    var supportsUserGroups: Bool { isGallery || (isImora && imoraServes("userGroups")) }
    /// gallery's own timeline mixes in the spaces each member opted to show.
    /// imora refuses the filter while it has no spaces.
    var mergesSharedSpacesIntoTimeline: Bool { supportsSharedSpaces }
    /// search v2's filter tree, order and cursor. gallery 5.7 took the 3.2
    /// rebase but refuses them with a 400, and imora follows it. later
    /// gallery releases accept them, which the client learns by trying, so
    /// the options only search v2 offers stay off there.
    var supportsStructuredSearch: Bool { product == .immich && version.map { $0 >= .v3_2 } == true }
    var supportsTags: Bool { !isImora || imoraServes("tags") }
    /// gallery 5.4 and later, which answers 404 before, and imora when it lists them.
    var supportsFaceSuggestions: Bool { isGallery || (isImora && imoraServes("faceSuggestions")) }
    /// imora's resumable upload. immich and gallery only take multipart.
    var supportsChunkedUploads: Bool { isImora && imoraServes("chunkedUploads") }

    /// favorites belong to each viewer, set through PUT /assets/favorites even
    /// on photos the user does not own. gallery says so with its sync type.
    var supportsPerUserFavorites: Bool {
        if isImora { return imoraServes("assetFavorites") }
        return isGallery && serverFeatures?.syncRequestTypes?.contains("AssetFavoritesV1") == true
    }
    /// search dates are local days with an exclusive end.
    var supportsLocalTakenRange: Bool { serverFeatures?.localTakenRange == true }
    var supportsSearchOptions: Bool {
        serverFeatures?.searchOptions == true || (isImora && imoraServes("searchOptions"))
    }
    /// the area exists and machine learning has it on.
    var supportsSpatialScene: Bool {
        serverFeatures?.spatialScene == true && (!isImora || imoraServes("spatialScene"))
    }
    /// favorites may span partners and shared spaces.
    var supportsFavoritesAcrossSpaces: Bool { serverFeatures?.searchFavoritesAcrossSpaces == true }
    /// imora when it lists them, immich from feature level 2, and only while
    /// the config has them on.
    var supportsPasskeys: Bool {
        let served = isImora
            ? imoraServes("passkeys")
            : product == .immich && (identity?.featureLevel ?? 0) >= 2
        return served && passkeyEnabled != false
    }
    /// imora's web sign in that hands the app a one time code, `/auth/app`.
    var supportsAppLogin: Bool { isImora && imoraServes("appLogin") }
    var supportsCleanup: Bool {
        isImora ? imoraServes("cleanup") : isGallery && identity?.hasCleanup == true
    }
    var supportsPhotoEditsV1: Bool { serverFeatures?.photoEditsV1 == true }
    var supportsPhotoEditsCASV1: Bool { serverFeatures?.photoEditsCASV1 == true }
    var supportsAdjust: Bool {
        isImora ? imoraServes("adjust") : isGallery && identity?.hasAdjustAndTrim == true
    }
    var supportsTrim: Bool {
        isImora ? imoraServes("trim") : isGallery && identity?.hasAdjustAndTrim == true
    }
    /// album comments and likes. gallery and immich always serve them.
    var supportsActivities: Bool { !isImora || imoraServes("activities") }
    /// imora when it lists it, immich 3.3 and later.
    var supportsPeopleSharing: Bool {
        if isImora { return imoraServes("peopleSharing") }
        return product == .immich && version.map { $0 >= .v3_3 } == true
    }
}

/// what the sign-in screen needs before a session exists.
nonisolated struct LoginOptions: Sendable {
    var passwordLogin = true
    var oauth = false
    var oauthAutoLaunch = false
    var oauthButtonText: String?
    var loginPageMessage: String?
    /// imora's web sign in, where saved passkeys work.
    var appLogin = false
    /// picks the oauth redirect scheme the server bounces back to.
    var isImora = false
}

private nonisolated struct EnabledFlag: Decodable, Sendable {
    let enabled: Bool?
}

/// GET /public/config, the unauthenticated subset added in 3.2. every field
/// is optional because the endpoint is still marked alpha upstream.
nonisolated struct PublicConfigResponse: Decodable, Sendable {
    struct OAuth: Decodable, Sendable {
        let enabled: Bool?
        let autoLaunch: Bool?
        let buttonText: String?
    }

    struct Server: Decodable, Sendable {
        let loginPageMessage: String?
    }

    let oauth: OAuth?
    fileprivate let passwordLogin: EnabledFlag?
    let server: Server?

    var loginOptions: LoginOptions {
        LoginOptions(
            passwordLogin: passwordLogin?.enabled ?? true,
            oauth: oauth?.enabled ?? false,
            oauthAutoLaunch: oauth?.autoLaunch ?? false,
            oauthButtonText: oauth?.buttonText,
            loginPageMessage: server?.loginPageMessage
        )
    }
}

/// GET /config, the signed-in view of the system config that replaces the
/// deprecated /server/features and /server/config in 3.2.
nonisolated struct UserConfigResponse: Decodable, Sendable {
    struct MachineLearning: Decodable, Sendable {
        let enabled: Bool?
        fileprivate let clip: EnabledFlag?
        fileprivate let duplicateDetection: EnabledFlag?
        fileprivate let facialRecognition: EnabledFlag?
        fileprivate let ocr: EnabledFlag?
    }

    struct Trash: Decodable, Sendable {
        let enabled: Bool?
        let days: Int?
    }

    struct Server: Decodable, Sendable {
        let externalDomain: String?
        let loginPageMessage: String?
    }

    struct User: Decodable, Sendable {
        let deleteDelay: Int?
    }

    let machineLearning: MachineLearning?
    fileprivate let map: EnabledFlag?
    fileprivate let passkey: EnabledFlag?
    /// gallery and imora only, immich keeps smtp to the admin config.
    let notifications: AdminNotificationConfig.Notifications?
    let trash: Trash?
    let oauth: PublicConfigResponse.OAuth?
    fileprivate let passwordLogin: EnabledFlag?
    let server: Server?
    let user: User?

    /// the same derivations the server applied when it still served features.
    var features: ServerFeatures {
        let ml = machineLearning?.enabled ?? false
        let smartSearch = ml && machineLearning?.clip?.enabled == true
        return ServerFeatures(
            smartSearch: smartSearch,
            facialRecognition: ml && machineLearning?.facialRecognition?.enabled == true,
            map: map?.enabled ?? true,
            trash: trash?.enabled ?? true,
            oauth: oauth?.enabled ?? false,
            oauthAutoLaunch: oauth?.autoLaunch ?? false,
            passwordLogin: passwordLogin?.enabled ?? true,
            ocr: ml && machineLearning?.ocr?.enabled == true,
            sidecar: nil,
            duplicateDetection: smartSearch && machineLearning?.duplicateDetection?.enabled == true,
            email: notifications?.smtp?.enabled,
            passkey: passkey?.enabled
        )
    }

    var config: ServerConfig {
        ServerConfig(
            oauthButtonText: oauth?.buttonText,
            loginPageMessage: server?.loginPageMessage,
            externalDomain: server?.externalDomain,
            userDeleteDelay: user?.deleteDelay
        )
    }
}

/// the one admin config value the app reads: whether smtp can send mail.
nonisolated struct AdminNotificationConfig: Decodable, Sendable {
    struct Notifications: Decodable, Sendable {
        fileprivate let smtp: EnabledFlag?
    }

    let notifications: Notifications?

    var smtpEnabled: Bool { notifications?.smtp?.enabled ?? false }
}

/// GET /cluster-groups/requests entry, immich 3.2.
nonisolated struct ClusterGroupRequest: Decodable, Identifiable, Sendable {
    let id: String
    let clusterGroupId: String
    let userId: String
}
