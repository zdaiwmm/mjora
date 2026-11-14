import Foundation

// MARK: - users

/// one account as the admin api returns it. quota fields are null for an
/// unlimited account, deletedAt is set once a deletion is queued.
nonisolated struct AdminUser: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var email: String
    var name: String
    var isAdmin: Bool
    var avatarColor: String?
    var profileImagePath: String?
    let createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var oauthId: String?
    var quotaSizeInBytes: Int64?
    var quotaUsageInBytes: Int64?
    var shouldChangePassword: Bool?
    /// active, removing or deleted.
    var status: String?
    var storageLabel: String?

    var isDeleted: Bool { deletedAt != nil }

    /// a queued deletion can be undone until the server starts removing.
    var canRestore: Bool { isDeleted && status == "deleted" }

    var hasQuota: Bool {
        guard let quotaSizeInBytes else { return false }
        return quotaSizeInBytes >= 0
    }

    var asUser: User {
        User(id: id, email: email, name: name, profileImagePath: profileImagePath, avatarColor: avatarColor)
    }

    var createdDate: Date? { APIDate.parse(createdAt) }
    var updatedDate: Date? { APIDate.parse(updatedAt) }
    var deletedDate: Date? { deletedAt.flatMap(APIDate.parse) }
}

/// the switches the detail page lists. every group is optional so a server
/// that predates one of them still decodes.
nonisolated struct AdminUserPreferences: Decodable, Sendable {
    struct Toggle: Decodable { let enabled: Bool? }
    struct Purchase: Decodable { let showSupportBadge: Bool? }
    struct Cast: Decodable { let gCastEnabled: Bool? }

    let emailNotifications: Toggle?
    let folders: Toggle?
    let memories: Toggle?
    let people: Toggle?
    let ratings: Toggle?
    let sharedLinks: Toggle?
    let tags: Toggle?
    let purchase: Purchase?
    let cast: Cast?

    /// title and state in the order the web page shows them.
    var features: [(title: String, enabled: Bool)] {
        [
            (String(localized: "Email Notifications"), emailNotifications?.enabled ?? false),
            (String(localized: "Folders"), folders?.enabled ?? false),
            (String(localized: "Memories"), memories?.enabled ?? false),
            (String(localized: "People"), people?.enabled ?? false),
            (String(localized: "Rating"), ratings?.enabled ?? false),
            (String(localized: "Shared Links"), sharedLinks?.enabled ?? false),
            (String(localized: "Supporter Badge"), purchase?.showSupportBadge ?? false),
            (String(localized: "Tags"), tags?.enabled ?? false),
            ("Google Cast", cast?.gCastEnabled ?? false),
        ]
    }
}

/// one login of an account, GET /admin/users/{id}/sessions.
nonisolated struct UserSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let deviceType: String
    let deviceOS: String
    let appVersion: String?
    let createdAt: String
    let updatedAt: String
    let current: Bool
    let expiresAt: String?

    var lastSeen: Date? { APIDate.parse(updatedAt) }

    /// sf symbol standing in for the web's platform icons.
    var icon: String {
        if deviceOS == "Android" { return "candybarphone" }
        if deviceOS == "iOS" || deviceOS == "macOS" { return "apple.logo" }
        if deviceOS.contains("Safari") { return "safari" }
        if deviceOS.contains("Windows") { return "pc" }
        if deviceOS == "Linux" || deviceOS == "Ubuntu" { return "terminal" }
        if deviceOS == "Chrome OS"
            || deviceType == "Chrome"
            || deviceType == "Chromium"
            || deviceType == "Mobile Chrome" {
            return "globe"
        }
        if deviceOS == "Google Cast" { return "tv" }
        return "questionmark.circle"
    }

    var title: String {
        guard !deviceType.isEmpty || !deviceOS.isEmpty else { return String(localized: "Unknown") }
        var text = "\(deviceOS.isEmpty ? String(localized: "Unknown") : deviceOS) • \(deviceType.isEmpty ? String(localized: "Unknown") : deviceType)"
        if let appVersion, !appVersion.isEmpty { text += " (v\(appVersion))" }
        return text
    }
}

nonisolated struct AssetStatistics: Decodable, Sendable {
    let images: Int
    let videos: Int
    let total: Int
}

/// daily activity over a date range, GET /admin/users/{id}/calendar-heatmap.
nonisolated struct CalendarHeatmap: Decodable, Sendable {
    struct Day: Decodable, Identifiable {
        let date: String
        let count: Int
        var id: String { date }
    }

    let from: String
    let to: String
    let series: [Day]
    let totalCount: Int
}

