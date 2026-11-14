import Foundation

/// a projected device asset has a synthetic timeline ID, even after backup.
/// only a verified pairing may be used with the server thumbnail endpoint.
nonisolated struct AssetThumbnailSource {
    let localIdentifier: String?
    let remoteIdentifier: String?
    let preferredLocalIdentifier: String?

    static func localCacheScope(accountKey: String?, version: String?, pixels: CGFloat) -> String {
        "\(accountKey ?? "device")|\(version ?? "")|fit-cover|\(Int(pixels.rounded(.up)))"
    }

    init(
        assetID: String,
        localIdentifier: String?,
        pairedLocalIdentifier: String?,
        pairedRemoteIdentifier: String?,
        unavailableLocalIdentifier: String?
    ) {
        self.localIdentifier = localIdentifier ?? pairedLocalIdentifier
        remoteIdentifier = localIdentifier == nil ? assetID : pairedRemoteIdentifier
        // a local-only tile has no alternate source. keep its image view alive
        // so its preview remains visible and a later recovery can retry it.
        preferredLocalIdentifier = remoteIdentifier != nil
            && unavailableLocalIdentifier == self.localIdentifier
            ? nil : self.localIdentifier
    }
}
