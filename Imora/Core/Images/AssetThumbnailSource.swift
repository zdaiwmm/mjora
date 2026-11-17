import Foundation
import Synchronization

/// a projected device asset has a synthetic timeline ID, even after backup.
/// only a verified pairing may be used with the server thumbnail endpoint.
nonisolated struct AssetThumbnailSource {
    let localIdentifier: String?
    let remoteIdentifier: String?
    let preferredLocalIdentifier: String?

    private struct AccountNamespaces {
        var revision: UInt64 = .max
        var values: [String: String] = [:]
    }
    private static let accountNamespaces = Mutex(AccountNamespaces())

    static func localCacheScope(accountKey: String?, version: String?, pixels: CGFloat) -> String {
        let namespace = accountKey.map(accountNamespace) ?? "device"
        return "\(namespace)|\(version ?? "")|fit-cover|\(Int(pixels.rounded(.up)))"
    }

    private static func accountNamespace(_ credential: String) -> String {
        let revision = SessionCache.mediaScopeRevision
        return accountNamespaces.withLock { cache in
            if cache.revision != revision {
                cache.values.removeAll(keepingCapacity: true)
                cache.revision = revision
            }
            if let value = cache.values[credential] { return value }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let verified = SessionCache.verifiedMediaScope(credential: credential)
            let value = verified.flatMap { try? encoder.encode($0) }.map(MediaDisplayKeyV1.digest) ?? credential
            if cache.values.count >= 64 { cache.values.removeAll(keepingCapacity: true) }
            cache.values[credential] = value
            return value
        }
    }

    /// Namespace passed by the prefetch adapter to LocalImageLoader.
    static func prefetchScope(accountKey: String?, version: String?, pixels: CGFloat) -> String {
        localCacheScope(accountKey: accountKey, version: version, pixels: pixels)
    }

    init(
        assetID: String,
        localIdentifier: String?,
        pairedLocalIdentifier: String?,
        pairedRemoteIdentifier: String?,
        unavailableLocalIdentifier: String?,
        isEdited: Bool = false
    ) {
        // A remote edit's current render is not the paired device original.
        // A device-owned asset still uses its own current PhotoKit rendering.
        self.localIdentifier = localIdentifier ?? (isEdited ? nil : pairedLocalIdentifier)
        remoteIdentifier = localIdentifier == nil ? assetID : pairedRemoteIdentifier
        // a local-only tile has no alternate source. keep its image view alive
        // so its preview remains visible and a later recovery can retry it.
        preferredLocalIdentifier = remoteIdentifier != nil
            && unavailableLocalIdentifier == self.localIdentifier
            ? nil : self.localIdentifier
    }
}