/// the web's heatmap window: 52 weeks ending today, opened on a sunday so
/// the grid starts on a full column.
nonisolated enum HeatmapRange {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func current(now: Date = Date()) -> (from: String, to: String) {
        let calendar = utcCalendar
        let to = calendar.startOfDay(for: now)
        let back = calendar.date(byAdding: .weekOfYear, value: -51, to: to) ?? to
        let from = calendar.date(byAdding: .day, value: 1, to: back) ?? back
        let weekday = calendar.component(.weekday, from: from)
        let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: from) ?? from
        return (dayFormatter.string(from: sunday), dayFormatter.string(from: to))
    }

    /// series dates come back either date-only or as full timestamps.
    static func parse(_ raw: String) -> Date? {
        dayFormatter.date(from: String(raw.prefix(10))) ?? APIDate.parse(raw)
    }
}

// MARK: - byte units

/// the web's byte-units helpers: binary units with a short label.
nonisolated enum BinaryByteFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    /// number and unit apart, for layouts that style them differently.
    static func components(_ bytes: Int64, maxFractionDigits: Int = 1) -> (value: String, unit: String) {
        let value = max(0, Double(bytes))
        let magnitude = value < 1 ? 0 : min(units.count - 1, Int(log(value) / log(1024)))
        let scaled = value / pow(1024, Double(magnitude))
        let number = scaled.formatted(.number.precision(.fractionLength(0...maxFractionDigits)))
        return (number, units[magnitude])
    }

    static func string(_ bytes: Int64, maxFractionDigits: Int = 1) -> String {
        let parts = components(bytes, maxFractionDigits: maxFractionDigits)
        return "\(parts.value) \(parts.unit)"
    }

    static func gibibytes(from bytes: Int64) -> Double {
        Double(bytes) / pow(1024, 3)
    }

    static func bytes(fromGibibytes value: Double) -> Int64 {
        Int64((value * pow(1024, 3)).rounded())
    }
}

// MARK: - queues

nonisolated struct QueueStatistics: Decodable, Hashable, Sendable {
    let active: Int
    let completed: Int
    let delayed: Int
    let failed: Int
    let paused: Int
    let waiting: Int

    /// what the queue card counts as waiting.
    var waitingTotal: Int { waiting + paused + delayed }
}

/// one server job queue, GET /queues. the name is kept raw so a queue this
/// build does not know still decodes and can be paused or resumed.
nonisolated struct Queue: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let isPaused: Bool
    let statistics: QueueStatistics

    var id: String { name }
    var kind: QueueKind? { QueueKind(rawValue: name) }
    var isIdle: Bool { statistics.active + statistics.waiting == 0 && !isPaused }
    var title: String { kind?.title ?? name }
}

/// GET /jobs on servers without the queues api.
nonisolated struct LegacyQueue: Decodable, Sendable {
    struct Status: Decodable { let isPaused: Bool }
    let jobCounts: QueueStatistics
    let queueStatus: Status
}

nonisolated enum QueueCommand: String, Sendable {
    case start
    case pause
    case resume
    case empty
    case clearFailed = "clear-failed"

    var title: String {
        switch self {
        case .start: String(localized: "Start")
        case .pause: String(localized: "Pause")
        case .resume: String(localized: "Resume")
        case .empty: String(localized: "Clear")
        case .clearFailed: String(localized: "Clear Failed Jobs")
        }
    }
}

