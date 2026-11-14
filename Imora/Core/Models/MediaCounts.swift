import Foundation

/// Counts logical library assets; a Live Photo and its motion resource are one photo.
nonisolated struct MediaCounts: Equatable, Sendable {
    var photos = 0
    var videos = 0
    var total: Int { photos + videos }

    init(photos: Int = 0, videos: Int = 0) {
        self.photos = photos
        self.videos = videos
    }

    var text: String {
        switch (photos, videos) {
        case (0, 0): String(localized: "0 items")
        case (_, 0): photoText
        case (0, _): videoText
        default: String(localized: "\(photoText) and \(videoText)")
        }
    }

    private var photoText: String { String(localized: "\(photos) photos") }
    private var videoText: String { String(localized: "\(videos) videos") }

    func progressText(of total: Self) -> String {
        let photoPart = String(localized: "Photos: \(photos) of \(total.photos)")
        let videoPart = String(localized: "Videos: \(videos) of \(total.videos)")
        return switch (total.photos, total.videos) {
        case (0, 0): String(localized: "0 of 0 items")
        case (_, 0): photoPart
        case (0, _): videoPart
        default: String(localized: "\(photoPart) and \(videoPart)")
        }
    }
}
