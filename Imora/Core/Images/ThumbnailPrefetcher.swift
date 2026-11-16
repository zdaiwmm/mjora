import Foundation
import Photos

/// keeps a rolling window of grid thumbnails warm around what is on screen, so
/// a fling lands on decoded tiles instead of placeholders. each grid owns one,
/// and dropping it cancels only that grid's prefetches.
///
/// server tiles go through the nuke pipeline and device tiles through
/// photokit's caching manager, but both take the same window.
@MainActor
final class ThumbnailPrefetcher {
    /// where one warmed asset's tile comes from.
    private enum Source: Hashable {
        case remote(URL)
        /// Device-only: warm only the locally available derivative.
        case local(String, String)
        /// device copy of a server asset: rendered from the library when it
        /// has it, never downloaded for a tile the server can serve. kept
        /// apart because the caching manager only serves matching options.
        case paired(String, String)
    }

    private struct Warmed: Hashable {
        let source: Source
        /// decoded into memory rather than only fetched to disk.
        let isDecoded: Bool
    }

    private var targetPixelSize: CGFloat
    private let localContentMode: PHImageContentMode
    /// the caching manager only serves requests whose target matches, so
    /// this has to agree with what the tiles ask for.
    private let localCoversTarget: Bool
    /// the asset range last warmed, with the `flatAssets` revision it was taken
    /// from. a fling reports visible rows far more often than the window it
    /// implies actually moves.
    private var window: Range<Int>?
    private var windowVersion = -1
    private var decodedRange: Range<Int>?
    /// one entry per asset of `window`, in order. while the revision holds, a
    /// moving window diffs by index arithmetic: only the assets entering or
    /// leaving it are looked at, never a url per asset of the whole window.
    private var warmed: [Warmed] = []
    private let ownerID = UUID()
    private weak var windowClient: ImoraClient?
    private var rowAssetCounts: [String: Int] = [:]
    private var rowCountsVersion = -1

    init(
        targetPixelSize: CGFloat = 640,
        localContentMode: PHImageContentMode = .aspectFill,
        localCoversTarget: Bool = false
    ) {
        self.targetPixelSize = targetPixelSize
        self.localContentMode = localContentMode
        self.localCoversTarget = localCoversTarget
    }

    /// anchors on both ends of the visible tile rows and warms the assets
    /// around them, the long side of the window facing the way the grid is
    /// going: 1 towards the bottom, -1 towards the top, 0 at rest.
    func update(
        visibleRowIDs: [String],
        model: TimelineModel,
        client: ImoraClient?,
        backup: BackupManager?,
        targetPixelSize: CGFloat? = nil,
        direction: Int = 0
    ) {
        if let targetPixelSize {
            updateTargetPixelSize(targetPixelSize)
        }
        // both ends anchor the window, so the look-ahead starts past the
        // fold rather than a screen short of it.
        guard let client,
              let firstID = visibleRowIDs.lazy.compactMap({ model.firstAssetIDByRowID[$0] }).first,
              let lastID = visibleRowIDs.reversed().lazy.compactMap({ model.firstAssetIDByRowID[$0] }).first,
              let first = model.flatAssetIndex(for: firstID),
              let last = model.flatAssetIndex(for: lastID)
        else { return cancel() }

        let assets = model.flatAssets
        let low = min(first, last)
        let high = max(first, last)
        if windowClient !== client {
            cancel()
            windowClient = client
        }
        if rowCountsVersion != model.flatAssetsVersion {
            rowAssetCounts = Dictionary(uniqueKeysWithValues: model.rows.compactMap { row in
                guard case .tiles(let id, let runs) = row else { return nil }
                return (id, runs.reduce(0) { $0 + $1.assets.count })
            })
            rowCountsVersion = model.flatAssetsVersion
        }
        let lastRowID = visibleRowIDs.reversed().first { model.firstAssetIDByRowID[$0] != nil }
        let visibleEnd = min(assets.count, high + (lastRowID.flatMap { rowAssetCounts[$0] } ?? 1))
        let next = ThumbnailLoadState.prefetchWindow(visible: low..<visibleEnd, count: assets.count)
        guard !next.isEmpty else { return cancel() }
        let nextDecoded = next

        let version = model.flatAssetsVersion
        guard next != window || version != windowVersion || nextDecoded != decodedRange else { return }
        let reusable = version == windowVersion ? window : nil

        var entries: [Warmed] = []
        entries.reserveCapacity(next.count)
        for index in next {
            let source: Source
            if let reusable, reusable.contains(index) {
                source = warmed[index - reusable.lowerBound].source
            } else {
                source = Self.source(of: assets[index], client: client, backup: backup, pixels: self.targetPixelSize)
            }
            // photokit has one caching lane, so only server tiles split.
            let isDecoded: Bool
            if case .remote = source {
                isDecoded = nextDecoded.contains(index)
            } else {
                isDecoded = true
            }
            entries.append(Warmed(source: source, isDecoded: isDecoded))
        }

        var start: [Warmed] = []
        var stop: [Warmed] = []
        if let reusable {
            for index in reusable where !next.contains(index) {
                stop.append(warmed[index - reusable.lowerBound])
            }
            for index in next {
                let entry = entries[index - next.lowerBound]
                guard reusable.contains(index) else {
                    start.append(entry)
                    continue
                }
                let previous = warmed[index - reusable.lowerBound]
                if previous != entry {
                    stop.append(previous)
                    start.append(entry)
                }
            }
        } else {
            // the assets moved under the window, so indices no longer line
            // up; this is the rare path, once per rows rebuild.
            (start, stop) = Self.difference(from: warmed, to: entries)
        }

        window = next
        windowVersion = version
        decodedRange = nextDecoded
        warmed = entries
        send(start: start, stop: stop)
    }