/// the queues the web panel knows, with their card texts.
nonisolated enum QueueKind: String, CaseIterable, Sendable {
    case thumbnailGeneration
    case metadataExtraction
    case videoConversion
    case faceDetection
    case facialRecognition
    case smartSearch
    case duplicateDetection
    case backgroundTask
    case storageTemplateMigration
    case migration
    case search
    case sidecar
    case library
    case notifications
    case backupDatabase
    case ocr
    case workflow
    case integrityCheck
    case editor
    case qualityAnalysis
    case spatialScene
    case petDetection
    case petRecognition
    case classification
    case peopleBackfill
    case storageBackendMigration

    /// the buttons an idle card offers. all and refresh are optional, the
    /// missing button always exists.
    struct Buttons {
        var all: String?
        var refresh: String?
        var missing: String
    }

    /// card order of the web panel, gallery's queues included; a card shows
    /// only when the server lists its queue. queues outside it only show in
    /// the paused-queues action.
    static let panelOrder: [QueueKind] = [
        .thumbnailGeneration, .metadataExtraction, .library, .sidecar, .smartSearch,
        .duplicateDetection, .faceDetection, .facialRecognition, .peopleBackfill, .ocr,
        .petDetection, .petRecognition, .classification, .qualityAnalysis, .spatialScene,
        .videoConversion, .storageTemplateMigration, .migration, .storageBackendMigration,
    ]

    var title: String {
        switch self {
        case .thumbnailGeneration: String(localized: "Generate Thumbnails")
        case .metadataExtraction: String(localized: "Extract Metadata")
        case .videoConversion: String(localized: "Transcode Videos")
        case .faceDetection: String(localized: "Face Detection")
        case .facialRecognition: String(localized: "Facial Recognition")
        case .smartSearch: String(localized: "Smart Search")
        case .duplicateDetection: String(localized: "Duplicate Detection")
        case .backgroundTask: String(localized: "Background Tasks")
        case .storageTemplateMigration: String(localized: "Storage Template Migration")
        case .migration: String(localized: "Migration")
        case .search: String(localized: "Search")
        case .sidecar: String(localized: "Sidecar Metadata")
        case .library: String(localized: "External Libraries")
        case .notifications: String(localized: "Notifications")
        case .backupDatabase: String(localized: "Backup Database")
        case .ocr: String(localized: "Optical Character Recognition")
        case .workflow: String(localized: "Workflows")
        case .integrityCheck: String(localized: "Integrity Checks")
        case .editor: String(localized: "Editor")
        case .qualityAnalysis: String(localized: "Quality Analysis")
        case .spatialScene: String(localized: "Spatial Scene")
        case .petDetection: String(localized: "Pet Detection")
        case .petRecognition: String(localized: "Pet Recognition")
        case .classification: String(localized: "Auto-Classification")
        case .peopleBackfill: String(localized: "People Identity Maintenance")
        case .storageBackendMigration: String(localized: "Storage Backend Migration")
        }
    }

    var subtitle: String? {
        switch self {
        case .thumbnailGeneration:
            String(localized: "Generate large, small and blurred thumbnails for each asset, as well as thumbnails for each person.")
        case .metadataExtraction:
            String(localized: "Extract metadata information from each asset, such as GPS, faces and resolution.")
        case .videoConversion:
            String(localized: "Transcode videos for wider compatibility with browsers and devices.")
        case .faceDetection:
            String(localized: "Detect the faces in assets using machine learning. For videos, only the thumbnail is considered. Refresh reprocesses all assets. Reset additionally clears all current face data. Missing queues assets that haven't been processed yet. Detected faces will be queued for Facial Recognition once Face Detection is complete, grouping them into existing or new people.")
        case .facialRecognition:
            String(localized: "Group detected faces into people. This step runs after Face Detection is complete. Reset reclusters all faces. Missing queues faces that don't have a person assigned.")
        case .smartSearch:
            String(localized: "Run machine learning on assets to support smart search.")
        case .duplicateDetection:
            String(localized: "Run machine learning on assets to detect similar images.")
        case .storageTemplateMigration:
            String(localized: "Apply the current storage template to previously uploaded assets.")
        case .migration:
            String(localized: "Migrate thumbnails for assets and faces to the latest folder structure.")
        case .sidecar:
            String(localized: "Discover or synchronize sidecar metadata from the filesystem.")
        case .library:
            String(localized: "Scan external libraries for new and changed assets.")
        case .ocr:
            String(localized: "Recognize text in images with machine learning so it can be searched.")
        case .qualityAnalysis:
            String(localized: "Score photos for sharpness and exposure, and detect screenshots, for Library Cleanup.")
        case .spatialScene:
            String(localized: "Compute a depth map for each photo, used by Spatial Scene.")
        case .petDetection:
            String(localized: "Detect cats and dogs in photos.")
        case .petRecognition:
            String(localized: "Recognize and group individual pets across photos.")
        case .classification:
            String(localized: "Automatically classify and tag photos.")
        case .peopleBackfill:
            String(localized: "Repair and recalculate the links between people, their identities and shared spaces. This normally runs on its own and is safe to rerun.")
        case .backgroundTask, .search, .notifications, .backupDatabase, .workflow, .integrityCheck, .editor,
             .storageBackendMigration:
            nil
        }
    }

    var icon: String {
        switch self {
        case .thumbnailGeneration: "photo.on.rectangle"
        case .metadataExtraction: "tablecells"
        case .videoConversion: "video"
        case .faceDetection: "faceid"
        case .facialRecognition: "person.2.crop.square.stack"
        case .smartSearch: "sparkle.magnifyingglass"
        case .duplicateDetection: "doc.on.doc"
        case .backgroundTask: "tray.full"
        case .storageTemplateMigration: "folder.badge.gearshape"
        case .migration: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .sidecar: "doc.text"
        case .library: "books.vertical"
        case .notifications: "bell"
        case .backupDatabase: "externaldrive.badge.timemachine"
        case .ocr: "text.viewfinder"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .integrityCheck: "checkmark.seal"
        case .editor: "pencil"
        case .qualityAnalysis: "camera.aperture"
        case .spatialScene: "cube.transparent"
        case .petDetection: "pawprint"
        case .petRecognition: "pawprint.circle"
        case .classification: "tag"
        case .peopleBackfill: "person.2.badge.gearshape"
        case .storageBackendMigration: "externaldrive.badge.icloud"
        }
    }

    var buttons: Buttons? {
        switch self {
        case .thumbnailGeneration, .metadataExtraction, .smartSearch, .duplicateDetection, .ocr, .videoConversion,
             .classification, .qualityAnalysis, .spatialScene:
            Buttons(all: String(localized: "All"), missing: String(localized: "Missing"))
        case .petDetection, .petRecognition:
            Buttons(all: String(localized: "Reset"), missing: String(localized: "Missing"))
        case .library:
            Buttons(missing: String(localized: "Rescan"))
        case .sidecar:
            Buttons(all: String(localized: "Sync"), missing: String(localized: "Discover"))
        case .faceDetection:
            Buttons(all: String(localized: "Reset"), refresh: String(localized: "Refresh"), missing: String(localized: "Missing"))
        case .facialRecognition:
            Buttons(all: String(localized: "Reset"), missing: String(localized: "Missing"))
        case .storageTemplateMigration, .migration, .peopleBackfill:
            Buttons(missing: String(localized: "Start"))
        default:
            nil
        }
    }

    /// queues whose feature is switched off on the server show a disabled
    /// card, exactly like the web panel.
    func isDisabled(features: ServerFeatures?) -> Bool {
        switch self {
        case .sidecar: features?.sidecar == false
        case .smartSearch: features?.smartSearch == false
        case .duplicateDetection: features?.duplicateDetection == false
        case .faceDetection, .facialRecognition: features?.facialRecognition == false
        case .ocr: features?.ocr == false
        default: false
        }
    }

    /// forcing these clears every named person, so the web asks first.
    var confirmsForcedStart: Bool {
        self == .faceDetection || self == .facialRecognition
    }
}

