import Foundation

/// Presentation only. This never changes pairing, verification or upload eligibility.
nonisolated struct PhotosVisualPreferences: Codable, Equatable {
    var showsAllBackupStatuses = false
}

@MainActor
final class PhotosVisualPreferencesStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load(account: String?) -> PhotosVisualPreferences {
        guard let account, let data = defaults.data(forKey: "imora.photos.presentation.v1.\(account)"),
              let value = try? JSONDecoder().decode(PhotosVisualPreferences.self, from: data)
        else { return PhotosVisualPreferences() }
        return value
    }
    func save(_ value: PhotosVisualPreferences, account: String?) {
        guard let account, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "imora.photos.presentation.v1.\(account)")
    }
}
