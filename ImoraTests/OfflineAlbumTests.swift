import AVFoundation
import Foundation
import Synchronization
import UIKit
import XCTest
@testable import Imora

@MainActor
final class OfflineAlbumTests: XCTestCase {
    private func asset(_ id: String = "still", motion: String? = nil, video: Bool = false, revision: String = "v1") -> Asset {
        Asset(id: id, ownerId: "fixture", isImage: !video, isFavorite: false, isTrashed: false, visibility: .timeline,
              thumbhash: revision, fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), localOffsetHours: 0,
              duration: video ? 2_000 : nil, livePhotoVideoId: motion, ratio: 1, city: nil, country: nil)
    }

    private func album(_ id: String = "album") throws -> Album {
        try JSONDecoder().decode(Album.self, from: Self.albumData(id))
    }

    private nonisolated static func albumData(_ id: String = "album") -> Data {
        Data("""
        {"id":"\(id)","albumName":"Offline fixture","description":"Synthetic media only","albumThumbnailAssetId":"still",
        "assetCount":3,"albumUsers":[],"shared":false,"hasSharedLink":false,"createdAt":"2026-01-01","updatedAt":"2026-01-01","order":"desc"}
        """.utf8)
    }

    private func component(_ asset: Asset, scope: StableMediaScope, kind: OfflineAlbum.Component.Kind = .image) throws -> OfflineAlbum.Component {
        try MediaContentGenerations.shared.ensureInitialized()
        return .init(kind: kind, asset: asset,
            generation: try XCTUnwrap(MediaContentGenerations.shared.current(scope: scope, subject: .remoteAsset(asset.id))))
    }

    private func png() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
    }

    private func install(_ bytes: Data, component: OfflineAlbum.Component, store: OfflineAlbumStore,
                         scope: StableMediaScope, context: AccountRequestContext, index: Int = 0) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: temporary); defer { try? FileManager.default.removeItem(at: temporary) }
        try await store.install(temporary: temporary, mime: component.kind == .video ? "video/quicktime" : "image/png",
            expectedBytes: Int64(bytes.count), scope: scope, albumID: "album", itemID: "still", componentIndex: index, context: context)
    }

    func testDurablePhotoSurvivesNewStoreAndCacheClearButCannotCrossAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
        let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
        let store = OfflineAlbumStore(root: root), part = try component(asset(), scope: scope)
        try await store.prepare(album: album(), items: [.init(asset: part.asset, components: [part])], scope: scope)
        let bytes = try png()
        try await install(bytes, component: part, store: store, scope: scope, context: context)
        try await store.setState(.ready, scope: scope, id: "album")
        let restarted = OfflineAlbumStore(root: root)
        let records = try await restarted.albums(scope: scope)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .ready)
        let url = URL(string: "https://offline.invalid/api/assets/still/thumbnail?size=preview&edited=true&c=v1")!
        let storedFile = try await restarted.media(scope: scope, url: url)
        let file = try XCTUnwrap(storedFile)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        ControlledMediaStore.clearCache()
        XCTAssertTrue(file.isCurrent())
        let other = StableMediaScope.verified(server: scope.serverIdentity, accountID: UUID().uuidString)
        let otherFile = try await restarted.media(scope: other, url: url)
        XCTAssertNil(otherFile)
        let changedRevision = try await restarted.media(scope: scope, url: URL(string: url.absoluteString.replacingOccurrences(of: "c=v1", with: "c=v2"))!)
        XCTAssertNil(changedRevision)
        let original = try await restarted.media(scope: scope, url: URL(string: "https://offline.invalid/api/assets/still/original?edited=false")!)
        XCTAssertNil(original, "An edited offline display must never stand in for editor/backup original bytes")
    }

    func testIncompleteLivePhotoIsNotReadyAndMissingFileCanBeDownloadedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
        let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
        let store = OfflineAlbumStore(root: root), still = asset(motion: "motion")
        let parts = [try component(still, scope: scope), try component(asset("motion", video: true), scope: scope, kind: .video)]
        let items = [OfflineAlbum.Item(asset: still, components: parts)]
        try await store.prepare(album: album(), items: items, scope: scope)
        try await install(png(), component: parts[0], store: store, scope: scope, context: context)
        var loaded = try await store.album(scope: scope, id: "album")
        var saved = try XCTUnwrap(loaded)
        let availableAssets = await store.availableAssets(saved, scope: scope)
        XCTAssertTrue(availableAssets.isEmpty)
        do { try await store.setState(.ready, scope: scope, id: "album"); XCTFail("A missing motion component was marked ready") } catch {}
        let storedFile = try await store.media(scope: scope,
            url: URL(string: "https://offline.invalid/api/assets/still/thumbnail?edited=true&c=v1")!)
        let file = try XCTUnwrap(storedFile)
        try FileManager.default.removeItem(at: file.url)
        try await store.prepare(album: album(), items: items, scope: scope)
        loaded = try await store.album(scope: scope, id: "album")
        saved = try XCTUnwrap(loaded)
        XCTAssertNil(saved.items[0].components[0].filename, "Resume must reset a missing file, rather than skipping it forever")
        try await install(png(), component: parts[0], store: store, scope: scope, context: context)
        let available = try await store.componentAvailable(scope: scope, albumID: "album", itemID: "still", index: 0)
        XCTAssertTrue(available)
    }

    func testPermissionRetirementRevokesAnAlreadyOpenedPlaybackLease() async throws {
        let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineAlbumStore(root: root), part = try component(asset(), scope: scope)
        let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
        try await store.prepare(album: album(), items: [.init(asset: part.asset, components: [part])], scope: scope)
        try await install(png(), component: part, store: store, scope: scope, context: context)
        let storedFile = try await store.media(scope: scope, url: URL(string: "https://offline.invalid/api/assets/still/original?edited=true")!)
        let file = try XCTUnwrap(storedFile)
        let controlled = ControlledMediaFile(url: file.url, access: .init(context: context, privateLease: nil, requiresElevation: false),
            additionalAuthorization: file.isCurrent, release: {})
        let avAsset = try controlled.makeAsset()
        XCTAssertTrue(ControlledMediaFile.isAuthorized(avAsset))
        _ = try MediaContentGenerations.shared.retire(scope: scope, subjects: [.remoteAsset("still")], blocksAccess: true)
        XCTAssertFalse(ControlledMediaFile.isAuthorized(avAsset))
        do { _ = try controlled.url; XCTFail("A revoked consumer retained its file URL") } catch {}
    }

    func testLengthMismatchAndCancelledContextCannotCommitAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
        let store = OfflineAlbumStore(root: root), part = try component(asset(), scope: scope)
        let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
        try await store.prepare(album: album(), items: [.init(asset: part.asset, components: [part])], scope: scope)
        let temporary = root.appending(path: "partial")
        try png().write(to: temporary)
        do {
            try await store.install(temporary: temporary, mime: "image/png", expectedBytes: 999_999,
                scope: scope, albumID: "album", itemID: "still", componentIndex: 0, context: context)
            XCTFail("A short response was accepted")
        } catch {}
        context.invalidate()
        do { try await install(png(), component: part, store: store, scope: scope, context: context); XCTFail("Cancelled account committed") } catch {}
        let loaded = try await store.album(scope: scope, id: "album")
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.completedCount, 0)
    }

    func testEditedMetadataInvalidatesCopiesAndUnrelatedAssetsDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
        let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
        let store = OfflineAlbumStore(root: root), part = try component(asset(), scope: scope)
        try await store.prepare(album: album(), items: [.init(asset: part.asset, components: [part])], scope: scope)
        try await install(png(), component: part, store: store, scope: scope, context: context)
        try await store.setState(.ready, scope: scope, id: "album")
        try await store.invalidate(scope: scope, ids: ["unrelated"])
        var loaded = try await store.album(scope: scope, id: "album")
        var saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.state, .ready)
        try await store.observe(asset(revision: "v2"), scope: scope)
        loaded = try await store.album(scope: scope, id: "album")
        saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.state, .needsUpdate)
        XCTAssertEqual(saved.bytes, 0)
        let availableAssets = await store.availableAssets(saved, scope: scope)
        XCTAssertTrue(availableAssets.isEmpty)
    }

    func testPrivateAndTrashedMediaAndInvalidFilesAreRejected() async throws {
        var value = asset()
        for visibility in [AssetVisibility.hidden, .locked] {
            value.visibility = visibility
            XCTAssertFalse(OfflineAlbumDownloads.canRetain(value))
        }
        value.visibility = .timeline; value.isTrashed = true
        XCTAssertFalse(OfflineAlbumDownloads.canRetain(value))
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for kind in [OfflineAlbum.Component.Kind.image, .video] {
            try Data("#EXTM3U\nhttps://untrusted.invalid/media".utf8).write(to: temporary)
            do { try await OfflineAlbumDownloads.validateMedia(at: temporary, kind: kind); XCTFail("A playlist or invalid image passed") } catch {}
        }
    }

    func testPairedMotionLeasesRequireCurrentParentForBothHiddenAndVisibleMotion() async throws {
        for visibility in [AssetVisibility.hidden, .timeline] {
            for change in ["retired", "hidden", "repaired"] {
                let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let scope = StableMediaScope.verified(server: "https://offline.invalid/api", accountID: UUID().uuidString)
                let context = AccountRequestContext(apiURL: URL(string: scope.serverIdentity)!, token: "synthetic")
                let parent = asset(motion: "motion")
                var motion = asset("motion", video: true); motion.visibility = visibility
                let still = try component(parent, scope: scope)
                var moving = try component(motion, scope: scope, kind: .video)
                moving.parentAsset = parent; moving.parentGeneration = still.generation
                let store = OfflineAlbumStore(root: root)
                try await store.prepare(album: album(), items: [.init(asset: parent, components: [still, moving])], scope: scope)
                try await install(png(), component: still, store: store, scope: scope, context: context)
                try await install(Data("owned-motion".utf8), component: moving, store: store, scope: scope, context: context, index: 1)
                let stored = try await store.media(scope: scope, url: URL(string: "https://offline.invalid/api/assets/motion/video/playback")!)
                let file = try XCTUnwrap(stored)
                let lease = ControlledMediaFile(url: file.url, access: .init(context: context, privateLease: nil, requiresElevation: false),
                    additionalAuthorization: file.isCurrent, release: {})
                let avAsset = try lease.makeAsset()
                XCTAssertTrue(ControlledMediaFile.isAuthorized(avAsset))
                if change == "retired" {
                    _ = try MediaContentGenerations.shared.retire(scope: scope, subjects: [.remoteAsset(parent.id)], blocksAccess: true)
                } else if change == "hidden" {
                    var hidden = parent; hidden.visibility = .hidden
                    try await store.observe(hidden, scope: scope)
                } else {
                    try await store.observe(asset(motion: "different-motion"), scope: scope)
                }
                XCTAssertFalse(ControlledMediaFile.isAuthorized(avAsset), "Parent \(change) failed to revoke \(visibility) motion")
            }
        }
    }

    func testAuthenticatedHiddenMotionGrantRejectsARetiredOrUnrelatedParent() async throws {
        let server = try fixtureServer(image: png(), video: Data("unused".utf8))
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        client.confirmMediaAccount(UUID().uuidString); defer { client.invalidate() }
        try MediaContentGenerations.shared.ensureInitialized()
        let read = try await client.authenticatedAsset(id: "live"), motionRead = try await client.authenticatedAsset(id: "motion")
        let parent = try XCTUnwrap(read.assets.first)
        let generation = try XCTUnwrap(MediaContentGenerations.shared.current(scope: client.mediaDisplayScope, subject: .remoteAsset(parent.id)))
        XCTAssertTrue(try motionRead.authorizeLinkedMotion(parent: parent, parentGeneration: generation, parentRead: read, using: client))
        XCTAssertFalse(try motionRead.authorizeLinkedMotion(parent: asset(motion: "motion"), parentGeneration: generation, parentRead: read, using: client))
        _ = try MediaContentGenerations.shared.retire(scope: client.mediaDisplayScope, subjects: [.remoteAsset(parent.id)], blocksAccess: true)
        XCTAssertFalse(try motionRead.authorizeLinkedMotion(parent: parent, parentGeneration: generation, parentRead: read, using: client))
        let hidden = try XCTUnwrap(motionRead.assets.first)
        XCTAssertFalse(OfflineAlbumDownloads.canRetain(hidden), "A hidden Live component cannot be an independent retained album item")
    }

    func testCorruptRetentionMetadataDoesNotBreakOrdinaryOnlineImages() async throws {
        let image = try png()
        let server = try fixtureServer(image: image)
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic")
        client.confirmMediaAccount(UUID().uuidString); defer { client.invalidate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let directory = OfflineAlbumStore.rootDirectory.appending(path: MediaDisplayKeyV1.digest(try encoder.encode(client.mediaDisplayScope)))
            .appending(path: "broken-manifest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appending(path: "manifest.json"))
        let request = try client.authorizedRequest(url: client.thumbnailURL(assetID: "still", size: "preview"))
        let received = try await client.imageData(for: request)
        XCTAssertEqual(received.0, image)
        try await OfflineAlbumStore.shared.remove(scope: client.mediaDisplayScope)
    }

    func testHeldManualLANReadsThroughRealImagePipelineAndVideoWithoutNetworkPermission() async throws {
        let moviePath = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4/services/video-media/live-motion.mov")
        guard FileManager.default.fileExists(atPath: moviePath.path) else { throw XCTSkip("Owned synthetic motion fixture unavailable") }
        let movie = try Data(contentsOf: moviePath)
        let server = try fixtureServer(image: png())
        try await server.start(); defer { server.stop() }
        let local = try LocalHTTPServer { _ in .init(status: 500) }
        try await local.start(); defer { local.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-held-lan")
        client.confirmMediaAccount(UUID().uuidString)
        let scope = client.mediaDisplayScope
        defer { client.invalidate(); ImageLoader.shared.configure(client: nil) }
        let parent = asset(motion: "motion"), still = try component(parent, scope: scope)
        var moving = try component(asset("motion", video: true), scope: scope, kind: .video)
        moving.parentAsset = parent; moving.parentGeneration = still.generation
        try await OfflineAlbumStore.shared.prepare(album: album(), items: [.init(asset: parent, components: [still, moving])], scope: scope)
        try await install(png(), component: still, store: .shared, scope: scope, context: client.context)
        try await install(movie, component: moving, store: .shared, scope: scope, context: client.context, index: 1)
        let savedConfig = UserDefaults.standard.data(forKey: "imora.localServer")
        defer {
            if let savedConfig { UserDefaults.standard.set(savedConfig, forKey: "imora.localServer") }
            else { UserDefaults.standard.removeObject(forKey: "imora.localServer") }
            ServerRoute.use(local: nil, external: nil)
        }
        let config = LocalServerConfig(server: server.apiURL, apiURL: local.apiURL)
        UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "imora.localServer")
        ServerRoute.holdManual(local: local.apiURL, external: server.apiURL, identity: nil)
        XCTAssertFalse(ServerRoute.isLocal)
        XCTAssertFalse(ServerRoute.permitsRequest(to: server.apiURL, for: server.apiURL))
        XCTAssertFalse(ServerRoute.permitsRequest(to: local.apiURL, for: server.apiURL))
        ImageLoader.shared.configure(client: client)
        ImageLoader.shared.clearCache()
        let canonicalImage = client.thumbnailURL(assetID: "still", size: "preview", cacheKey: "v1")
        let image = try await ImageLoader.shared.image(for: canonicalImage, targetPixelSize: 64)
        XCTAssertGreaterThan(image.size.width, 0)
        let localImage = ServerRoute.resolve(canonicalImage)
        let response = try await client.imageData(for: URLRequest(url: localImage))
        XCTAssertNotNil(UIImage(data: response.0))
        let playback = try await client.localMediaFile(client.playbackURL(assetID: "motion"))
        XCTAssertEqual(try Data(contentsOf: playback.url), movie)
        let frame = try await AVAssetImageGenerator(asset: playback.makeAsset()).image(at: .zero)
        XCTAssertGreaterThan(frame.image.width, 0)
        XCTAssertThrowsError(try client.authorizedRequest(url: localImage), "The offline read must not enable a network request")
        do { _ = try await client.serverStorage(); XCTFail("The held LAN sent an API request") } catch {}
        let foreign = URL(string: "https://untrusted.invalid/api/assets/still/thumbnail?edited=true&c=v1")!
        do { _ = try await client.imageData(for: URLRequest(url: foreign)); XCTFail("Foreign origin read another server's retained file") } catch {}
        do { _ = try await ImageLoader.shared.image(for: foreign, targetPixelSize: 64); XCTFail("Foreign origin entered the image cache") } catch {}
        let stale = ImoraClient(apiURL: server.apiURL, accessToken: "old-context")
        let staleURL = stale.thumbnailURL(assetID: "still", size: "preview", cacheKey: "v1")
        do { _ = try await client.imageData(for: URLRequest(url: staleURL)); XCTFail("A previous context read the current account") } catch {}
        stale.invalidate()
        XCTAssertTrue(server.received.isEmpty)
        XCTAssertTrue(local.received.isEmpty)
        try await OfflineAlbumStore.shared.remove(scope: scope)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the owned asynchronous operation")
    }

    private func fixtureServer(image: Data, video: Data = Data()) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            if request.path == "/api/albums/album" { return .init(body: Self.albumData()) }
            if request.path == "/api/server/version" { return .init(body: Data(#"{"major":3,"minor":4,"patch":1}"#.utf8)) }
            if request.path == "/api/server/features" { return .init(body: Data("{}".utf8)) }
            if request.path == "/api/search/metadata" {
                return .init(body: video.isEmpty ? Data(#"{"assets":{"items":[{"id":"still"}]}}"#.utf8)
                    : Data(#"{"assets":{"items":[{"id":"still"},{"id":"live"},{"id":"video"}]}}"#.utf8))
            }
            if request.path.contains("/original?") || request.path.contains("/thumbnail?") {
                return .init(headers: ["Content-Type": "image/png"], body: image)
            }
            if request.path.hasSuffix("/video/playback") { return .init(headers: ["Content-Type": "video/quicktime"], body: video) }
            if request.path.hasPrefix("/api/assets/") {
                let id = String(request.path.split(separator: "/").last!)
                let isVideo = id == "video" || id == "motion"
                let day = id == "video" ? 3 : id == "live" ? 2 : 1
                let pairing = id == "live" ? #", "livePhotoVideoId":"motion""# : ""
                return .init(body: Data("""
                {"id":"\(id)","ownerId":"fixture","type":"\(isVideo ? "VIDEO" : "IMAGE")","originalFileName":"\(id)",
                "fileCreatedAt":"2026-01-0\(day)T12:00:00Z","localDateTime":"2026-01-0\(day)T12:00:00Z","isFavorite":false,
                "isTrashed":false,"visibility":"\(id == "motion" ? "hidden" : "timeline")","thumbhash":"v1","width":32,"height":32\(pairing)}
                """.utf8))
            }
            return .init(status: 404)
        }
    }

    func testActualHTTPDownloadReadsPhotoVideoAndLiveAfterServerStops() async throws {
        let path = URL(fileURLWithPath: "/Users/achilles/mjora/execution/photos-phase4/services/video-media/live-motion.mov")
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Owned synthetic motion fixture unavailable") }
        let bytes = try Data(contentsOf: path), image = try png()
        let server = try fixtureServer(image: image, video: bytes)
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "offline-synthetic")
        client.confirmMediaAccount(UUID().uuidString)
        let scope = client.mediaDisplayScope
        let downloads = OfflineAlbumDownloads()
        await downloads.attach(client)
        downloads.download(try album(), client: client)
        try await waitUntil { !downloads.workingIDs.contains("album") }
        XCTAssertNil(downloads.error)
        XCTAssertEqual(downloads.albums.first?.state, .ready)
        XCTAssertEqual(downloads.albums.first?.completedCount, 3)
        let record = try XCTUnwrap(downloads.albums.first)
        let retainedOrder = await OfflineAlbumStore.shared.availableAssets(record, scope: scope)
        XCTAssertEqual(retainedOrder.map(\.id), ["video", "live", "still"], "Display order follows the album date order, not membership ID order")
        server.stop(); client.invalidate()
        let restored = ImoraClient(apiURL: server.apiURL, accessToken: "new-synthetic-session")
        restored.confirmMediaAccount(try XCTUnwrap(scope.accountID))
        defer { restored.invalidate() }
        let request = try restored.authorizedRequest(url: restored.thumbnailURL(assetID: "still", size: "preview", cacheKey: "v1"))
        let offlineImage = try await restored.imageData(for: request)
        XCTAssertEqual(offlineImage.0, image)
        for id in ["motion", "video"] {
            let retained = try await restored.retainedMediaFile(restored.playbackURL(assetID: id))
            let file = try XCTUnwrap(retained)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
            let avAsset = try file.makeAsset()
            let duration = try await avAsset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0)
            let frame = try await AVAssetImageGenerator(asset: avAsset).image(at: .zero)
            XCTAssertGreaterThan(frame.image.width, 0)
        }
        await downloads.attach(restored)
        await downloads.remove("album")
        XCTAssertTrue(downloads.albums.isEmpty)
        try await OfflineAlbumStore.shared.remove(scope: scope)
    }

    func testLateSignOutCannotClearTheNextAccountsOfflineState() async throws {
        let server = try fixtureServer(image: png())
        try await server.start(); defer { server.stop() }
        let first = ImoraClient(apiURL: server.apiURL, accessToken: "first"), second = ImoraClient(apiURL: server.apiURL, accessToken: "second")
        first.confirmMediaAccount(UUID().uuidString); second.confirmMediaAccount(UUID().uuidString)
        defer { first.invalidate(); second.invalidate() }
        let downloads = OfflineAlbumDownloads()
        await downloads.attach(first)
        var reachedRemoval = false
        var releaseRemoval: CheckedContinuation<Void, Never>?
        downloads.beforeStorageRemoval = { _ in
            reachedRemoval = true
            await withCheckedContinuation { releaseRemoval = $0 }
        }
        let signOut = Task { await downloads.signOut(first) }
        try await waitUntil { reachedRemoval }
        await downloads.attach(second)
        downloads.download(try album(), client: second)
        try await waitUntil { !downloads.workingIDs.contains("album") }
        XCTAssertEqual(downloads.albums.first?.state, .ready)
        releaseRemoval?.resume(); await signOut.value
        XCTAssertEqual(downloads.albums.first?.state, .ready, "An old account's late cleanup cleared the new account")
        downloads.beforeStorageRemoval = nil
        await downloads.remove("album")
    }

    func testRemovingAnAlbumBlocksRedownloadAcrossSameAccountClientReplacement() async throws {
        let server = try fixtureServer(image: png())
        try await server.start(); defer { server.stop() }
        let first = ImoraClient(apiURL: server.apiURL, accessToken: "first"), second = ImoraClient(apiURL: server.apiURL, accessToken: "second")
        let user = UUID().uuidString
        first.confirmMediaAccount(user); second.confirmMediaAccount(user)
        defer { first.invalidate(); second.invalidate() }
        let downloads = OfflineAlbumDownloads(), value = try album()
        await downloads.attach(first)
        downloads.download(value, client: first)
        try await waitUntil { !downloads.workingIDs.contains("album") }
        var reachedRemoval = false
        var releaseRemoval: CheckedContinuation<Void, Never>?
        downloads.beforeStorageRemoval = { _ in
            reachedRemoval = true
            await withCheckedContinuation { releaseRemoval = $0 }
        }
        let removal = Task { await downloads.remove("album") }
        try await waitUntil { reachedRemoval }
        await downloads.attach(second)
        downloads.download(value, client: second)
        XCTAssertFalse(downloads.workingIDs.contains("album"), "A replacement client bypassed the scope/album removal barrier")
        releaseRemoval?.resume(); await removal.value
        XCTAssertTrue(downloads.albums.isEmpty)
        downloads.beforeStorageRemoval = nil
        downloads.download(value, client: second)
        try await waitUntil { !downloads.workingIDs.contains("album") }
        XCTAssertEqual(downloads.albums.first?.state, .ready, "The barrier was not released after deletion")
        await downloads.remove("album")
    }
}