/// jobs the create-job dialog can queue, POST /jobs.
nonisolated enum ManualJob: String, CaseIterable, Identifiable, Sendable {
    case personCleanup = "person-cleanup"
    case tagCleanup = "tag-cleanup"
    case userCleanup = "user-cleanup"
    case memoryCleanup = "memory-cleanup"
    case memoryCreate = "memory-create"
    case backupDatabase = "backup-database"
    case integrityMissingFiles = "integrity-missing-files"
    case integrityUntrackedFiles = "integrity-untracked-files"
    case integrityChecksumMismatch = "integrity-checksum-mismatch"
    case integrityMissingFilesRefresh = "integrity-missing-files-refresh"
    case integrityUntrackedFilesRefresh = "integrity-untracked-files-refresh"
    case integrityChecksumMismatchRefresh = "integrity-checksum-mismatch-refresh"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personCleanup: String(localized: "Person Cleanup")
        case .tagCleanup: String(localized: "Tag Cleanup")
        case .userCleanup: String(localized: "User Cleanup")
        case .memoryCleanup: String(localized: "Memory Cleanup")
        case .memoryCreate: String(localized: "Memory Generation")
        case .backupDatabase: String(localized: "Backup Database")
        case .integrityMissingFiles: String(localized: "Missing Files")
        case .integrityUntrackedFiles: String(localized: "Untracked Files")
        case .integrityChecksumMismatch: String(localized: "Checksum Mismatch")
        case .integrityMissingFilesRefresh: String(localized: "Missing Files (Refresh)")
        case .integrityUntrackedFilesRefresh: String(localized: "Untracked Files (Refresh)")
        case .integrityChecksumMismatchRefresh: String(localized: "Checksum Mismatch (Refresh)")
        }
    }

    var group: String {
        switch self {
        case .personCleanup, .tagCleanup, .userCleanup, .memoryCleanup, .memoryCreate: String(localized: "Cleanup")
        case .backupDatabase: String(localized: "Database")
        default: String(localized: "Integrity Checks")
        }
    }

    static let groups: [String] = [String(localized: "Cleanup"), String(localized: "Database"), String(localized: "Integrity Checks")]
}
