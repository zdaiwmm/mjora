import Foundation

nonisolated enum PhotosLibrarySource: String, CaseIterable {
    case all, cloud, local

    // A new preference makes the combined library the default for existing installs too.
    static let preferenceKey = "imora.photos.resourceFilter"

    var title: String {
        switch self {
        case .all: String(localized: "All Sources")
        case .cloud: String(localized: "Cloud")
        case .local: String(localized: "On Device")
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .cloud: "icloud"
        case .local: "iphone"
        }
    }

    var launchSource: String {
        switch self {
        case .all: "mixed"
        case .cloud: "cloud"
        case .local: "device"
        }
    }
}
