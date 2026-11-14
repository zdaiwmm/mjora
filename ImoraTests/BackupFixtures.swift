import Foundation
@testable import Imora

func fixtureDevice(id: String = "fixture-local", live: Bool = false, video: Bool = false, modified: Date? = Date(timeIntervalSince1970: 100)) -> DeviceAsset {
    DeviceAsset(localIdentifier: id, isVideo: video, isLivePhoto: live, isScreenshot: false,
                creationDate: Date(timeIntervalSince1970: 50), modificationDate: modified,
                isFavorite: false, durationMs: video || live ? 2000 : 0, pixelWidth: 4, pixelHeight: 3)
}

actor FixtureBackupRemote: BackupRemoteAPI {
    var assets: [String: BackupRemoteAsset]
    var onRead: (@Sendable () -> Void)?

    init(_ assets: [BackupRemoteAsset], onRead: (@Sendable () -> Void)? = nil) {
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        self.onRead = onRead
    }

    func repairLivePhoto(stillID: String, videoID: String) async throws {
        throw BackupVerificationError.component(stillID, .pairPending)
    }

    func backupAssetDetail(id: String) async throws -> BackupRemoteAsset {
        onRead?()
        guard let asset = assets[id] else { throw ImoraError.http(404, "fixture missing") }
        return asset
    }
}

func fixtureRemote(_ id: String = "still", checksum: String = "still-sha1", type: String = "IMAGE", link: String? = nil) -> BackupRemoteAsset {
    BackupRemoteAsset(id: id, ownerId: "owner", type: type, checksum: checksum,
                      isTrashed: false, isOffline: false, livePhotoVideoId: link)
}