    /// warms an explicit window, for hosts that already know theirs: the
    /// viewer pages a flat list and picks its own thumbnail size.
    func warm(remote: Set<URL>, local: Set<String>) {
        let entries = remote.map { Warmed(source: .remote($0), isDecoded: true) }
            + local.map { Warmed(source: .local($0, ""), isDecoded: true) }
        let (start, stop) = Self.difference(from: warmed, to: entries)
        window = nil
        windowVersion = -1
        decodedRange = nil
        warmed = entries
        send(start: start, stop: stop)
    }

    func cancel() {
        let stop = warmed
        window = nil
        windowVersion = -1
        decodedRange = nil
        warmed = []
        send(start: [], stop: stop)
        ImageLoader.shared.releasePrefetchOwner(ownerID)
    }

    private func updateTargetPixelSize(_ value: CGFloat) {
        let value = max(1, value.rounded(.up))
        guard value != targetPixelSize else { return }
        cancel()
        targetPixelSize = value
    }

    /// tiles render the device copy when one is paired, so warm the same
    /// source, with the same options, the tile will ask for.
    private static func source(of asset: Asset, client: ImoraClient, backup: BackupManager?, pixels: CGFloat) -> Source {
        let scope = AssetThumbnailSource.prefetchScope(accountKey: client.offlineAccountKey,
            version: asset.localImageVersion ?? asset.thumbhash, pixels: pixels)
        if let localIdentifier = asset.localIdentifier {
            return .local(localIdentifier, scope)
        }
        if let localIdentifier = backup?.localIdentifierByRemoteId[asset.id] {
            return .paired(localIdentifier, scope)
        }
        return .remote(client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash))
    }

    private static func difference(from old: [Warmed], to new: [Warmed]) -> (start: [Warmed], stop: [Warmed]) {
        let oldSet = Set(old)
        let newSet = Set(new)
        return (Array(newSet.subtracting(oldSet)), Array(oldSet.subtracting(newSet)))
    }

    private func send(start: [Warmed], stop: [Warmed]) {
        guard !start.isEmpty || !stop.isEmpty else { return }
        var decoded: (start: [URL], stop: [URL]) = ([], [])
        var data: (start: [URL], stop: [URL]) = ([], [])
        var local: (start: [String: String], stop: [String: String]) = ([:], [:])
        var paired: (start: [String: String], stop: [String: String]) = ([:], [:])
        for (entries, isStart) in [(stop, false), (start, true)] {
            for entry in entries {
                switch entry.source {
                case .remote(let url):
                    if entry.isDecoded {
                        isStart ? decoded.start.append(url) : decoded.stop.append(url)
                    } else {
                        isStart ? data.start.append(url) : data.stop.append(url)
                    }
                case .local(let identifier, let scope):
                    if isStart { local.start[identifier] = scope } else { local.stop[identifier] = scope }
                case .paired(let identifier, let scope):
                    if isStart { paired.start[identifier] = scope } else { paired.stop[identifier] = scope }
                }
            }
        }
        if !decoded.stop.isEmpty {
            ImageLoader.shared.stopPrefetching(urls: decoded.stop, targetPixelSize: targetPixelSize, ownerID: ownerID)
        }
        if !data.stop.isEmpty {
            ImageLoader.shared.stopPrefetchingData(urls: data.stop, ownerID: ownerID)
        }
        if !decoded.start.isEmpty {
            ImageLoader.shared.startPrefetching(urls: decoded.start, targetPixelSize: targetPixelSize, ownerID: ownerID)
        }
        if !data.start.isEmpty {
            ImageLoader.shared.startPrefetchingData(urls: data.start, ownerID: ownerID)
        }
        syncLocal(start: local.start, stop: local.stop, allowsNetwork: false)
        syncLocal(start: paired.start, stop: paired.stop, allowsNetwork: false)
    }

    private func syncLocal(start: [String: String], stop: [String: String], allowsNetwork: Bool) {
        if !stop.isEmpty {
            LocalImageLoader.shared.stopCaching(
                localIdentifiers: Array(stop.keys),
                targetPixelSize: targetPixelSize,
                contentMode: localContentMode,
                coversTarget: localCoversTarget,
                allowsNetwork: allowsNetwork,
                cacheScopes: stop, ownerID: ownerID
            )
        }
        if !start.isEmpty {
            LocalImageLoader.shared.startCaching(
                localIdentifiers: Array(start.keys),
                targetPixelSize: targetPixelSize,
                contentMode: localContentMode,
                coversTarget: localCoversTarget,
                allowsNetwork: allowsNetwork,
                cacheScopes: start, ownerID: ownerID
            )
        }
    }
}
