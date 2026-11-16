import XCTest
import UIKit
import SwiftUI
import CryptoKit
import Nuke
import Photos
import Synchronization
import ObjectiveC
@testable import Imora

@MainActor
final class Phase4ImagePresentationFlowTests: XCTestCase {
    private func client(_ token: String = "fixture-token") -> ImoraClient {
        ImoraClient(apiURL: URL(string: "https://fixture.invalid/api")!, accessToken: token)
    }

    private func asset() -> Asset {
        Asset(id: "same-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
              visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
              duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
    }

    func testInitialViewportRequiresEveryCurrentImageAndRestoredPosition() async throws {
        let userID = "initial-viewport-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let server = try LocalHTTPServer { request in
            request.path == "/api/users/me" ? .init(body: user) : .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "initial-viewport", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client)
        let second = Asset(id: "second-image", ownerId: "alice", isImage: true, isFavorite: false,
            isTrashed: false, visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now,
            localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        let values = [asset(), second]
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: values)
        model.showsDateHeaders = false
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        grid.frame = CGRect(x: 0, y: 0, width: 390, height: 280)
        grid.contentInsetAdjustmentBehavior = .never
        grid.initialPresentationCovered = true
        var releases = 0
        grid.onInitialViewportPrepared = { releases += 1 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; host.view.addSubview(grid); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        grid.update(side: AssetGridLayout.tileSide(viewportWidth: 390, columns: 3), tailPadding: 0,
            context: .init(session: session, columns: 3, targetPixelSize: 416, showsBackupBadge: false,
                usesOriginalAspectRatio: false, isSelecting: false, selection: [], reduceMotion: true,
                registry: AssetTileRegistry(), motion: GridMotion(), isSelectable: { _ in true },
                isSelectableAssetID: { _ in true }, actions: .init(toggleSelection: { _ in },
                    menu: { _ in UIMenu(children: []) }, makeViewer: { _, _, _ in nil }), toggleDay: { _, _ in }), animated: false)
        grid.layoutIfNeeded()
        func tiles(_ view: UIView) -> [TimelineTileView] {
            (view as? TimelineTileView).map { [$0] } ?? view.subviews.flatMap { tiles($0) }
        }
        let mounted = tiles(grid)
        XCTAssertEqual(mounted.count, 2)
        let image = solidImage(pixels: 512)
        for value in values {
            ImageLoader.shared.installPrepared(image, url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash),
                targetPixelSize: 416, client: client)
            let tile = try XCTUnwrap(mounted.first { $0.asset?.id == value.id })
            tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
                pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: 0, targetPixelSize: 416)
            grid.layoutIfNeeded()
            XCTAssertEqual(releases, 0, "An incomplete viewport or unrestored position must remain covered")
        }
        XCTAssertTrue(mounted.allSatisfy(\.hasPreparedInitialImage))
        grid.initialPhotosPositionReady = true; grid.setNeedsLayout(); grid.layoutIfNeeded()
        XCTAssertEqual(releases, 1)
        grid.setNeedsLayout(); grid.layoutIfNeeded(); XCTAssertEqual(releases, 1)
        client.invalidate()
        XCTAssertTrue(mounted.allSatisfy { !$0.initialImageIsCurrent }, "Prepared pixels cannot authorize a retired session")
        await session.logOut(reportRemoteFailure: false)
    }

    func testCurrentPINElevationRecoversCanonicalLockedBucketWithoutDiskBytes() async throws {
        try await checkLockedRecovery(rollbackFromLockedPage: false)
    }

    func testFailedMoveFromElevatedLockedPageRetainsCanonicalRowAndImage() async throws {
        try await checkLockedRecovery(rollbackFromLockedPage: true)
    }

    #if DEBUG
    func testLargeRetiredHistoryDoesNotBreakRealLockedBucketAcrossRestart() async throws {
        let account = "bucket-pressure-\(UUID())"
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let payload = Data(#"{"id":["bucket-one","bucket-two","bucket-three"],"ownerId":["alice","alice","alice"],"isImage":[true,true,true],"isFavorite":[false,false,false],"isTrashed":[false,false,false],"visibility":["locked","locked","locked"],"thumbhash":["revision-one","revision-two","revision-three"],"fileCreatedAt":["2023-11-14T00:00:00.000Z","2023-11-14T00:00:00.000Z","2023-11-14T00:00:00.000Z"],"localOffsetHours":[0,0,0],"duration":[null,null,null],"livePhotoVideoId":[null,null,null],"ratio":[1,1,1]}"#.utf8)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/auth/status" { return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":3}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let historyScope = StableMediaScope.verified(server: "https://history.invalid/api", accountID: "history-\(UUID())")
        let scope = StableMediaScope.verified(server: ServerTrustPolicy(apiURL: server.apiURL).canonicalRoot, accountID: account)
        let journal = MediaContentGenerations.shared
        let journalFile = LaunchPreviewStore.rootDirectory.appending(path: "content-generations.json")
        let beforeBytes = FileManager.default.fileExists(atPath: journalFile.path) ? try Data(contentsOf: journalFile) : nil
        let restore = try journal.isolatedFixtureRestorer(scopes: [historyScope, scope], freshCapacityNamespace: true)
        let history = (0..<150).map { MediaDisplayKeyV1.Subject.remoteAsset("edited-asset-\($0)") }
        let revisions = (0..<180).map { Data(String(format: "revision-%010d", $0).utf8).base64EncodedString() }
        weak var priorModel: TimelineModel?
        weak var priorSession: LockedFolderSession?
        weak var priorClient: ImoraClient?
        var savedError: (any Error)?

        func runBucket() async throws -> [MediaDisplayKeyV1] {
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "bucket-pressure-token")
            client.confirmMediaAccount(account); ImageLoader.shared.configure(client: client)
            let locked = LockedFolderSession(client: client)
            var model: TimelineModel? = TimelineModel(filter: TimelineFilter(visibility: .locked))
            let publicTile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
            priorClient = client; priorSession = locked; priorModel = model
            defer {
                publicTile.unregister(); model = nil; locked.shutdown()
                ImageLoader.shared.configure(client: nil); client.invalidate()
            }
            await locked.refreshStatus()
            XCTAssertNotNil(client.lockedMediaLease)
            let publicAsset = Asset(id: "public-pressure", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "public-revision", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            publicTile.projectImage(asset: publicAsset, source: .init(assetID: publicAsset.id, localIdentifier: nil,
                pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: 0, targetPixelSize: 416)
            for _ in 0..<200 {
                if publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            let oldReceipt = try await client.timeBucket("2023-11-01T00:00:00Z", filter: TimelineFilter(visibility: .locked))
            let oldKeys = oldReceipt.assets.map { MediaPresentationCoordinator.gridKey(asset: $0, client: client, pixels: 416) }
            let subjects = oldReceipt.assets.map { MediaDisplayKeyV1.Subject.remoteAsset($0.id) }
            try journal.retire(scope: scope, subjects: subjects, retiresSourceRevisions: false, blocksAccess: true)
            ImageLoader.shared.markEphemeral(assetIDs: oldReceipt.assets.map(\.id))
            oldReceipt.authorizePresented(oldReceipt.assets, visibility: .locked, using: client)
            XCTAssertTrue(oldKeys.allSatisfy { !$0.isCurrentContent }, "A pre-retirement bucket cannot regrant stale producers")
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertNotNil((publicTile.makeZoomReplica() as? UIImageView)?.image?.cgImage)

            model?.attach(client); await model?.load()
            let canonical = try XCTUnwrap(model?.sections.flatMap { $0.days?.flatMap(\.assets) ?? [] })
            XCTAssertEqual(canonical.count, 3, "The locked model must project the real three-item response")
            for value in canonical {
                let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
                XCTAssertTrue(key.isCurrentContent, "All items from the same bucket receipt must be granted")
                do {
                    let image = try await ImageLoader.shared.image(for: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: 416)
                    XCTAssertNotNil(image.cgImage)
                } catch { XCTFail("A current locked bucket item did not load real endpoint bytes: \(error)") }
            }
            await model?.loadBucket("2023-11-01T00:00:00Z", refresh: true)
            for value in canonical {
                XCTAssertTrue(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent,
                    "A subsequent response must preserve earlier grants")
            }
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertTrue(journal.isRetired(scope: historyScope, subject: history[0], sourceRevision: revisions[0]))
            XCTAssertTrue(journal.isRetired(scope: historyScope, subject: history[149], sourceRevision: revisions[179]))
            return oldKeys
        }

        func awaitShutdown() async throws {
            for _ in 0..<200 {
                if priorModel == nil && priorSession == nil && priorClient == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Fixture model, client and session must finish before journal reconstruction or restore")
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let keys = history.flatMap { subject in revisions.map { revision in
                MediaDisplayKeyV1(scope: historyScope, subject: subject, sourceRevision: revision, presentationRevision: revision,
                    variant: .grid, pixelBucket: 64, fitMode: "fill", orientationRevision: "up", colorProfile: "sRGB",
                    contentGeneration: "synthetic-old-producer")
            } }
            try journal.retire(scope: historyScope, subjects: history, keys: keys)
            let size = try Data(contentsOf: LaunchPreviewStore.rootDirectory.appending(path: "content-generations.json")).count
            print("TASK17_FIX4 real bucket journal bytes=\(size), synthetic retired revisions=\(keys.count)")
            XCTAssertGreaterThan(size, 768 << 10); XCTAssertLessThan(size, (1 << 20) - 16_384)
            let old = try await runBucket()
            try await awaitShutdown()
            try journal.reloadIsolatedFixtureFromDisk()
            XCTAssertTrue(old.allSatisfy { !$0.isCurrentContent }, "Old producers stay retired after journal reconstruction")
            XCTAssertTrue(journal.isRetired(scope: historyScope, subject: history[0], sourceRevision: revisions[0]))
            _ = try await runBucket()
            try await awaitShutdown()
            try journal.reloadIsolatedFixtureFromDisk()
            XCTAssertTrue(journal.isRetired(scope: historyScope, subject: history[149], sourceRevision: revisions[179]))
        } catch { savedError = error }
        try await awaitShutdown()
        try restore()
        let afterBytes = FileManager.default.fileExists(atPath: journalFile.path) ? try Data(contentsOf: journalFile) : nil
        XCTAssertEqual(afterBytes, beforeBytes, "Fixture teardown must restore the exact pre-test file or its absence")
        print("TASK17_FIX4 journal restoration verified; prior bytes=\(beforeBytes?.count ?? 0), prior file exists=\(beforeBytes != nil)")
        if let savedError { throw savedError }
    }
    #endif

    func testElevatedStatusWithoutCurrentValidPINExpiryCannotUnlockOrReadPrivateImage() async throws {
        for expiry in ["", "not-a-date", "2000-01-01T00:00:00Z", "2099-01-01T00:00:00Z"] {
            let payload = "{\"isElevated\":true,\"pinCode\":true,\"password\":true"
                + (expiry.isEmpty ? "" : ",\"pinExpiresAt\":\"\(expiry)\"")
                + (expiry.hasPrefix("2099") ? ",\"expiresAt\":\"2000-01-01T00:00:00Z\"" : "") + "}"
            let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
            let server = try LocalHTTPServer { request in
                if request.path == "/api/auth/status" { return .init(body: Data(payload.utf8)) }
                return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
            }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "lease-denial-\(UUID())")
            client.confirmMediaAccount("lease-denial-\(UUID())")
            ImageLoader.shared.configure(client: client)
            defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
            let locked = LockedFolderSession(client: client); defer { locked.shutdown() }
            await locked.refreshStatus()
            XCTAssertFalse(locked.isUnlocked, "Missing, invalid, expired PIN or earlier session expiry is never an unlimited private lease")
            ImageLoader.shared.markEphemeral(assetIDs: ["same-id"])
            do {
                _ = try await ImageLoader.shared.image(for: client.thumbnailURL(assetID: "same-id", cacheKey: "R"), targetPixelSize: 416)
                XCTFail("Private endpoint accepted without a valid current elevation")
            } catch { }
            XCTAssertFalse(server.received.contains { $0.path.contains("/thumbnail") })
        }
    }

    func testUnlockHTTP200WithoutConfirmedStatusRemainsTruthfullyLocked() async throws {
        let server = try LocalHTTPServer { request in .init(status: request.path.hasSuffix("/unlock") ? 200 : 503) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "unlock-status-\(UUID())")
        client.confirmMediaAccount("unlock-status-\(UUID())")
        defer { client.invalidate() }
        let locked = LockedFolderSession(client: client); defer { locked.shutdown() }
        do { try await locked.unlock(pin: "123456"); XCTFail("An unconfirmed status cannot report successful private unlock") }
        catch { }
        XCTAssertFalse(locked.isUnlocked)
    }

    func testMountedPrivateTileRevokesAndRenewsWithoutChurningPublicImageOrWritingPrivateBytes() async throws {
        let userID = "private-mounted-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let deadline = Mutex("2099-01-01T00:00:00Z"), status = Mutex(200)
        // This private fixture must differ from public endpoint JPEGs used by
        // other tests: the disk assertion below compares the entire directory.
        let bytes = try XCTUnwrap(solidImage(pixels: 529).jpegData(compressionQuality: 0.87))
        let publicBytes = try XCTUnwrap(solidImage(pixels: 544).jpegData(compressionQuality: 0.87))
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/session/unlock" { return .init() }
            if request.path == "/api/auth/status" { return .init(status: status.withLock { $0 }, body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8)) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("public-id") ? publicBytes : bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "private-mounted", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            var value = asset(); value.visibility = .locked
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
            await locked.refreshStatus() // Fresh server status is valid even without this round's unlock POST.
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            for _ in 0..<150 {
                if tile.checkpointSurface(for: key, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let firstLease = try XCTUnwrap(client.lockedMediaLease)
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
            let url = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
            let disk = try DataCache(name: "imora-images"); disk.flush()
            let diskImage = await ImageLoader.shared.diskImage(for: url, targetPixelSize: 416)
            XCTAssertNil(diskImage)
            let files = try FileManager.default.contentsOfDirectory(at: disk.path, includingPropertiesForKeys: nil)
            XCTAssertFalse(files.contains { (try? Data(contentsOf: $0)) == bytes }, "Private original endpoint bytes must not exist in the actual Nuke disk directory")
            let packRoot = FileManager.default.temporaryDirectory.appending(path: "private-pack-\(UUID())")
            defer { try? FileManager.default.removeItem(at: packRoot) }
            let snapshot = LaunchViewportSnapshot(scope: key.scope, source: "cloud", filter: "locked", sort: "date", anchor: value.id,
                layout: .init(width: 402, height: 874, scale: 3, columns: 3), visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
            do {
                _ = try await LaunchPreviewStore(root: packRoot).checkpoint(snapshot: snapshot,
                    images: [.init(key: key, bytes: bytes, pixelWidth: 529, pixelHeight: 529, content: .photograph)])
                XCTFail("A real private surface was written into the launch pack")
            } catch { }
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            let publicURL = client.thumbnailURL(assetID: publicAsset.id, cacheKey: publicAsset.thumbhash)
            _ = try await ImageLoader.shared.image(for: publicURL, targetPixelSize: 416)
            locked.lock()
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "Revocation clears the already mounted private UIImage without manual projection")
            XCTAssertFalse(firstLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 416))
            XCTAssertTrue(publicKey.isCurrentContent)
            XCTAssertNotNil(ImageLoader.shared.cachedImage(for: publicURL, targetPixelSize: 416))
            deadline.withLock { $0 = "2099-01-01T00:00:00Z" }
            try await locked.unlock(pin: "123456")
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image, "A fresh E2 lease renews the same mounted producer")
            XCTAssertFalse(firstLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            status.withLock { $0 = 403 }
            await locked.refreshStatus()
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(client.lockedMediaLease, "A known server rejection immediately revokes private authority")
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
            status.withLock { $0 = 200 }; deadline.withLock { $0 = Date().addingTimeInterval(1.5).ISO8601Format() }
            await locked.refreshStatus()
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
            for _ in 0..<250 {
                if client.lockedMediaLease == nil && (tile.makeZoomReplica() as? UIImageView)?.image == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(client.lockedMediaLease)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "PIN expiry revokes the actual mounted private image")
            XCTAssertNotNil(ImageLoader.shared.cachedImage(for: publicURL, targetPixelSize: 416))
        } catch { await finish(); throw error }
        await finish()
    }

    func testVerifiedAccountChangeCannotRebindAnEarlierAccountsPrivateLease() async throws {
        let server = try LocalHTTPServer { _ in .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8)) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "scope-lease-\(UUID())")
        client.confirmMediaAccount("account-a"); defer { client.invalidate() }
        _ = try await client.authStatus()
        let old = try XCTUnwrap(client.lockedMediaLease)
        client.confirmMediaAccount("account-b")
        XCTAssertFalse(old.isCurrent)
        XCTAssertNil(client.lockedMediaLease, "A's status may not manufacture a lease for newly verified B")
    }

    func testAuthenticatedStatusStartedBeforeLockCannotRestoreOldElevation() async throws {
        let gate = DispatchSemaphore(value: 0), reads = Mutex(0)
        let server = try LocalHTTPServer { request in
            if request.path == "/api/auth/status" {
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 2 { _ = gate.wait(timeout: .now() + 3) }
                return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
            }
            return .init()
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "late-status-\(UUID())")
        client.confirmMediaAccount("late-status-\(UUID())"); defer { client.invalidate() }
        let locked = LockedFolderSession(client: client); defer { locked.shutdown() }
        await locked.refreshStatus(); XCTAssertTrue(locked.isUnlocked)
        let old = try XCTUnwrap(client.lockedMediaLease)
        let pending = Task { try await client.authStatus() }
        for _ in 0..<100 {
            if reads.withLock({ $0 }) == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reads.withLock { $0 }, 2)
        locked.lock(); gate.signal()
        do { _ = try await pending.value; XCTFail("A pre-lock authenticated status cannot renew a retired elevation nonce") } catch { }
        XCTAssertFalse(locked.isUnlocked); XCTAssertNil(client.lockedMediaLease); XCTAssertFalse(old.isCurrent)
    }

    func testNewerFolderStatusDeadlineSurvivesOlderSuccessfulResponseAndRevokesMountedBytes() async throws {
        try await checkOverlappingStatusDeadline(newerUsesClient: false)
    }

    func testNewerAccountStatusSynchronizesFolderAndRevokesMountedBytes() async throws {
        try await checkOverlappingStatusDeadline(newerUsesClient: true)
    }

    func testOlderStatusRejectionCannotRevokeNewerLeaseButCurrentRejectionCan() async throws {
        for code in [401, 403, 404] { try await checkLateStatusRejection(code: code) }
    }

    private func checkLateStatusRejection(code: Int) async throws {
        let gate = DispatchSemaphore(value: 0), reads = Mutex(0)
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path == "/api/auth/status" else { return .init(status: 503) }
            let number = reads.withLock { $0 += 1; return $0 }
            if number == 2 { _ = gate.wait(timeout: .now() + 10); return .init(status: code) }
            if number == 4 { return .init(status: code) }
            return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "late-rejection-\(UUID())")
        client.confirmMediaAccount("late-rejection-\(UUID())"); defer { client.invalidate() }
        let locked = LockedFolderSession(client: client); defer { locked.shutdown() }
        await locked.refreshStatus()
        let first = try XCTUnwrap(client.lockedMediaLease)
        let older = Task { try await client.authStatus() }
        for _ in 0..<200 {
            if reads.withLock({ $0 }) == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reads.withLock { $0 }, 2)
        _ = try await client.authStatus()
        XCTAssertNotNil(client.lockedMediaLease)
        gate.signal()
        do { _ = try await older.value; XCTFail("A server rejection must not become a successful status") }
        catch is CancellationError { }
        catch { XCTFail("A superseded status rejection must be discarded: \(error)") }
        XCTAssertNotNil(client.lockedMediaLease); XCTAssertTrue(first.isCurrent); XCTAssertTrue(locked.isUnlocked)
        do { _ = try await client.authStatus(); XCTFail("A current rejection must revoke private authority") }
        catch ImoraError.http(let actual, _) { XCTAssertEqual(actual, code) }
        for _ in 0..<100 {
            if !locked.isUnlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(client.lockedMediaLease); XCTAssertFalse(first.isCurrent); XCTAssertFalse(locked.isUnlocked)
    }

    #if DEBUG
    func testOlderInvalidStatusCannotRevokeNewerMountedLease() async throws {
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil), reached = Mutex(false)
        let oldEndpointGate = DispatchSemaphore(value: 0), newEndpointGate = DispatchSemaphore(value: 0)
        let oldEndpointStarted = Mutex(false), oldEndpointReturned = Mutex(false), newEndpointStarted = Mutex(false)
        let privateThumbnailReads = Mutex(0)
        let deadline = Mutex("2099-01-01T00:00:00Z")
        let userID = "invalid-status-race-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let oldBytes = try XCTUnwrap(solidImage(pixels: 528).jpegData(compressionQuality: 0.87))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func bytes(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.87))
        }
        let newBytes = try bytes(.blue), lateBytes = try bytes(.green), publicBytes = try bytes(.purple)
        func rgba(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" { return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8)) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("public-id") { return .init(headers: ["Content-Type": "image/jpeg"], body: publicBytes) }
                if request.path.contains("size=preview") {
                    if request.path.contains("edited=false") {
                        newEndpointStarted.withLock { $0 = true }
                        _ = newEndpointGate.wait(timeout: .now() + 25)
                        return .init(headers: ["Content-Type": "image/jpeg"], body: newBytes)
                    }
                    oldEndpointStarted.withLock { $0 = true }
                    _ = oldEndpointGate.wait(timeout: .now() + 25)
                    oldEndpointReturned.withLock { $0 = true }
                    return .init(headers: ["Content-Type": "image/jpeg"], body: lateBytes)
                }
                let read = privateThumbnailReads.withLock { $0 += 1; return $0 }
                return .init(headers: ["Content-Type": "image/jpeg"], body: read == 1 ? oldBytes : newBytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { oldEndpointGate.signal(); newEndpointGate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "invalid-status-race", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        func releaseStatus() { held.withLock { value in let continuation = value; value = nil; return continuation }?.resume() }
        defer { releaseStatus(); client.setInvalidStatusFixtureHook(nil) }
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let publicTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(publicTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister(); publicTile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            var value = asset(); value.visibility = .locked
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            publicTile.configure(asset: publicAsset, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            await locked.refreshStatus()
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            for _ in 0..<200 {
                if tile.checkpointSurface(for: key, client: client) != nil && publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            let oldLease = try XCTUnwrap(client.lockedMediaLease)
            let oldBitmap = try XCTUnwrap((tile.makeZoomReplica() as? UIImageView)?.image)
            let oldColor = try rgba(oldBitmap)
            XCTAssertGreaterThan(oldColor[0], oldColor[2], "E1 must be a real red endpoint bitmap mounted on screen")
            let privateURL = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
            let oldPreviewURL = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
            let oldEndpoint = Task { try await ImageLoader.shared.image(for: oldPreviewURL, targetPixelSize: 416) }
            for _ in 0..<200 {
                if oldEndpointStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard oldEndpointStarted.withLock({ $0 }) else { XCTFail("E1 must reach the real held thumbnail endpoint"); throw CocoaError(.fileReadUnknown) }
            client.setInvalidStatusFixtureHook {
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                    reached.withLock { $0 = true }
                }
            }
            deadline.withLock { $0 = "not-a-date" }
            let older = Task { await locked.refreshStatus() }
            for _ in 0..<200 {
                if reached.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard reached.withLock({ $0 }) else { XCTFail("The accepted invalid status must pause before cleanup"); throw CocoaError(.fileReadUnknown) }
            XCTAssertNil(client.lockedMediaLease)
            XCTAssertFalse(oldLease.isCurrent)
            XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertNil(tile.checkpointSurface(for: key, client: client), "The still-mounted E1 bitmap is denied during the invalid gap")
            XCTAssertTrue((tile.makeZoomReplica() as? UIImageView)?.image === oldBitmap, "The denial is tested against the actual mounted E1 bitmap")
            client.setInvalidStatusFixtureHook(nil)
            deadline.withLock { $0 = "2099-01-01T00:00:00Z" }
            await locked.refreshStatus()
            let newLease = try XCTUnwrap(client.lockedMediaLease)
            XCTAssertTrue(locked.isUnlocked)
            XCTAssertNotEqual(oldLease.identity, newLease.identity)
            XCTAssertFalse(oldLease.isCurrent, "A later valid status cannot revive E1")
            XCTAssertFalse(oldSurface.isCurrent(), "The mounted E1 surface cannot become authorized again")
            tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
                pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: ImageLoadRecovery.shared.generation, targetPixelSize: 416)
            for _ in 0..<200 {
                if privateThumbnailReads.withLock({ $0 }) >= 2,
                   tile.checkpointSurface(for: key, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let newSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let newColor = try rgba(newSurface.image)
            XCTAssertGreaterThanOrEqual(privateThumbnailReads.withLock { $0 }, 2, "E2 must fetch its own actual endpoint bitmap")
            XCTAssertGreaterThan(newColor[2], newColor[0], "E2 must display the new blue endpoint bitmap")
            XCTAssertFalse(oldSurface.isCurrent())

            let newPreviewURL = client.thumbnailURL(assetID: value.id, size: "preview", edited: false, cacheKey: value.thumbhash)
            let newEndpoint = Task { try await ImageLoader.shared.image(for: newPreviewURL, targetPixelSize: 416) }
            for _ in 0..<200 {
                if newEndpointStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard newEndpointStarted.withLock({ $0 }) else { XCTFail("E2 must reach its separately held endpoint"); throw CocoaError(.fileReadUnknown) }
            oldEndpointGate.signal()
            do {
                let image = try await oldEndpoint.value
                XCTFail("A held E1 endpoint delivered a bitmap after E2: \(String(describing: image.cgImage))")
            } catch { }
            XCTAssertTrue(oldEndpointReturned.withLock { $0 }, "The E1 server returned its actual late response")
            XCTAssertFalse(oldLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertTrue(newLease.isCurrent); XCTAssertTrue(newSurface.isCurrent())
            XCTAssertTrue((tile.makeZoomReplica() as? UIImageView)?.image === newSurface.image)
            releaseStatus(); await older.value
            XCTAssertTrue(newLease.isCurrent, "Delayed E1 cleanup cannot revoke E2")
            XCTAssertTrue(newSurface.isCurrent())
            XCTAssertNotNil(ImageLoader.shared.cachedImage(for: privateURL, targetPixelSize: 416), "Delayed E1 cleanup cannot purge E2 cached bytes")
            XCTAssertTrue((tile.makeZoomReplica() as? UIImageView)?.image === newSurface.image)
            newEndpointGate.signal()
            let newEndpointImage = try await newEndpoint.value
            let endpointColor = try rgba(newEndpointImage)
            XCTAssertGreaterThan(endpointColor[2], endpointColor[0], "Delayed E1 cleanup cannot cancel E2 endpoint work")
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertTrue((publicTile.makeZoomReplica() as? UIImageView)?.image === publicSurface.image)
        } catch { oldEndpointGate.signal(); newEndpointGate.signal(); releaseStatus(); await finish(); throw error }
        await finish()
    }

    func testIndependentValidStatusAutomaticallyRebindsMountedPrivateImage() async throws {
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil), reached = Mutex(false)
        let oldEndpointGate = DispatchSemaphore(value: 0), newEndpointGate = DispatchSemaphore(value: 0)
        let newGridGate = DispatchSemaphore(value: 0), newGridStarted = Mutex(false)
        let oldEndpointStarted = Mutex(false), oldEndpointReturned = Mutex(false), newEndpointStarted = Mutex(false)
        let privateThumbnailReads = Mutex(0)
        let deadline = Mutex("2099-01-01T00:00:00Z")
        let userID = "automatic-status-race-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let oldBytes = try XCTUnwrap(solidImage(pixels: 528).jpegData(compressionQuality: 0.87))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func bytes(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.87))
        }
        let newBytes = try bytes(.blue), lateBytes = try bytes(.green), publicBytes = try bytes(.purple)
        func rgba(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" { return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8)) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("public-id") { return .init(headers: ["Content-Type": "image/jpeg"], body: publicBytes) }
                if request.path.contains("size=preview") {
                    if request.path.contains("edited=false") {
                        newEndpointStarted.withLock { $0 = true }
                        _ = newEndpointGate.wait(timeout: .now() + 25)
                        return .init(headers: ["Content-Type": "image/jpeg"], body: newBytes)
                    }
                    oldEndpointStarted.withLock { $0 = true }
                    _ = oldEndpointGate.wait(timeout: .now() + 25)
                    oldEndpointReturned.withLock { $0 = true }
                    return .init(headers: ["Content-Type": "image/jpeg"], body: lateBytes)
                }
                let read = privateThumbnailReads.withLock { $0 += 1; return $0 }
                if read == 1 { return .init(headers: ["Content-Type": "image/jpeg"], body: oldBytes) }
                newGridStarted.withLock { $0 = true }
                _ = newGridGate.wait(timeout: .now() + 25)
                return .init(headers: ["Content-Type": "image/jpeg"], body: newBytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { oldEndpointGate.signal(); newEndpointGate.signal(); newGridGate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "invalid-status-race", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        func releaseStatus() { held.withLock { value in let continuation = value; value = nil; return continuation }?.resume() }
        defer { releaseStatus(); client.setInvalidStatusFixtureHook(nil) }
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let publicTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(publicTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister(); publicTile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            var value = asset(); value.visibility = .locked
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            publicTile.configure(asset: publicAsset, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            await locked.refreshStatus()
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            for _ in 0..<200 {
                if tile.checkpointSurface(for: key, client: client) != nil && publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            let oldLease = try XCTUnwrap(client.lockedMediaLease)
            let oldBitmap = try XCTUnwrap((tile.makeZoomReplica() as? UIImageView)?.image)
            let oldColor = try rgba(oldBitmap)
            XCTAssertGreaterThan(oldColor[0], oldColor[2], "E1 must be a real red endpoint bitmap mounted on screen")
            let privateURL = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
            let oldPreviewURL = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
            let oldEndpoint = Task { try await ImageLoader.shared.image(for: oldPreviewURL, targetPixelSize: 416) }
            for _ in 0..<200 {
                if oldEndpointStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard oldEndpointStarted.withLock({ $0 }) else { XCTFail("E1 must reach the real held thumbnail endpoint"); throw CocoaError(.fileReadUnknown) }
            client.setInvalidStatusFixtureHook {
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                    reached.withLock { $0 = true }
                }
            }
            deadline.withLock { $0 = "not-a-date" }
            let older = Task { try? await client.authStatus() }
            for _ in 0..<200 {
                if reached.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard reached.withLock({ $0 }) else { XCTFail("The accepted invalid status must pause before cleanup"); throw CocoaError(.fileReadUnknown) }
            XCTAssertNil(client.lockedMediaLease)
            XCTAssertFalse(oldLease.isCurrent)
            XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertNil(tile.checkpointSurface(for: key, client: client), "The still-mounted E1 bitmap is denied during the invalid gap")
            if let gapBitmap = (tile.makeZoomReplica() as? UIImageView)?.image {
                XCTAssertTrue(gapBitmap === oldBitmap, "An unqualified replacement must not appear during the invalid gap")
            }
            client.setInvalidStatusFixtureHook(nil)
            deadline.withLock { $0 = "2099-01-01T00:00:00Z" }
            _ = try await client.authStatus() // Independent account-security caller, not the folder refresh path.
            let newLease = try XCTUnwrap(client.lockedMediaLease)
            XCTAssertTrue(locked.isUnlocked)
            XCTAssertNotEqual(oldLease.identity, newLease.identity)
            XCTAssertFalse(oldLease.isCurrent, "A later valid status cannot revive E1")
            XCTAssertFalse(oldSurface.isCurrent(), "The mounted E1 surface cannot become authorized again")
            for _ in 0..<200 {
                if newGridStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard newGridStarted.withLock({ $0 }) else {
                XCTFail("The mounted tile did not automatically start a fresh E2 endpoint request")
                throw CocoaError(.fileReadUnknown)
            }
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image,
                "Retired E1 pixels must clear while the fresh E2 endpoint is held")
            XCTAssertTrue((publicTile.makeZoomReplica() as? UIImageView)?.image === publicSurface.image)
            newGridGate.signal()
            for _ in 0..<200 {
                if privateThumbnailReads.withLock({ $0 }) >= 2,
                   tile.checkpointSurface(for: key, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let newSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let newColor = try rgba(newSurface.image)
            XCTAssertGreaterThanOrEqual(privateThumbnailReads.withLock { $0 }, 2, "E2 must fetch its own actual endpoint bitmap")
            XCTAssertGreaterThan(newColor[2], newColor[0], "Observed mounted tile must automatically display fresh E2 endpoint pixels")
            XCTAssertFalse(oldSurface.isCurrent())

            let newPreviewURL = client.thumbnailURL(assetID: value.id, size: "preview", edited: false, cacheKey: value.thumbhash)
            let newEndpoint = Task { try await ImageLoader.shared.image(for: newPreviewURL, targetPixelSize: 416) }
            for _ in 0..<200 {
                if newEndpointStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard newEndpointStarted.withLock({ $0 }) else { XCTFail("E2 must reach its separately held endpoint"); throw CocoaError(.fileReadUnknown) }
            oldEndpointGate.signal()
            do {
                let image = try await oldEndpoint.value
                XCTFail("A held E1 endpoint delivered a bitmap after E2: \(String(describing: image.cgImage))")
            } catch { }
            XCTAssertTrue(oldEndpointReturned.withLock { $0 }, "The E1 server returned its actual late response")
            XCTAssertFalse(oldLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertTrue(newLease.isCurrent); XCTAssertTrue(newSurface.isCurrent())
            XCTAssertTrue((tile.makeZoomReplica() as? UIImageView)?.image === newSurface.image)
            releaseStatus(); _ = await older.value
            XCTAssertTrue(newLease.isCurrent, "Delayed E1 cleanup cannot revoke E2")
            XCTAssertTrue(newSurface.isCurrent())
            XCTAssertNotNil(ImageLoader.shared.cachedImage(for: privateURL, targetPixelSize: 416), "Delayed E1 cleanup cannot purge E2 cached bytes")
            XCTAssertTrue((tile.makeZoomReplica() as? UIImageView)?.image === newSurface.image)
            newEndpointGate.signal()
            let newEndpointImage = try await newEndpoint.value
            let endpointColor = try rgba(newEndpointImage)
            XCTAssertGreaterThan(endpointColor[2], endpointColor[0], "Delayed E1 cleanup cannot cancel E2 endpoint work")
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertTrue((publicTile.makeZoomReplica() as? UIImageView)?.image === publicSurface.image)
        } catch { oldEndpointGate.signal(); newEndpointGate.signal(); newGridGate.signal(); releaseStatus(); await finish(); throw error }
        await finish()
    }

    func testIndependentStatusAutomaticallyClearsAndRebindsMountedSwiftUIPrivateImage() async throws {
        let heldStatus = Mutex<CheckedContinuation<Void, Never>?>(nil), denialReached = Mutex(false)
        let newGridGate = DispatchSemaphore(value: 0), newGridStarted = Mutex(false)
        let privateReads = Mutex(0), deadline = Mutex("2099-01-01T00:00:00Z")
        let userID = "swiftui-private-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        func bytes(_ color: UIColor) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let oldBytes = try bytes(.red), newBytes = try bytes(.blue), publicBytes = try bytes(.purple)
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" {
                return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8))
            }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("public-swiftui") { return .init(headers: ["Content-Type": "image/jpeg"], body: publicBytes) }
                if privateReads.withLock({ $0 += 1; return $0 }) == 1 {
                    return .init(headers: ["Content-Type": "image/jpeg"], body: oldBytes)
                }
                newGridStarted.withLock { $0 = true }
                _ = newGridGate.wait(timeout: .now() + 25)
                return .init(headers: ["Content-Type": "image/jpeg"], body: newBytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { newGridGate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "swiftui-private", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        func releaseDenial() { heldStatus.withLock { let held = $0; $0 = nil; return held }?.resume() }
        defer { releaseDenial(); client.setInvalidStatusFixtureHook(nil) }
        var value = asset(); value.visibility = .locked
        ImageLoader.shared.markEphemeral(assetIDs: [value.id])
        await locked.refreshStatus()
        let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
        let privateURL = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
        let publicURL = client.thumbnailURL(assetID: "public-swiftui", cacheKey: "r1")
        let root = HStack(spacing: 16) {
            RemoteImage(url: privateURL, targetPixelSize: 416).frame(width: 132, height: 132)
            RemoteImage(url: publicURL, targetPixelSize: 416).frame(width: 132, height: 132)
        }.environment(session)
        let host = UIHostingController(rootView: root)
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        host.view.layoutIfNeeded() // Initial fixture layout only.
        func finish() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        func pixel(x: CGFloat) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let rect = CGRect(x: x.rounded(.down), y: (host.view.bounds.midY).rounded(.down), width: 1, height: 1)
            let cropped = try XCTUnwrap(cg.cropping(to: rect))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        do {
            let privateX = host.view.bounds.midX - 74, publicX = host.view.bounds.midX + 74
            for _ in 0..<200 {
                let a = try pixel(x: privateX), b = try pixel(x: publicX)
                if a[0] > 180 && a[2] < 80 && b[0] > 50 && b[2] > 50 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let old = try pixel(x: privateX), publicBefore = try pixel(x: publicX)
            XCTAssertGreaterThan(old[0], 180, "E1 must be an actually rendered red endpoint image")
            XCTAssertLessThan(old[2], 80)
            XCTAssertGreaterThan(publicBefore[0], 50); XCTAssertGreaterThan(publicBefore[2], 50)
            let oldLease = try XCTUnwrap(client.lockedMediaLease)
            client.setInvalidStatusFixtureHook {
                await withCheckedContinuation { continuation in
                    heldStatus.withLock { $0 = continuation }; denialReached.withLock { $0 = true }
                }
            }
            deadline.withLock { $0 = "not-a-date" }
            let denied = Task { try? await client.authStatus() }
            for _ in 0..<200 {
                if denialReached.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard denialReached.withLock({ $0 }) else { XCTFail("The invalid acceptance was not held"); throw CocoaError(.fileReadUnknown) }
            client.setInvalidStatusFixtureHook(nil)
            deadline.withLock { $0 = "2099-01-01T00:00:00Z" }
            _ = try await client.authStatus()
            XCTAssertFalse(oldLease.isCurrent)
            for _ in 0..<200 {
                if newGridStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let whileHeld = try pixel(x: privateX)
            XCTAssertFalse(whileHeld[0] > 180 && whileHeld[2] < 80,
                "Retired E1 pixels must clear automatically from the mounted SwiftUI view")
            guard newGridStarted.withLock({ $0 }) else { XCTFail("The mounted view did not request fresh E2 bytes"); throw CocoaError(.fileReadUnknown) }
            XCTAssertEqual(try pixel(x: publicX), publicBefore, "A private change must preserve the public rendered surface")
            newGridGate.signal()
            for _ in 0..<200 {
                let image = try pixel(x: privateX)
                if image[2] > 180 && image[0] < 80 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let renewed = try pixel(x: privateX)
            XCTAssertGreaterThan(renewed[2], 180, "Fresh E2 bytes must become the actual rendered image")
            XCTAssertLessThan(renewed[0], 80)
            releaseDenial(); _ = await denied.value
            XCTAssertEqual(try pixel(x: publicX), publicBefore)
        } catch { newGridGate.signal(); releaseDenial(); await finish(); throw error }
        await finish()
    }

    func testViewerTransitionAutomaticallyClearsRetiredPrivateSurface() async throws {
        let (pairedLocalID, _) = try await createSurfaceFixture()
        let pairedRevision = try XCTUnwrap(LocalImageLoader.currentModificationRevision(pairedLocalID))
        let heldStatus = Mutex<CheckedContinuation<Void, Never>?>(nil), denialReached = Mutex(false)
        let oldGate = DispatchSemaphore(value: 0), newGate = DispatchSemaphore(value: 0)
        let oldViewerStarted = Mutex(false), oldPreviewReturned = Mutex(false), newStarted = Mutex(false)
        let e2PreviewStarted = Mutex(false), e2PreviewReads = Mutex(0), wireOK = Mutex(true)
        let reads = Mutex(0), epoch = Mutex(1)
        let deadline = Mutex("2099-01-01T00:00:00Z"), userID = "viewer-private-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        func bytes(_ color: UIColor, pixels: Int) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width: pixels, height: pixels)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                color.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let red = try bytes(.red, pixels: 640), blue = try bytes(.blue, pixels: 640)
        let redPreview = try bytes(.red, pixels: 2048), bluePreview = try bytes(.blue, pixels: 2048)
        let redHash = SHA256.hash(data: red).map { String(format: "%02x", $0) }.joined()
        let blueHash = SHA256.hash(data: blue).map { String(format: "%02x", $0) }.joined()
        let redPreviewHash = SHA256.hash(data: redPreview).map { String(format: "%02x", $0) }.joined()
        let bluePreviewHash = SHA256.hash(data: bluePreview).map { String(format: "%02x", $0) }.joined()
        print("TASK18_TRACE fixture-red=\(redHash) fixture-blue=\(blueHash) thumbnail=640x640 preview=2048x2048 blue-preview=\(bluePreviewHash) bytes=\(bluePreview.count)")
        func releaseOld() { for _ in 0..<12 { oldGate.signal() } }
        func releaseNew() { for _ in 0..<12 { newGate.signal() } }
        func releaseGates() { releaseOld(); releaseNew() }
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" {
                return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8))
            }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("imora-private-producer") || request.path.contains("imora-session")
                    || request.headers["authorization"] != "Bearer viewer-private" { wireOK.withLock { $0 = false } }
                let read = reads.withLock { $0 += 1; return $0 }
                let kind = request.path.contains("size=preview") ? "preview" : "thumbnail"
                if read == 1 {
                    print("TASK18_TRACE server-return read=\(read) kind=\(kind) epoch=1 sha256=\(redHash)")
                    return .init(headers: ["Content-Type": "image/jpeg"], body: red)
                }
                if epoch.withLock({ $0 }) == 1 {
                    oldViewerStarted.withLock { $0 = true }
                    _ = oldGate.wait(timeout: .now() + 25)
                    if kind == "preview" { oldPreviewReturned.withLock { $0 = true } }
                    let body = kind == "preview" ? redPreview : red
                    print("TASK18_TRACE server-return read=\(read) kind=\(kind) epoch=1 sha256=\(kind == "preview" ? redPreviewHash : redHash)")
                    return .init(headers: ["Content-Type": "image/jpeg"], body: body)
                }
                newStarted.withLock { $0 = true }
                if kind == "preview" {
                    e2PreviewStarted.withLock { $0 = true }
                    e2PreviewReads.withLock { $0 += 1 }
                }
                _ = newGate.wait(timeout: .now() + 25)
                let body = kind == "preview" ? bluePreview : blue
                print("TASK18_TRACE server-return read=\(read) kind=\(kind) epoch=2 sha256=\(kind == "preview" ? bluePreviewHash : blueHash)")
                return .init(headers: ["Content-Type": "image/jpeg"], body: body)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { releaseGates(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "viewer-private", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        session.backup?.adoptLaunchSelections([.init(localIdentifier: pairedLocalID,
            modificationRevision: pairedRevision, remoteIdentifier: "same-id")])
        func releaseDenial() { heldStatus.withLock { let held = $0; $0 = nil; return held }?.resume() }
        defer { releaseDenial(); client.setInvalidStatusFixtureHook(nil) }
        var value = asset(); value.visibility = .locked
        ImageLoader.shared.markEphemeral(assetIDs: [value.id]); await locked.refreshStatus()
        let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let rootController = try XCTUnwrap(window.rootViewController)
        let parent = UIViewController()
        parent.view.backgroundColor = .darkGray
        parent.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rootController.present(parent, animated: false) { continuation.resume() }
        }
        let tile = TimelineTileView(frame: .init(x: 40, y: 150, width: 132, height: 132)), registry = AssetTileRegistry()
        parent.view.addSubview(tile)
        tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
        parent.view.layoutIfNeeded() // Initial fixture layout only.
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        for _ in 0..<200 {
            if tile.checkpointSurface(for: key, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
        let presentation = ViewerPresentation(), route = try XCTUnwrap(presentation.makeRoute(assets: [value], initialIndex: 0))
        var didPresent = false
        let viewer = AssetViewerHostingController(route: route, startsAsContextPreview: false, previewBounds: window.bounds.size,
            session: session, sourceRegistry: registry, album: nil, personID: nil,
            willPresent: { presentation.activate($0, presentsCover: false) }, didPresent: { _ in didPresent = true },
            didDismiss: { presentation.complete($0) }, onChange: { _ in })
        func finish() async {
            releaseGates(); releaseDenial()
            viewer.requestDismissal()
            for _ in 0..<200 {
                if parent.presentedViewController == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            tile.unregister(); tile.removeFromSuperview()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parent.dismiss(animated: false) { continuation.resume() }
            }
            await session.logOut(reportRemoteFailure: false)
        }
        func centerPixel(xOffset: CGFloat = 0, evidence: String? = nil) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            if let evidence, let bytes = image.pngData() {
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
                attachment.name = evidence; attachment.lifetime = .keepAlways; add(attachment)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let pixelImage = try XCTUnwrap(cg.cropping(to: CGRect(x: (window.bounds.midX + xOffset).rounded(.down), y: window.bounds.midY.rounded(.down), width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        do {
            viewer.presentDirectly(from: parent)
            for _ in 0..<250 {
                if didPresent && oldViewerStarted.withLock({ $0 }) {
                    let image = try centerPixel()
                    if image[0] > 180 && image[2] < 80 { break }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(didPresent); XCTAssertTrue(oldViewerStarted.withLock { $0 })
            let opening = try centerPixel(evidence: "viewer-private-opening")
            XCTAssertGreaterThan(opening[0], 180, "The real viewer must show the bound red opening surface")
            XCTAssertLessThan(opening[2], 80)
            client.setInvalidStatusFixtureHook {
                await withCheckedContinuation { continuation in
                    heldStatus.withLock { $0 = continuation }; denialReached.withLock { $0 = true }
                }
            }
            deadline.withLock { $0 = "not-a-date" }
            let denied = Task { try? await client.authStatus() }
            for _ in 0..<200 {
                if denialReached.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard denialReached.withLock({ $0 }) else { XCTFail("The invalid acceptance was not held"); throw CocoaError(.fileReadUnknown) }
            client.setInvalidStatusFixtureHook(nil); epoch.withLock { $0 = 2 }
            deadline.withLock { $0 = "2099-01-01T00:00:00Z" }
            _ = try await client.authStatus()
            let newLease = try XCTUnwrap(client.lockedMediaLease)
            XCTAssertFalse(oldSurface.isCurrent())
            for _ in 0..<200 {
                let image = try centerPixel()
                if !(image[0] > 180 && image[2] < 80) && newStarted.withLock({ $0 }) && e2PreviewStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let pending = try centerPixel(evidence: "viewer-private-e2-held")
            XCTAssertFalse(pending[0] > 180 && pending[2] < 80,
                "The viewer must automatically remove its retired E1 transition pixels while E2 is held")
            XCTAssertTrue(newStarted.withLock { $0 }, "The viewer or mounted tile must start fresh E2 work")
            XCTAssertTrue(e2PreviewStarted.withLock { $0 }, "The healthy viewer must start an independent E2 preview endpoint while E1 is held")
            let previewURL = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
            let peer = Task { try await ImageLoader.shared.image(for: previewURL, targetPixelSize: pagePixelSize) }
            defer { peer.cancel() }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(e2PreviewReads.withLock { $0 }, 1, "Two same-lease preview consumers must share one real endpoint transfer")
            releaseOld()
            for _ in 0..<200 {
                if oldPreviewReturned.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(oldPreviewReturned.withLock { $0 }, "The held E1 preview must actually return before E2")
            XCTAssertTrue(newLease.isCurrent)
            releaseDenial(); _ = await denied.value
            XCTAssertTrue(newLease.isCurrent, "Delayed E1 cleanup must not revoke E2")
            releaseNew()
            let peerImage = try await peer.value
            XCTAssertEqual(peerImage.cgImage?.width, 2048)
            XCTAssertEqual(peerImage.cgImage?.height, 2048)
            XCTAssertTrue(wireOK.withLock { $0 }, "Only the original authenticated endpoint may go on the wire")
            for _ in 0..<200 {
                let image = try centerPixel()
                if image[2] > 180 && image[0] < 80 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let photo = try centerPixel(xOffset: 80)
            XCTAssertGreaterThan(photo[2], 180, "The actual viewer photo must contain fresh blue E2 pixels")
            XCTAssertLessThan(photo[0], 80)
            let renewed = try centerPixel(evidence: "viewer-private-e2-released")
            print("TASK18_VIEWER pixels=\(renewed) viewerMounted=\(viewer.view.window != nil) presented=\(parent.presentedViewController === viewer) reads=\(reads.withLock { $0 }) lease=\(client.lockedMediaLease != nil) tileCurrent=\(tile.checkpointSurface(for: key, client: client) != nil)")
            XCTAssertGreaterThan(renewed[2], 180, "The actual viewer center must contain fresh E2 pixels")
            XCTAssertLessThan(renewed[0], 80, "A healthy E2 viewer must not show an unexpected white retry glyph")
            for _ in 0..<200 {
                if (viewer.displayState.displayedMediaSurface?.image.cgImage?.width ?? 0) >= 2048 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(viewer.displayState.displayedMediaSurface, "The displayed private image must carry its captured proof")
            viewer.requestDismissal()
            let returning = try centerPixel(evidence: "viewer-private-return-before-revocation")
            XCTAssertGreaterThan(returning[2], 150, "The detached return must initially show the current private pixels")
            let revokeStarted = ContinuousClock.now
            deadline.withLock { $0 = "not-a-date" }
            _ = try? await client.authStatus()
            for _ in 0..<30 {
                let color = try centerPixel()
                if !(color[2] > 150 && color[0] < 100) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let revoked = try centerPixel(evidence: "viewer-private-return-revoked")
            XCTAssertLessThan(ContinuousClock.now - revokeStarted, .milliseconds(300), "The check must observe the active return animation")
            XCTAssertFalse(revoked[2] > 150 && revoked[0] < 100,
                "The detached return must clear retired private pixels automatically")
        } catch { await finish(); throw error }
        await finish()
    }

    func testStartupSweepWaitsForActualVisibleSurfaces() async throws {
        let bytes = try XCTUnwrap(solidImage(pixels: 640).jpegData(compressionQuality: 0.9))
        let gate = DispatchSemaphore(value: 0), secondStarted = Mutex(false), paths = Mutex<[String]>([])
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path.contains("/thumbnail") else { return .init(status: 503) }
            paths.withLock { $0.append(request.path) }
            if request.path.contains("visible-second") {
                secondStarted.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 15)
            }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "startup-sweep")
        client.confirmMediaAccount("startup-sweep-\(UUID())"); ImageLoader.shared.configure(client: client)
        let coordinator = MediaPresentationCoordinator.shared
        defer { coordinator.cancelCheckpoint(); ImageLoader.shared.configure(client: nil); client.invalidate() }
        func value(_ id: String) -> Asset {
            Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "r1", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        }
        let assets = [value("visible-first"), value("visible-second")]
        let keys = assets.map { MediaPresentationCoordinator.gridKey(asset: $0, client: client, pixels: 416) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let host = try XCTUnwrap(controller.view)
        defer { window.isHidden = true }
        let tiles = [TimelineTileView(frame: .init(x: 20, y: 100, width: 132, height: 132)),
                     TimelineTileView(frame: .init(x: 160, y: 100, width: 132, height: 132))]
        for tile in tiles { host.addSubview(tile) }
        defer { for tile in tiles { tile.removeFromSuperview() } }
        host.layoutIfNeeded() // Initial fixture layout only.
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "startup-sweep",
            sort: "desc", anchor: assets[0].id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: keys, metadata: try JSONEncoder().encode(assets))
        coordinator.checkpoint(snapshot: snapshot, assets: assets, client: client, surfaceProvider: { key in
            guard let index = keys.firstIndex(of: key) else { return nil }
            return tiles[index].checkpointSurface(for: key, client: client)
        })
        ImageLoader.shared.sweepThumbnails(urls: [client.thumbnailURL(assetID: "background-sweep", cacheKey: "r1")])
        for (index, asset) in assets.enumerated() {
            tiles[index].projectImage(asset: asset, source: .init(assetID: asset.id, localIdentifier: nil,
                pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: 0, targetPixelSize: 416)
        }
        for _ in 0..<200 {
            if secondStarted.withLock({ $0 }), tiles[0].checkpointSurface(for: keys[0], client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(secondStarted.withLock { $0 }); XCTAssertNotNil(tiles[0].checkpointSurface(for: keys[0], client: client))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(paths.withLock { $0.contains { $0.contains("background-sweep") } },
            "The sweep must not start while a real visible image is still held")
        gate.signal()
        for _ in 0..<300 {
            if paths.withLock({ $0.contains { $0.contains("background-sweep") } }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(tiles[1].checkpointSurface(for: keys[1], client: client))
        XCTAssertTrue(paths.withLock { $0.contains { $0.contains("background-sweep") } },
            "The sweep must resume after both actual visible images bind")
    }

    func testLaunchAndCacheHitHaveNoPerTileFade() async throws {
        func jpeg(_ color: UIColor) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        }
        let black = try jpeg(.black), white = try jpeg(.white), requests = Mutex(0)
        let server = try LocalHTTPServer { request in
            requests.withLock { $0 += 1 }
            return .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("/black-") ? black : white)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "monochrome-\(UUID())")
        client.confirmMediaAccount("monochrome-\(UUID())"); ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        func value(_ id: String) -> Asset {
            Asset(id: id, ownerId: "fixture", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "monochrome-r1", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        }
        let values = [value("black-\(UUID())"), value("white-\(UUID())")]
        let keys = values.map { MediaPresentationCoordinator.gridKey(asset: $0, client: client, pixels: 416) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .systemRed
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(120))
        func tiles() -> [TimelineTileView] {
            [TimelineTileView(frame: .init(x: 20, y: 100, width: 132, height: 132)),
             TimelineTileView(frame: .init(x: 160, y: 100, width: 132, height: 132))]
        }
        func bind(_ tiles: [TimelineTileView]) {
            for (index, tile) in tiles.enumerated() {
                controller.view.addSubview(tile)
                let asset = values[index]
                tile.projectImage(asset: asset, source: .init(assetID: asset.id, localIdentifier: nil,
                    pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                    client: client, generation: 0, targetPixelSize: 416)
            }
        }
        func rendered(_ tiles: [TimelineTileView], name: String) throws -> [[UInt8]] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            var didRender = false
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                didRender = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(didRender)
            let attachment = XCTAttachment(data: try XCTUnwrap(frame.pngData()), uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            return try tiles.map { tile in
                let point = tile.convert(CGPoint(x: 66, y: 66), to: window)
                let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                return pixel
            }
        }
        func assertMonochrome(_ pixels: [[UInt8]]) {
            XCTAssertTrue(pixels[0].prefix(3).allSatisfy { $0 < 15 }, "A real black photo must remain black")
            XCTAssertTrue(pixels[1].prefix(3).allSatisfy { $0 > 240 }, "A real white photo must remain white")
        }
        let initial = tiles(); bind(initial)
        for _ in 0..<200 {
            if zip(initial, keys).allSatisfy({ $0.0.checkpointSurface(for: $0.1, client: client) != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(zip(initial, keys).allSatisfy { $0.0.checkpointSurface(for: $0.1, client: client) != nil })
        assertMonochrome(try rendered(initial, name: "monochrome-network-window"))
        initial.forEach { $0.removeFromSuperview() }
        let cacheHits = tiles(); bind(cacheHits)
        XCTAssertTrue(zip(cacheHits, keys).allSatisfy { $0.0.checkpointSurface(for: $0.1, client: client) != nil },
            "A cache hit must bind on the same projection")
        assertMonochrome(try rendered(cacheHits, name: "monochrome-cache-hit-first-window"))
        XCTAssertEqual(requests.withLock { $0 }, 2, "The cached projection must not request either image again")
        cacheHits.forEach { $0.removeFromSuperview() }
    }

    func testPeriodTransitionKeepsQualifiedPixelsAndClearsRetiredSource() async throws {
        let userID = "period-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let red = try XCTUnwrap(solidImage(pixels: 1024).jpegData(compressionQuality: 0.9))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: red) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), value = asset()
        let restoreJournal = try MediaContentGenerations.shared.isolatedFixtureRestorer(scopes: [client.mediaDisplayScope])
        var didRestoreJournal = false
        defer { if !didRestoreJournal { try? restoreJournal() } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .blue; window.rootViewController = controller; window.makeKeyAndVisible()
        let motion = PhotoPeriodMotion(), gridMotion = GridMotion(), registry = AssetTileRegistry()
        let tile = TimelineTileView(frame: CGRect(x: 20, y: 100, width: 132, height: 132))
        let card = PeriodPhotoImageView(frame: CGRect(x: 200, y: 330, width: 132, height: 132))
        defer { motion.cancel(); tile.unregister(); window.isHidden = true }
        controller.view.addSubview(tile); controller.view.addSubview(card)
        tile.configure(asset: value, session: session, motion: gridMotion, showsBackupBadge: false,
            targetPixelSize: 416, registry: registry)
        card.configure(asset: value, mode: .months, session: session, motion: motion)
        try await Task.sleep(for: .milliseconds(120))
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        for _ in 0..<200 {
            if tile.checkpointSurface(for: key, client: client) != nil, card.image != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(tile.checkpointSurface(for: key, client: client)); XCTAssertNotNil(card.image)
        func redPixels(_ name: String) throws -> Int {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            var drawn = false
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            let attachment = XCTAttachment(data: try XCTUnwrap(frame.pngData()), uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let cg = try XCTUnwrap(frame.cgImage), width = cg.width, height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return stride(from: 0, to: height, by: 8).reduce(0) { total, y in
                total + stride(from: 0, to: width, by: 8).filter { x in
                    let i = (y * width + x) * 4
                    return pixels[i] > 180 && pixels[i + 2] < 80
                }.count
            }
        }
        motion.begin(assetID: value.id, from: .all, to: .months, gridSource: tile, session: session, reduceMotion: false)
        XCTAssertNotNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        XCTAssertGreaterThan(try redPixels("period-normal-transition"), 100)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        XCTAssertGreaterThan(try redPixels("period-normal-destination"), 100)
        motion.begin(assetID: value.id, from: .months, to: .all, gridSource: tile, session: session, reduceMotion: false)
        motion.arrive(at: tile, mode: .all)
        XCTAssertNotNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        XCTAssertNil(ImageLoader.shared.invalidateSubjects(client: client, subjects: [.remoteAsset(value.id)]))
        ImageLoadRecovery.shared.contentChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(try redPixels("period-retired-transition"), 0, "Retired pixels must leave the real transition window")
        motion.cancel(); tile.unregister(); window.isHidden = true
        try restoreJournal(); didRestoreJournal = true
        await session.logOut(reportRemoteFailure: false)
    }

    #if DEBUG
    func testPeriodForegroundKeepsDisplayedPixelsWhenCacheIsEvicted() async throws {
        let userID = "period-resume-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 1024).jpegData(compressionQuality: 0.9))
        let reads = Mutex(0), gate = DispatchSemaphore(value: 0)
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") {
                if reads.withLock({ $0 += 1; return $0 }) > 1 { _ = gate.wait(timeout: .now() + 15) }
                return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-resume-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), value = asset()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .blue; window.rootViewController = controller; window.makeKeyAndVisible()
        let motion = PhotoPeriodMotion(), card = PeriodPhotoImageView(frame: CGRect(x: 40, y: 150, width: 132, height: 132))
        controller.view.addSubview(card); defer { motion.cancel(); window.isHidden = true }
        card.configure(asset: value, mode: .months, session: session, motion: motion)
        for _ in 0..<200 {
            if card.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let displayed = try XCTUnwrap(card.image), original = try XCTUnwrap(card.preparedSurfaceForMotion())
        func centerPixel(_ name: String) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            var drawn = false
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            let attachment = XCTAttachment(data: try XCTUnwrap(frame.pngData()), uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let point = card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: window)
            let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        let before = try centerPixel("period-resume-before")
        XCTAssertGreaterThan(before[0], 180); XCTAssertLessThan(before[2], 80)
        let url = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
        ImageLoader.shared.evictLoopbackFixture(for: url, targetPixelSize: 900, client: client)
        XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 900))
        let disk = await ImageLoader.shared.diskImage(for: url, targetPixelSize: 900)
        XCTAssertNil(disk); XCTAssertTrue(original.isCurrent())
        ImageLoadRecovery.shared.becameActive()
        try await Task.sleep(for: .milliseconds(200))
        let after = try centerPixel("period-resume-after")
        XCTAssertGreaterThan(after[0], 180, "Foreground must preserve the displayed red pixels while a replacement is unavailable")
        XCTAssertLessThan(after[2], 80)
        XCTAssertTrue(card.image === displayed)
        XCTAssertEqual(reads.withLock { $0 }, 1, "A current bound surface needs no new transfer on ordinary foreground")
        await session.logOut(reportRemoteFailure: false)
    }

    func testPeriodMotionRequiresPixelsThatCoverTheActualCard() async throws {
        let userID = "period-size-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let large = try XCTUnwrap(solidImage(pixels: 1536).jpegData(compressionQuality: 0.9))
        let small = try XCTUnwrap(solidImage(pixels: 32).jpegData(compressionQuality: 0.9))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") {
                return .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("small-period") ? small : large)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-size-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        func fixture(_ id: String) -> Asset {
            Asset(id: id, ownerId: userID, isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "r1", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        }
        let tiny = fixture("small-period"), healthy = fixture("large-period")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .blue; window.rootViewController = controller; window.makeKeyAndVisible()
        let motion = PhotoPeriodMotion()
        let smallCard = PeriodPhotoImageView(frame: CGRect(x: 20, y: 150, width: 132, height: 132))
        let largeCard = PeriodPhotoImageView(frame: CGRect(x: 20, y: 350, width: 358, height: 238))
        controller.view.addSubview(smallCard); controller.view.addSubview(largeCard)
        defer { motion.cancel(); window.isHidden = true }
        smallCard.configure(asset: tiny, mode: .months, session: session, motion: motion)
        let pixels = PhotoPeriodCoverSurface.targetPixels(asset: healthy, size: largeCard.bounds.size,
                                                          scale: window.traitCollection.displayScale)
        XCTAssertGreaterThanOrEqual(pixels, 358 * window.traitCollection.displayScale)
        largeCard.configure(asset: healthy, mode: .months, session: session, motion: motion, targetPixelSize: pixels)
        for _ in 0..<200 {
            if smallCard.image != nil, largeCard.image != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(smallCard.image); XCTAssertNotNil(largeCard.image)
        XCTAssertNil(smallCard.preparedSurfaceForMotion(), "A 32-pixel bitmap cannot qualify for a 132-point card")
        motion.begin(assetID: tiny.id, from: .months, to: .all, gridSource: nil, session: session, reduceMotion: false)
        XCTAssertNil(window.viewWithTag(PhotoPeriodMotion.replicaTag), "Keep the real image visible and use ordinary navigation")
        XCTAssertEqual(smallCard.alpha, 1)
        motion.cancel()
        XCTAssertNotNil(largeCard.preparedSurfaceForMotion())
        XCTAssertEqual(largeCard.preparedSurfaceForMotion()?.key.pixelBucket, Int(pixels))
        motion.begin(assetID: healthy.id, from: .months, to: .all, gridSource: nil, session: session, reduceMotion: false)
        XCTAssertNotNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        var drawn = false
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        let attachment = XCTAttachment(data: try XCTUnwrap(frame.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = "period-size-current-and-motion"; attachment.lifetime = .keepAlways; add(attachment)
        for card in [smallCard, largeCard] {
            let point = card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: window)
            let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(pixel[0], 180); XCTAssertLessThan(pixel[2], 80)
        }
        motion.cancel(); await session.logOut(reportRemoteFailure: false)
    }

    func testDetachedPeriodCardDoesNotRetainItsDecodedImage() async throws {
        let userID = "period-release-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 1024).jpegData(compressionQuality: 0.9))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "period-release-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), value = asset()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible(); defer { window.isHidden = true }
        let motion = PhotoPeriodMotion()
        var card: PeriodPhotoImageView? = PeriodPhotoImageView(frame: CGRect(x: 40, y: 150, width: 132, height: 132))
        controller.view.addSubview(try XCTUnwrap(card))
        card?.configure(asset: value, mode: .months, session: session, motion: motion)
        for _ in 0..<200 {
            if card?.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(card?.preparedSurfaceForMotion())
        weak var releasedView = card
        weak var releasedImage = card?.image
        XCTAssertNotNil(releasedImage)
        let url = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
        ImageLoader.shared.evictLoopbackFixture(for: url, targetPixelSize: 900, client: client)
        XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 900))
        card?.cancelLoad(); card?.removeFromSuperview(); card = nil
        for _ in 0..<100 {
            if releasedView == nil, releasedImage == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(releasedView)
        XCTAssertNil(releasedImage, "An offscreen registry entry must not hold decoded pixels outside the caches")
        await session.logOut(reportRemoteFailure: false)
    }
    #endif

    func testLocalPeriodUsesQualifiedCoveringSurface() async throws {
        let (localID, _) = try await createSurfaceFixture()
        let revision = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        let userID = "local-period-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let server = try LocalHTTPServer { request in
            request.path == "/api/users/me" ? .init(body: user) : .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "local-period", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client)
        var value = asset(); value.localIdentifier = localID; value.localImageVersion = revision
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .blue; window.rootViewController = controller; window.makeKeyAndVisible()
        let motion = PhotoPeriodMotion(), gridMotion = GridMotion(), registry = AssetTileRegistry()
        let tile = TimelineTileView(frame: CGRect(x: 20, y: 100, width: 132, height: 132))
        let card = PeriodPhotoImageView(frame: CGRect(x: 200, y: 330, width: 132, height: 132))
        controller.view.addSubview(tile); controller.view.addSubview(card)
        defer { motion.cancel(); tile.unregister(); window.isHidden = true }
        tile.configure(asset: value, session: session, motion: gridMotion, showsBackupBadge: false,
            targetPixelSize: 416, registry: registry)
        card.configure(asset: value, mode: .months, session: session, motion: motion)
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        for _ in 0..<300 {
            if tile.checkpointSurface(for: key, client: client) != nil, card.preparedSurfaceForMotion() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try XCTUnwrap(card.preparedSurfaceForMotion())
        XCTAssertEqual(surface.localProvenance?.localIdentifier, localID)
        XCTAssertEqual(surface.localProvenance?.modificationRevision, revision)
        XCTAssertNotNil(tile.checkpointSurface(for: key, client: client))
        motion.begin(assetID: value.id, from: .all, to: .months, gridSource: tile, session: session, reduceMotion: false)
        XCTAssertNotNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(window.viewWithTag(PhotoPeriodMotion.replicaTag))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var drawn = false
        let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        let attachment = XCTAttachment(data: try XCTUnwrap(frame.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = "local-period-qualified-destination"; attachment.lifetime = .keepAlways; add(attachment)
        let point = card.convert(CGPoint(x: 66, y: 66), to: window)
        let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 180); XCTAssertLessThan(pixel[2], 80)
        motion.cancel(); tile.unregister(); window.isHidden = true
        await session.logOut(reportRemoteFailure: false)
    }

    func testMemoryPressureKeepsW0BeforeOffscreenHighRes() async throws {
        let client = client("memory-\(UUID())")
        client.confirmMediaAccount("memory-\(UUID())"); ImageLoader.shared.configure(client: client)
        let coordinator = MediaPresentationCoordinator.shared
        defer { coordinator.cancelCheckpoint(); ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let url = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
        let high = client.thumbnailURL(assetID: "offscreen-\(UUID())", size: "preview", cacheKey: "r1")
        ImageLoader.shared.installPrepared(solidImage(pixels: 416), url: url, targetPixelSize: 416, client: client)
        ImageLoader.shared.installPrepared(solidImage(pixels: 1400), url: high, targetPixelSize: 1400, client: client)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let host = try XCTUnwrap(controller.view)
        defer { window.isHidden = true }
        let tile = TimelineTileView(frame: .init(x: 20, y: 100, width: 132, height: 132)); host.addSubview(tile)
        defer { tile.removeFromSuperview() }
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: 416)
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "memory-\(UUID())",
            sort: "desc", anchor: value.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client,
            surfaceProvider: { tile.checkpointSurface(for: $0, client: client) })
        XCTAssertNotNil(tile.checkpointSurface(for: key, client: client))
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: high, targetPixelSize: 1400))
        func renderedPixel(_ name: String) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            var drawn = false
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn, "The appeared window must actually render")
            if let data = frame.pngData() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
            let point = tile.convert(CGPoint(x: 66, y: 66), to: window)
            let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        let before = try renderedPixel("memory-pressure-before")
        XCTAssertGreaterThan(before[0], 180); XCTAssertLessThan(before[2], 80)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(ImageLoader.shared.cachedImage(for: high, targetPixelSize: 1400), "Offscreen high-resolution memory should be released")
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 416)?.cgImage, "W0 must remain in the bounded cache")
        XCTAssertNotNil(tile.checkpointSurface(for: key, client: client)?.image.cgImage, "Mounted W0 must retain its real image")
        let after = try renderedPixel("memory-pressure-after")
        XCTAssertGreaterThan(after[0], 180); XCTAssertLessThan(after[2], 80)
    }

    /// The picture moves toward its grid cell; the window center legitimately
    /// becomes background during a healthy return. Sample the actual presented
    /// picture rectangle and pixels from the same Core Animation presentation.
    private func returnTransitionPixel(in window: UIWindow, evidence: String) throws -> [UInt8] {
        func imageViews(in view: UIView) -> [AssetViewerBoundImageView] {
            (view as? AssetViewerBoundImageView).map { [$0] } ?? view.subviews.flatMap { imageViews(in: $0) }
        }
        let view = try XCTUnwrap(imageViews(in: window).last, "A normal return must carry the bound picture")
        let layer = try XCTUnwrap(view.layer.presentation(), "Capture a committed animation frame")
        let root = try XCTUnwrap(window.layer.presentation())
        let rectangle = layer.convert(layer.bounds, to: root)
        XCTAssertGreaterThan(rectangle.width, 0); XCTAssertTrue(rectangle.intersects(window.bounds))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            root.render(in: context.cgContext)
        }
        if let data = frame.pngData() {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = evidence; attachment.lifetime = .keepAlways; add(attachment)
        }
        let sample = try XCTUnwrap(frame.cgImage?.cropping(to: CGRect(x: floor(rectangle.midX), y: floor(rectangle.midY), width: 1, height: 1)))
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return result
    }

    func testGridAndViewerReusePreparedLocalImage() async throws {
        let (localID, _) = try await createSurfaceFixture()
        let revision = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        let userID = "local-viewer-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let server = try LocalHTTPServer { request in
            request.path == "/api/users/me" ? .init(body: user) : .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "local-viewer", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client)
        var value = asset(); value.localIdentifier = localID; value.localImageVersion = revision
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let root = try XCTUnwrap(window.rootViewController), parent = UIViewController()
        parent.view.backgroundColor = .darkGray; parent.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in root.present(parent, animated: false) { continuation.resume() } }
        let registry = AssetTileRegistry(), original = TimelineTileView(frame: .init(x: 40, y: 150, width: 132, height: 132))
        parent.view.addSubview(original)
        original.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
        parent.view.layoutIfNeeded()
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        for _ in 0..<200 {
            if original.checkpointSurface(for: key, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(original.checkpointSurface(for: key, client: client))
        let slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        let presentation = ViewerPresentation(), route = try XCTUnwrap(presentation.makeRoute(assets: [value], initialIndex: 0))
        var didPresent = false
        let viewer = AssetViewerHostingController(route: route, startsAsContextPreview: false, previewBounds: window.bounds.size,
            session: session, sourceRegistry: registry, album: nil, personID: nil,
            willPresent: { presentation.activate($0, presentsCover: false) }, didPresent: { _ in didPresent = true },
            didDismiss: { presentation.complete($0) }, onChange: { _ in })
        var destination: TimelineTileView?
        func finish() async {
            for permit in held { await slots.release(permit) }; held.removeAll()
            viewer.requestDismissal()
            for _ in 0..<200 {
                if parent.presentedViewController == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            original.unregister(); original.removeFromSuperview()
            destination?.unregister(); destination?.removeFromSuperview()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        func pixel(_ point: CGPoint, evidence: String? = nil) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            if let evidence, let data = frame.pngData() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = evidence; attachment.lifetime = .keepAlways; add(attachment)
            }
            let cg = try XCTUnwrap(frame.cgImage)
            let sample = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
            var result = [UInt8](repeating: 0, count: 4)
            result.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return result
        }
        do {
            viewer.presentDirectly(from: parent)
            for _ in 0..<300 {
                if didPresent, viewer.displayState.displayedMediaSurface?.key.pixelBucket == 416 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let displayed = try XCTUnwrap(viewer.displayState.displayedMediaSurface,
                "The viewer must bind the grid-sized PhotoKit image while its larger request is held")
            XCTAssertEqual(displayed.key.pixelBucket, 416)
            let image = try pixel(CGPoint(x: window.bounds.midX + 80, y: window.bounds.midY), evidence: "local-viewer-from-grid")
            XCTAssertGreaterThan(image[0], 180); XCTAssertLessThan(image[2], 80)
            original.unregister(); original.recycle()
            XCTAssertTrue(displayed.isCurrent(), "The viewer proof must survive recycling the source tile")
            let next = TimelineTileView(frame: .init(x: 40, y: 150, width: 132, height: 132)); destination = next
            parent.view.addSubview(next)
            next.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            for _ in 0..<100 {
                if next.checkpointSurface(for: key, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(next.checkpointSurface(for: key, client: client))
            viewer.requestDismissal()
            try await Task.sleep(for: .milliseconds(35))
            let transition = try returnTransitionPixel(in: window, evidence: "local-viewer-return")
            XCTAssertGreaterThan(transition[0], 150); XCTAssertLessThan(transition[2], 100)
            try await Task.sleep(for: .milliseconds(450))
            let final = try pixel(CGPoint(x: 106, y: 216), evidence: "local-viewer-return-grid")
            XCTAssertGreaterThan(final[0], 150); XCTAssertLessThan(final[2], 100)
        } catch { await finish(); throw error }
        await finish()
    }

    func testPhotoKitPreheatMatchesActualRequestOptions() async throws {
        let (localID, _) = try await createSurfaceFixture()
        let manager = RecordingPhotoKitManager(), loader = LocalImageLoader.fixture(manager: manager)
        let scope = "shared-\(UUID())", first = UUID(), second = UUID()
        let slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        loader.startCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: first)
        loader.startCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: second)
        try await Task.sleep(for: .milliseconds(250))
        let visible = Task { await loader.image(localIdentifier: localID, targetPixelSize: 416,
            contentMode: .aspectFit, coversTarget: true, allowsNetwork: false, cacheScope: scope) }
        try await Task.sleep(for: .milliseconds(250))
        loader.stopCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: first)
        for permit in held { await slots.release(permit) }; held.removeAll()
        let image = await visible.value
        XCTAssertNotNil(image?.cgImage, "A visible consumer must survive another owner's cancellation")
        for _ in 0..<100 {
            if manager.requests.withLock({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.requests.withLock { $0.count }, 1, "The two preheats and visible request must share one actual PhotoKit request")
        let control = await loader.image(localIdentifier: localID, targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScope: "control-\(UUID())")
        XCTAssertNotNil(control?.cgImage)
        let requests = manager.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 2)
        if requests.count == 2 {
            XCTAssertEqual(requests[0], requests[1], "Preheat and visible PhotoKit requests must use the same manager, target and options")
            XCTAssertEqual(requests[0].target, CGSize(width: 416, height: 416))
            XCTAssertEqual(requests[0].mode, PHImageContentMode.aspectFit.rawValue)
            XCTAssertEqual(requests[0].delivery, PHImageRequestOptionsDeliveryMode.opportunistic.rawValue)
            XCTAssertEqual(requests[0].resize, PHImageRequestOptionsResizeMode.fast.rawValue)
            XCTAssertFalse(requests[0].allowsNetwork)
        }
        loader.stopCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: second)
    }

    func testCancellingOneLocalPreheatKeepsOtherOwner() async throws {
        let (localID, _) = try await createSurfaceFixture()
        let manager = RecordingPhotoKitManager(), loader = LocalImageLoader.fixture(manager: manager)
        let scope = "owners-\(UUID())", first = UUID(), second = UUID(), slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        for owner in [first, second] {
            loader.startCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
                coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: owner)
        }
        try await Task.sleep(for: .milliseconds(250))
        loader.stopCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: first)
        try await Task.sleep(for: .milliseconds(100))
        for permit in held { await slots.release(permit) }; held.removeAll()
        for _ in 0..<200 {
            if loader.cachedImage(localIdentifier: localID, targetPixelSize: 416,
                contentMode: .aspectFit, coversTarget: true, cacheScope: scope) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(loader.cachedImage(localIdentifier: localID, targetPixelSize: 416,
            contentMode: .aspectFit, coversTarget: true, cacheScope: scope)?.cgImage,
            "The remaining owner must receive the actual PhotoKit image")
        XCTAssertEqual(manager.requests.withLock { $0.count }, 1)
        loader.stopCaching(localIdentifiers: [localID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [localID: scope], ownerID: second)
    }

    func testVisibleLocalDemandPromotesQueuedPreheat() async throws {
        let (olderID, _) = try await createSurfaceFixture(), (visibleID, _) = try await createSurfaceFixture()
        let manager = RecordingPhotoKitManager(), loader = LocalImageLoader.fixture(manager: manager)
        let olderScope = "older-\(UUID())", visibleScope = "visible-\(UUID())"
        let first = UUID(), second = UUID(), slots = ThumbnailLoadLimiter.shared
        var held: [UUID] = []
        for _ in 0..<4 { held.append(try await slots.acquire()) }
        defer { Task { for permit in held { await slots.release(permit) } } }
        loader.startCaching(localIdentifiers: [olderID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [olderID: olderScope], ownerID: first)
        try await Task.sleep(for: .milliseconds(250))
        loader.startCaching(localIdentifiers: [visibleID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [visibleID: visibleScope], ownerID: second)
        try await Task.sleep(for: .milliseconds(250))
        let visible = Task { await loader.image(localIdentifier: visibleID, targetPixelSize: 416,
            contentMode: .aspectFit, coversTarget: true, allowsNetwork: false, cacheScope: visibleScope) }
        try await Task.sleep(for: .milliseconds(250))
        await slots.release(held.removeFirst())
        for _ in 0..<200 {
            if manager.requests.withLock({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.requests.withLock { $0.first?.assetID }, visibleID,
            "The visible subscriber must promote its queued PhotoKit producer")
        for permit in held { await slots.release(permit) }; held.removeAll()
        let image = await visible.value
        XCTAssertNotNil(image?.cgImage)
        loader.stopCaching(localIdentifiers: [olderID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [olderID: olderScope], ownerID: first)
        loader.stopCaching(localIdentifiers: [visibleID], targetPixelSize: 416, contentMode: .aspectFit,
            coversTarget: true, allowsNetwork: false, cacheScopes: [visibleID: visibleScope], ownerID: second)
    }

    func testViewerReturnCarriesDisplayedPixelsIntoUnreadyDestination() async throws {
        try await assertViewerReturn(asset: asset())
    }

    func testVideoAndLivePhotoPostersCarryTheirDisplayedReturnSurface() async throws {
        func poster(isImage: Bool, motionID: String?) -> Asset {
            Asset(id: "same-id", ownerId: "alice", isImage: isImage, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: isImage ? nil : 2000, livePhotoVideoId: motionID, ratio: 1, city: nil, country: nil)
        }
        try await assertViewerReturn(asset: poster(isImage: false, motionID: nil))
        try await assertViewerReturn(asset: poster(isImage: true, motionID: "synthetic-motion"))
    }

    func testEditedPairedViewerReturnsCurrentRemoteImage() async throws {
        let (localID, _) = try await createSurfaceFixture()
        let revision = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        var edited = asset(); edited.isEdited = true
        try await assertViewerReturn(asset: edited, stalePair: (localID, revision))
    }

    private func assertViewerReturn(asset value: Asset, stalePair: (String, String)? = nil) async throws {
        let userID = "viewer-return-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 2048), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let previewRead = Mutex(false)
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") {
                if request.path.contains("size=preview") { previewRead.withLock { $0 = true } }
                return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
            }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "viewer-return", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client)
        if let stalePair {
            session.backup?.adoptLaunchSelections([.init(localIdentifier: stalePair.0,
                modificationRevision: stalePair.1, remoteIdentifier: value.id)])
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let root = try XCTUnwrap(window.rootViewController), parent = UIViewController()
        parent.view.backgroundColor = .darkGray; parent.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            root.present(parent, animated: false) { continuation.resume() }
        }
        let registry = AssetTileRegistry(), original = TimelineTileView(frame: .init(x: 40, y: 150, width: 132, height: 132))
        parent.view.addSubview(original)
        original.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
        parent.view.layoutIfNeeded() // Initial fixture layout only.
        let originalKey = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        for _ in 0..<200 {
            if original.checkpointSurface(for: originalKey, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(original.checkpointSurface(for: originalKey, client: client))
        let presentation = ViewerPresentation(), route = try XCTUnwrap(presentation.makeRoute(assets: [value], initialIndex: 0))
        var didPresent = false
        let viewer = AssetViewerHostingController(route: route, startsAsContextPreview: false, previewBounds: window.bounds.size,
            session: session, sourceRegistry: registry, album: nil, personID: nil,
            willPresent: { presentation.activate($0, presentsCover: false) }, didPresent: { _ in didPresent = true },
            didDismiss: { presentation.complete($0) }, onChange: { _ in })
        var destination: TimelineTileView?
        func finish() async {
            viewer.requestDismissal()
            for _ in 0..<200 {
                if parent.presentedViewController == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            original.unregister(); original.removeFromSuperview()
            destination?.unregister(); destination?.removeFromSuperview()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parent.dismiss(animated: false) { continuation.resume() }
            }
            await session.logOut(reportRemoteFailure: false)
        }
        func pixel(_ point: CGPoint, evidence: String? = nil) throws -> [UInt8] {
            let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            if let evidence, let data = frame.pngData() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = evidence; attachment.lifetime = .keepAlways; add(attachment)
            }
            let cg = try XCTUnwrap(frame.cgImage)
            let sample = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
            var result = [UInt8](repeating: 0, count: 4)
            result.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return result
        }
        do {
            viewer.presentDirectly(from: parent)
            for _ in 0..<300 {
                if didPresent, previewRead.withLock({ $0 }),
                   (viewer.displayState.displayedMediaSurface?.image.cgImage?.width ?? 0) >= 2048 {
                    let color = try pixel(CGPoint(x: window.bounds.midX + 80, y: window.bounds.midY))
                    if color[2] > 180 && color[0] < 80 { break }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(didPresent); XCTAssertTrue(previewRead.withLock { $0 })
            let displayed = try pixel(CGPoint(x: window.bounds.midX + 80, y: window.bounds.midY), evidence: "viewer-return-before")
            XCTAssertGreaterThan(displayed[2], 180); XCTAssertLessThan(displayed[0], 80)
            original.unregister(); original.removeFromSuperview()
            let next = TimelineTileView(frame: .init(x: 40, y: 150, width: 132, height: 132)); destination = next
            parent.view.addSubview(next)
            next.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 800, registry: registry)
            let nextKey = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 800)
            XCTAssertNil(next.checkpointSurface(for: nextKey, client: client), "The destination starts without its matching decoded surface")
            viewer.requestDismissal()
            XCTAssertNotNil(next.checkpointSurface(for: nextKey, client: client),
                "The destination must bind the qualified displayed surface before the viewer detaches")
            try await Task.sleep(for: .milliseconds(35))
            let transition = try returnTransitionPixel(in: window, evidence: "viewer-return-transition")
            XCTAssertGreaterThan(transition[2], 150, "The detached transition must show the actual blue viewer pixels")
            XCTAssertLessThan(transition[0], 100)
            try await Task.sleep(for: .milliseconds(450))
            let final = try pixel(CGPoint(x: 106, y: 216), evidence: "viewer-return-grid")
            XCTAssertGreaterThan(final[2], 150, "Finishing the transition must reveal the prepared destination image")
            XCTAssertLessThan(final[0], 100)
        } catch { await finish(); throw error }
        await finish()
    }

    func testEditedPairedSwiftUITileShowsCurrentRemotePixels() async throws {
        let (localID, original) = try await createSurfaceFixture()
        let localRevision = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        let userID = "edited-pair-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        let blueBytes = try XCTUnwrap(blue.jpegData(compressionQuality: 0.9))
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: blueBytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "edited-pair", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), backup = try XCTUnwrap(session.backup)
        var value = asset(); value.isEdited = true
        // Model a still-mounted pairing map racing a remote edit; this does not
        // create or modify a backup proof or any external asset.
        backup.adoptLaunchSelections([.init(localIdentifier: localID, modificationRevision: localRevision, remoteIdentifier: value.id)])
        let scope = AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey, version: value.thumbhash, pixels: 416)
        LocalImageLoader.shared.installPrepared(original, localIdentifier: localID, targetPixelSize: 416,
            cacheScope: scope, permission: LocalImageLoader.shared.permissionGeneration)
        let root = AssetTile(asset: value, targetPixelSize: 416).frame(width: 132, height: 132).environment(session)
        let host = UIHostingController(rootView: root)
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        host.view.layoutIfNeeded()
        func pixel() throws -> [UInt8] {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let point = CGRect(x: host.view.bounds.midX.rounded(.down), y: host.view.bounds.midY.rounded(.down), width: 1, height: 1)
            let crop = try XCTUnwrap(cg.cropping(to: point))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        do {
            for _ in 0..<200 {
                let color = try pixel()
                if color[2] > 180 && color[0] < 80 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let displayed = try pixel()
            XCTAssertGreaterThan(displayed[2], 180, "A current remote edit must display its blue endpoint render")
            XCTAssertLessThan(displayed[0], 80, "The old red paired local original must not replace the committed remote edit")
            XCTAssertTrue(server.received.contains { $0.path.contains("/thumbnail") })
        } catch {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false); throw error
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
        await session.logOut(reportRemoteFailure: false)
    }

    func testNewerStatusIssuedBeforeInvalidAcceptanceGrantsNewProducer() async throws {
        let invalidGate = DispatchSemaphore(value: 0), newerGate = DispatchSemaphore(value: 0)
        let reads = Mutex(0), held = Mutex<CheckedContinuation<Void, Never>?>(nil), reached = Mutex(false)
        let server = try LocalHTTPServer(concurrent: true) { request in
            guard request.path == "/api/auth/status" else { return .init(status: 503) }
            let number = reads.withLock { $0 += 1; return $0 }
            if number == 2 { _ = invalidGate.wait(timeout: .now() + 20) }
            if number == 3 { _ = newerGate.wait(timeout: .now() + 20) }
            let expiry = number == 2 ? "not-a-date" : "2099-01-01T00:00:00Z"
            return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(expiry)\"}".utf8))
        }
        try await server.start(); defer { invalidGate.signal(); newerGate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "preissued-status")
        client.confirmMediaAccount("preissued-status-\(UUID())")
        ImageLoader.shared.configure(client: client)
        func releaseStatus() { held.withLock { value in let continuation = value; value = nil; return continuation }?.resume() }
        defer { releaseStatus(); client.setInvalidStatusFixtureHook(nil); client.invalidate(); ImageLoader.shared.configure(client: nil) }
        _ = try await client.authStatus()
        let oldLease = try XCTUnwrap(client.lockedMediaLease)
        client.setInvalidStatusFixtureHook {
            await withCheckedContinuation { continuation in
                held.withLock { $0 = continuation }; reached.withLock { $0 = true }
            }
        }
        let invalid = Task { try await client.authStatus() }
        for _ in 0..<200 {
            if reads.withLock({ $0 }) >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reads.withLock({ $0 }) == 2 else { XCTFail("The invalid status must be in flight first"); throw CocoaError(.fileReadUnknown) }
        let newer = Task { try await client.authStatus() }
        for _ in 0..<200 {
            if reads.withLock({ $0 }) >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reads.withLock({ $0 }) == 3 else { XCTFail("The newer status must be issued before invalid acceptance"); throw CocoaError(.fileReadUnknown) }
        invalidGate.signal()
        for _ in 0..<200 {
            if reached.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reached.withLock({ $0 }) else { XCTFail("The invalid response must be accepted before the newer response"); throw CocoaError(.fileReadUnknown) }
        XCTAssertNil(client.lockedMediaLease); XCTAssertFalse(oldLease.isCurrent)
        newerGate.signal()
        _ = try await newer.value
        let newLease = try XCTUnwrap(client.lockedMediaLease)
        XCTAssertTrue(newLease.isCurrent)
        XCTAssertNotEqual(oldLease.identity, newLease.identity)
        XCTAssertFalse(oldLease.isCurrent, "A later accepted status cannot revive an earlier producer")
        client.rejectLockedMediaLease(oldLease) // A delayed E1 endpoint 401/403 must not reject E2.
        XCTAssertTrue(newLease.isCurrent, "A late rejection belonging to E1 cannot revoke E2")
        releaseStatus()
        do { _ = try await invalid.value; XCTFail("The superseded invalid completion must be discarded") }
        catch is CancellationError { }
        XCTAssertTrue(newLease.isCurrent)
    }

    func testAwakenedOldExpiryCannotRevokeNewLeaseAndCurrentExpiryClearsMountedBytes() async throws {
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil), woke = Mutex(false)
        let deadline = Mutex("2099-01-01T00:00:00Z")
        let userID = "expiry-renewal-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 528).jpegData(compressionQuality: 0.87))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" { return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline.withLock { $0 })\"}".utf8)) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "expiry-renewal", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        func releaseExpiry() { held.withLock { value in let continuation = value; value = nil; return continuation }?.resume() }
        defer { releaseExpiry(); client.setExpiryFixtureHook(nil) }
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let publicTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(publicTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister(); publicTile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            _ = try await client.authStatus() // Leave the folder timer unarmed until the gated callback has awakened.
            var value = asset(); value.visibility = .locked
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            publicTile.configure(asset: publicAsset, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            for _ in 0..<200 {
                if tile.checkpointSurface(for: key, client: client) != nil && publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            client.setExpiryFixtureHook {
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                    woke.withLock { $0 = true }
                }
            }
            deadline.withLock { $0 = Date().addingTimeInterval(2.5).ISO8601Format() }
            _ = try await client.authStatus()
            for _ in 0..<400 {
                if woke.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard woke.withLock({ $0 }) else { XCTFail("The old expiry must wake and pause before the newer status"); throw CocoaError(.fileReadUnknown) }
            client.setExpiryFixtureHook(nil)
            let newText = Date().addingTimeInterval(4).ISO8601Format()
            let newDeadline = try XCTUnwrap(APIDate.parse(newText))
            deadline.withLock { $0 = newText }
            await locked.refreshStatus()
            XCTAssertEqual(client.lockedMediaLease?.deadline, newDeadline)
            XCTAssertEqual(locked.elevatedUntil, newDeadline)
            releaseExpiry()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(client.lockedMediaLease?.deadline, newDeadline, "An awakened old expiry cannot revoke the renewed lease")
            XCTAssertTrue(locked.isUnlocked); XCTAssertTrue(oldSurface.isCurrent())
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
            while Date() < newDeadline.addingTimeInterval(0.6) { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(client.lockedMediaLease); XCTAssertFalse(locked.isUnlocked)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "The current expiry still clears the mounted private UIImage")
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertNotNil((publicTile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
        } catch { releaseExpiry(); await finish(); throw error }
        await finish()
    }
    #endif

    func testStatusDuringFailedExplicitLockCannotReopenMountedPrivateImage() async throws {
        let gate = DispatchSemaphore(value: 0), lockStarted = Mutex(false)
        let userID = "pending-lock-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 528).jpegData(compressionQuality: 0.87))
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" { return .init(body: Data(#"{"isElevated":true,"pinCode":true,"password":true,"pinExpiresAt":"2099-01-01T00:00:00Z"}"#.utf8)) }
            if request.path == "/api/auth/session/lock" {
                lockStarted.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 10)
                return .init(status: 503)
            }
            if request.path == "/api/auth/session/unlock" { return .init() }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "pending-lock", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let publicTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(publicTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister(); publicTile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            var value = asset(); value.visibility = .locked
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            publicTile.configure(asset: publicAsset, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            await locked.refreshStatus()
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            for _ in 0..<200 {
                if tile.checkpointSurface(for: key, client: client) != nil && publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            let oldLease = try XCTUnwrap(client.lockedMediaLease)
            locked.lock()
            for _ in 0..<200 {
                if lockStarted.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(lockStarted.withLock { $0 }, "The status must begin after the lock POST has started")
            do { _ = try await client.authStatus() } catch { }
            XCTAssertNil(client.lockedMediaLease, "An independent status cannot grant a lease while explicit lock is pending")
            XCTAssertFalse(oldLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
            gate.signal()
            await locked.refreshStatus() // awaits the failed lock POST before trying a fresh status
            XCTAssertNil(client.lockedMediaLease, "A failed lock POST cannot silently regrant private authority")
            XCTAssertFalse(locked.isUnlocked)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
            try await locked.unlock(pin: "123456")
            for _ in 0..<200 {
                if (tile.makeZoomReplica() as? UIImageView)?.image != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(locked.isUnlocked); XCTAssertNotNil(client.lockedMediaLease)
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image?.cgImage, "A new confirmed explicit unlock may renew the mounted producer")
            XCTAssertFalse(oldLease.isCurrent); XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertNotNil((publicTile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
        } catch { gate.signal(); await finish(); throw error }
        await finish()
    }

    private func checkOverlappingStatusDeadline(newerUsesClient: Bool) async throws {
        let gate = DispatchSemaphore(value: 0), reads = Mutex(0), shortText = Mutex("")
        let userID = "overlapping-status-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let privateBytes = try XCTUnwrap(solidImage(pixels: 528).jpegData(compressionQuality: 0.87))
        let publicBytes = try XCTUnwrap(solidImage(pixels: 544).jpegData(compressionQuality: 0.87))
        let server = try LocalHTTPServer(concurrent: true) { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/auth/status" {
                let number = reads.withLock { $0 += 1; return $0 }
                if number == 2 { _ = gate.wait(timeout: .now() + 10) }
                let deadline = number == 3 ? shortText.withLock { $0 } : "2099-01-01T00:00:00Z"
                return .init(body: Data("{\"isElevated\":true,\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"\(deadline)\"}".utf8))
            }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data(#"[{"timeBucket":"2023-11-01T00:00:00Z","count":1}]"#.utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("public-id") ? publicBytes : privateBytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "overlap-status", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client), locked = try XCTUnwrap(session.lockedFolder)
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let publicTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(publicTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister(); publicTile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            var value = asset(); value.visibility = .locked
            let publicAsset = Asset(id: "public-id", ownerId: "alice", isImage: true, isFavorite: false, isTrashed: false,
                visibility: .timeline, thumbhash: "revision-one", fileCreatedAt: .now, localOffsetHours: 0,
                duration: nil, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            ImageLoader.shared.markEphemeral(assetIDs: [value.id])
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            publicTile.configure(asset: publicAsset, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            await locked.refreshStatus()
            let model = TimelineModel(filter: TimelineFilter(visibility: .locked)); model.attach(client); await model.load()
            let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let publicKey = MediaPresentationCoordinator.gridKey(asset: publicAsset, client: client, pixels: 416)
            for _ in 0..<200 {
                if tile.checkpointSurface(for: key, client: client) != nil && publicTile.checkpointSurface(for: publicKey, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let oldSurface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
            let publicSurface = try XCTUnwrap(publicTile.checkpointSurface(for: publicKey, client: client))
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
            let privateURL = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
            let diskImage = await ImageLoader.shared.diskImage(for: privateURL, targetPixelSize: 416)
            XCTAssertNil(diskImage)

            let text = Date().addingTimeInterval(4).ISO8601Format()
            let deadline = try XCTUnwrap(APIDate.parse(text))
            shortText.withLock { $0 = text }
            let older = Task { await locked.refreshStatus() }
            for _ in 0..<200 {
                if reads.withLock({ $0 }) >= 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(reads.withLock { $0 }, 2, "The old request must be held before the newer request starts")
            if newerUsesClient { _ = try await client.authStatus() } else { await locked.refreshStatus() }
            for _ in 0..<100 {
                if locked.elevatedUntil == deadline { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(client.lockedMediaLease?.deadline, deadline)
            XCTAssertEqual(locked.elevatedUntil, deadline, "A status from either caller must synchronize the folder timer")
            gate.signal(); await older.value
            XCTAssertEqual(client.lockedMediaLease?.deadline, deadline, "An older same-nonce response cannot extend the newer confirmed deadline")
            XCTAssertEqual(locked.elevatedUntil, deadline)
            while Date() < deadline.addingTimeInterval(0.6) { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(client.lockedMediaLease)
            XCTAssertFalse(locked.isUnlocked)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "The mounted private UIImage must clear at the newer deadline")
            XCTAssertFalse(oldSurface.isCurrent())
            XCTAssertTrue(publicKey.isCurrentContent); XCTAssertTrue(publicSurface.isCurrent())
            XCTAssertNotNil((publicTile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
        } catch { gate.signal(); await finish(); throw error }
        await finish()
    }

    private func checkLockedRecovery(rollbackFromLockedPage: Bool) async throws {
        let elevated = Mutex(false), month = "2023-11-01T00:00:00.000Z"
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["locked"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let detail = Data(#"{"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg","thumbhash":"revision-one","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z","isFavorite":false,"isTrashed":false,"visibility":"locked"}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/auth/session/unlock" { elevated.withLock { $0 = true }; return .init() }
            if request.path == "/api/auth/session/lock" { elevated.withLock { $0 = false }; return .init() }
            if request.path == "/api/auth/status" {
                return .init(body: Data("{\"isElevated\":\(elevated.withLock { $0 }),\"pinCode\":true,\"password\":true,\"pinExpiresAt\":\"2099-01-01T00:00:00.000Z\"}".utf8))
            }
            if request.method == "PUT" { return .init(status: rollbackFromLockedPage ? 400 : 200) }
            guard elevated.withLock({ $0 }) else { return .init(status: 403) }
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            if request.path == "/api/assets/same-id" { return .init(body: detail) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "locked-fixture-\(UUID())")
        client.confirmMediaAccount("locked-fixture-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let locked = LockedFolderSession(client: client)
        defer { locked.shutdown() }
        var value = asset(); value.visibility = rollbackFromLockedPage ? .locked : .timeline
        let source = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
        source.suppliedLaunchContext = "locked-fixture"; source.attach(client)
        if !rollbackFromLockedPage {
            let removal = source.removeAssetsForOptimisticAction(ids: [value.id])
            try await client.setVisibility(ids: [value.id], .locked)
            source.commit(removal)
        }
        try await locked.unlock(pin: "123456")
        XCTAssertTrue(locked.isUnlocked)
        let model: TimelineModel
        if rollbackFromLockedPage {
            model = TimelineModel(filter: TimelineFilter(visibility: .locked), suppliedAssets: [value])
            model.suppliedLaunchContext = "locked-rollback-fixture"; model.attach(client)
            var removal: TimelineRemoval?
            let outcome: Void? = await OptimisticAction.perform(errorMessage: "locked fixture", apply: {
                removal = model.removeAssetsForOptimisticAction(ids: [value.id])
            }, rollback: { if let removal { model.restore(removal) } },
                request: { try await client.setVisibility(ids: [value.id], .timeline) }, reportFailure: { _, _ in })
            XCTAssertNil(outcome)
        } else {
            model = TimelineModel(filter: TimelineFilter(visibility: .locked))
            model.attach(client); await model.load()
        }
        for _ in 0..<100 {
            if let current = model.sections.flatMap({ $0.days?.flatMap(\.assets) ?? [] }).first,
               MediaPresentationCoordinator.gridKey(asset: current, client: client, pixels: 416).isCurrentContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let canonical = try XCTUnwrap(model.sections.flatMap { $0.days?.flatMap(\.assets) ?? [] }.first,
            "A current authorized locked rollback must retain its row")
        XCTAssertEqual(canonical.visibility, .locked)
        let key = MediaPresentationCoordinator.gridKey(asset: canonical, client: client, pixels: 416)
        XCTAssertTrue(key.isCurrentContent)
        do {
            let url = client.thumbnailURL(assetID: canonical.id, cacheKey: canonical.thumbhash)
            let image = try await ImageLoader.shared.image(for: url, targetPixelSize: 416)
            XCTAssertNotNil(image.cgImage)
        } catch { XCTFail("Current PIN plus canonical locked response could not decode: \(type(of: error)): \(error)") }
    }

    func testPairNamespaceRetirementAfterSavedPackStillBindsCurrentRemoteRevision() async throws {
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "pair-retirement-\(UUID())")
        client.confirmMediaAccount("pair-retirement-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), pixels: CGFloat = 416
        let snapshot = try await makeSavedPack(client: client)
        let previous = try XCTUnwrap(snapshot.visibleKeys.first)
        XCTAssertTrue(previous.isCurrentContent)
        XCTAssertNil(ImageLoader.shared.invalidateSubjects(client: client, subjects: [previous.subject], retiresSourceRevisions: false))
        let current = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: pixels)
        XCTAssertNotEqual(current.contentGeneration, previous.contentGeneration)
        XCTAssertFalse(previous.isCurrentContent, "The replaced pairing's captured producer must stay retired")
        XCTAssertTrue(current.isCurrentContent, "A saved latest.json must respect namespace-only retirement of the unchanged remote revision")
        let restarted = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
        XCTAssertEqual(restarted.current(scope: current.scope, subject: current.subject), current.contentGeneration)
        XCTAssertFalse(restarted.isRetired(scope: current.scope, subject: current.subject, sourceRevision: current.sourceRevision))
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: pixels)
        for _ in 0..<150 {
            if tile.checkpointSurface(for: current, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try XCTUnwrap(tile.checkpointSurface(for: current, client: client))
        XCTAssertNil(surface.localProvenance)
        XCTAssertGreaterThanOrEqual(min(surface.image.size.width, surface.image.size.height) * surface.image.scale, pixels)
        XCTAssertTrue(server.received.contains { $0.path.contains("/thumbnail") })
    }

    func testFailedVisibilityRemovalRollsBackRealModelAndBindsSameRevisionAfterCurrentReadback() async throws {
        let value = asset()
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let detail = Data("""
        {"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg",
        "thumbhash":"revision-one","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z",
        "isFavorite":false,"isTrashed":false,"visibility":"timeline","width":512,"height":512}
        """.utf8)
        let server = try LocalHTTPServer { request in
            if request.method == "PUT" { return .init(status: 400, body: Data("{\"message\":\"rejected fixture mutation\"}".utf8)) }
            if request.path == "/api/assets/same-id" { return .init(headers: ["Content-Type": "application/json"], body: detail) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "rollback-\(UUID())")
        client.confirmMediaAccount("rollback-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
        model.suppliedLaunchContext = "real-removal-fixture"
        model.attach(client)
        let old = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        var removal: TimelineRemoval?
        let outcome: Void? = await OptimisticAction.perform(errorMessage: "fixture failure", apply: {
            removal = model.removeAssetsForOptimisticAction(ids: [value.id])
            XCTAssertTrue(model.sections.flatMap { $0.days?.flatMap(\.assets) ?? [] }.isEmpty)
        }, rollback: { if let removal { model.restore(removal) } },
            request: { try await client.setVisibility(ids: [value.id], .archive) }, reportFailure: { _, _ in })
        XCTAssertNil(outcome)
        XCTAssertEqual(model.sections.flatMap { $0.days?.flatMap(\.assets) ?? [] }, [value], "Actual failed action rollback restores the same metadata and placement")
        let confirmed = try await client.assetDetail(id: value.id)
        XCTAssertEqual(confirmed.visibility, .timeline)
        XCTAssertEqual(confirmed.thumbhash, value.thumbhash)
        for _ in 0..<150 {
            if MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        XCTAssertFalse(old.isCurrentContent)
        XCTAssertNotEqual(current.contentGeneration, old.contentGeneration)
        XCTAssertTrue(current.isCurrentContent, "A failed visibility action plus fresh authorized readback cannot permanently tombstone unchanged image content")
        let journal = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
        XCTAssertFalse(journal.isRetired(scope: current.scope, subject: current.subject, sourceRevision: current.sourceRevision))
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: 416)
        for _ in 0..<150 {
            if tile.checkpointSurface(for: current, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(tile.checkpointSurface(for: current, client: client))
        XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
        XCTAssertTrue(server.received.contains { $0.method == "PUT" && $0.path == "/api/assets" })
        XCTAssertTrue(server.received.contains { $0.path.contains("/thumbnail") })
        model.commit(try XCTUnwrap(removal))
        XCTAssertTrue(current.isCurrentContent, "A resolved old commit token cannot revoke a successfully rolled-back surface")
        XCTAssertNotNil(tile.checkpointSurface(for: current, client: client))
    }

    func testFreshCanonicalTimelineProducerRecoversRemovedSameRevisionAfterRestart() async throws {
        let month = "2023-11-01T00:00:00.000Z"
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["timeline"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") {
                return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8))
            }
            if request.path.hasPrefix("/api/timeline/bucket?") { return .init(body: payload) }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "canonical-\(UUID())")
        client.confirmMediaAccount("canonical-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let model = TimelineModel(filter: TimelineFilter())
        model.attach(client); await model.load()
        let value = try XCTUnwrap(model.flatAssets.first)
        let before = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        model.removeAssets(ids: [value.id])
        XCTAssertFalse(before.isCurrentContent)
        let restarted = TimelineModel(filter: TimelineFilter())
        restarted.attach(client); await restarted.load()
        await restarted.loadBucket(month, refresh: true)
        XCTAssertGreaterThanOrEqual(server.received.filter { $0.path.hasPrefix("/api/timeline/bucket?") }.count, 2)
        XCTAssertEqual(restarted.flatAssets.map(\.id), [value.id])
        let current = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        XCTAssertTrue(current.isCurrentContent, "A fresh authenticated canonical list must be an actual recovery producer, not only a special rollback detail request")
        XCTAssertFalse(before.isCurrentContent)
        do {
            let image = try await ImageLoader.shared.image(for: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: 416)
            XCTAssertGreaterThanOrEqual(min(image.size.width, image.size.height) * image.scale, 416)
        } catch { XCTFail("Fresh canonical producer could not decode its current endpoint: \(type(of: error)): \(error)") }
        let journal = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
        XCTAssertFalse(journal.isRetired(scope: current.scope, subject: current.subject, sourceRevision: current.sourceRevision))
    }

    func testUnknownArchiveOutcomeCannotReauthorizeRestoredTimelineFromArchiveReadback() async throws {
        let detail = Data(#"{"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg","thumbhash":"revision-one","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z","isFavorite":false,"isTrashed":false,"visibility":"archive"}"#.utf8)
        let server = try LocalHTTPServer { request in
            if request.method == "PUT" { return .init(status: 503) }
            return .init(body: detail)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "unknown-outcome-\(UUID())")
        client.confirmMediaAccount("unknown-outcome-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [asset()])
        model.suppliedLaunchContext = "unknown-outcome-fixture"; model.attach(client)
        var removal: TimelineRemoval?
        let result: Void? = await OptimisticAction.perform(errorMessage: "unknown fixture", apply: {
            removal = model.removeAssetsForOptimisticAction(ids: [value.id])
        }, rollback: { if let removal { model.restore(removal) } },
            request: { try await client.setVisibility(ids: [value.id], .archive) }, reportFailure: { _, _ in })
        XCTAssertNil(result)
        for _ in 0..<150 {
            if model.sections.flatMap({ $0.days?.flatMap(\.assets) ?? [] }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.sections.flatMap { $0.days?.flatMap(\.assets) ?? [] }.isEmpty,
            "Fresh archive authority must replace the stale timeline rollback projection before any image grant")
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
        XCTAssertTrue(server.received.contains { $0.method == "GET" && $0.path == "/api/assets/same-id" })
        XCTAssertFalse(server.received.contains { $0.path.contains("/thumbnail") })
    }

    func testAuthenticatedArchiveProjectionCannotGrantOldTimelineMetadataTheSameSurface() async throws {
        let month = "2023-11-01T00:00:00.000Z"
        let policy = Mutex("archive")
        let payload = Data(#"{"id":["same-id"],"ownerId":["alice"],"isImage":[true],"isFavorite":[false],"isTrashed":[false],"visibility":["archive"],"thumbhash":["revision-one"],"fileCreatedAt":["2023-11-14T00:00:00.000Z"],"localOffsetHours":[0],"duration":[null],"livePhotoVideoId":[null],"ratio":[1]}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path.hasPrefix("/api/timeline/buckets?") { return .init(body: Data("[{\"timeBucket\":\"\(month)\",\"count\":1}]".utf8)) }
            if request.path.hasPrefix("/api/timeline/bucket?") {
                return .init(body: Data(String(decoding: payload, as: UTF8.self)
                    .replacingOccurrences(of: "\"archive\"", with: "\"\(policy.withLock { $0 })\"").utf8))
            }
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "archive-policy-\(UUID())")
        client.confirmMediaAccount("archive-policy-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let staleTimelineAsset = asset(), original = TimelineModel(filter: TimelineFilter(), suppliedAssets: [asset()])
        original.suppliedLaunchContext = "archive-policy-fixture"; original.attach(client)
        _ = try await makeSavedPack(client: client)
        original.removeAssets(ids: [staleTimelineAsset.id])
        ImageLoader.shared.markEphemeral(assetIDs: [staleTimelineAsset.id])
        let archive = TimelineModel(filter: TimelineFilter(visibility: .archive))
        archive.attach(client); await archive.load()
        let canonical = try XCTUnwrap(archive.flatAssets.first)
        XCTAssertEqual(canonical.visibility, .archive)
        let archiveKey = MediaPresentationCoordinator.gridKey(asset: canonical, client: client, pixels: 416)
        XCTAssertTrue(archiveKey.isCurrentContent)
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: staleTimelineAsset, client: client, pixels: 416).isCurrentContent,
            "A different page's positive archive response cannot revive stale timeline presentation metadata")
        let image = try await ImageLoader.shared.image(for: client.thumbnailURL(assetID: canonical.id, cacheKey: canonical.thumbhash), targetPixelSize: 416)
        XCTAssertNotNil(image.cgImage)
        let stale = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        stale.projectImage(asset: staleTimelineAsset, source: .init(assetID: staleTimelineAsset.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: 416)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil((stale.makeZoomReplica() as? UIImageView)?.image)
        policy.withLock { $0 = "timeline" }
        let returned = TimelineModel(filter: TimelineFilter())
        returned.attach(client); await returned.load(); await returned.loadBucket(month, refresh: true)
        let visible = try XCTUnwrap(returned.flatAssets.first)
        XCTAssertEqual(visible.visibility, .timeline)
        let returnedKey = MediaPresentationCoordinator.gridKey(asset: visible, client: client, pixels: 416)
        XCTAssertTrue(returnedKey.isCurrentContent, "Another device's authenticated canonical visibility restoration must recover without deleting source history")
        XCTAssertFalse(archiveKey.isCurrentContent, "Old publishers remain rejected even when content hash repeats across legitimate visibility changes")
        XCTAssertFalse(MediaContentGenerations(root: LaunchPreviewStore.rootDirectory).isRetired(scope: returnedKey.scope,
            subject: returnedKey.subject, sourceRevision: returnedKey.sourceRevision))
    }

    func testMountedBlockedTileAutomaticallyRebindsAfterAuthenticatedRollbackProof() async throws {
        let userID = "mounted-recovery-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let detail = Data(#"{"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg","thumbhash":"revision-one","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z","isFavorite":false,"isTrashed":false,"visibility":"timeline"}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path == "/api/assets/same-id" { return .init(body: detail) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "mounted-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parent.present(host, animated: false) { continuation.resume() }
        }
        func finish() async {
            tile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                host.dismiss(animated: false) { continuation.resume() }
            }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            let client = try XCTUnwrap(session.client), value = asset()
            let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
            model.suppliedLaunchContext = "mounted-proof-fixture"; model.attach(client)
            let removal = model.removeAssetsForOptimisticAction(ids: [value.id])
            let blocked = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let registry = AssetTileRegistry()
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false,
                targetPixelSize: 416, registry: registry)
            XCTAssertFalse(blocked.isCurrentContent)
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
            model.restore(removal)
            // No manual configure/project/notification after proof: UIKit's
            // existing observed recovery generation must update this same view.
            for _ in 0..<200 {
                if (tile.makeZoomReplica() as? UIImageView)?.image != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let current = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
            XCTAssertNotNil(tile.checkpointSurface(for: current, client: client))
            XCTAssertFalse(blocked.isCurrentContent)
            XCTAssertTrue(server.received.contains { $0.path.contains("/thumbnail") })
        } catch {
            await finish(); throw error
        }
        await finish()
    }

    func testRetirementScopeFoldClearsMountedUnlistedTileAndPreservesOtherScopeSurface() async throws {
        let (localID, localImage) = try await createSurfaceFixture()
        let other = client(UUID().uuidString); other.confirmMediaAccount("fold-other-\(UUID())")
        defer { other.invalidate() }
        var local = asset(); local.localIdentifier = localID
        local.localImageVersion = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        let otherKey = MediaPresentationCoordinator.gridKey(asset: local, client: other, pixels: 416)
        LocalImageLoader.shared.installPrepared(localImage, localIdentifier: localID, targetPixelSize: 416,
            cacheScope: MediaPresentationCoordinator.localScope(asset: local, client: other, pixels: 416),
            permission: LocalImageLoader.shared.permissionGeneration)
        let otherTile = TimelineTileView(frame: .init(x: 170, y: 150, width: 132, height: 132))
        otherTile.projectImage(asset: local, source: .init(assetID: local.id, localIdentifier: localID,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: other, generation: 0, targetPixelSize: 416)
        let otherSurface = try XCTUnwrap(otherTile.checkpointSurface(for: otherKey, client: other))
        let userID = "fold-mounted-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "fold-mounted", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let host = UIViewController(), tile = TimelineTileView(frame: .init(x: 20, y: 150, width: 132, height: 132))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        host.modalPresentationStyle = .fullScreen; host.view.addSubview(tile); host.view.addSubview(otherTile)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in parent.present(host, animated: false) { continuation.resume() } }
        func finish() async {
            tile.unregister()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in host.dismiss(animated: false) { continuation.resume() } }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            let client = try XCTUnwrap(session.client), value = asset(), registry = AssetTileRegistry()
            let old = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            tile.configure(asset: value, session: session, motion: GridMotion(), showsBackupBadge: false, targetPixelSize: 416, registry: registry)
            for _ in 0..<150 {
                if tile.checkpointSurface(for: old, client: client) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(tile.checkpointSurface(for: old, client: client))
            let requests = server.received.filter { $0.path.contains("/thumbnail") }.count
            let blocked = (0..<6_000).map { MediaDisplayKeyV1.Subject.remoteAsset("folded-\($0)") }
            XCTAssertNil(ImageLoader.shared.invalidateSubjects(client: client, subjects: blocked, retiresSourceRevisions: false, blocksAccess: true))
            XCTAssertFalse(old.isCurrentContent)
            XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
            for _ in 0..<100 {
                if (tile.makeZoomReplica() as? UIImageView)?.image == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "A scope-default-deny transition must clear the already mounted unlisted subject without manual projection")
            XCTAssertEqual(server.received.filter { $0.path.contains("/thumbnail") }.count, requests, "Default-deny cannot refill from an old remote producer")
            XCTAssertTrue(otherKey.isCurrentContent); XCTAssertTrue(otherSurface.isCurrent())
            XCTAssertNotNil((otherTile.makeZoomReplica() as? UIImageView)?.image)
        } catch { await finish(); throw error }
        await finish()
    }

    func testFailedMutationReadbackWithNewRevisionAutomaticallyBindsCanonicalMountedGrid() async throws {
        try await checkChangedRevisionRollback(stableSecondRevision: true)
    }

    func testSecondCanonicalRevisionChangeStaysBlockedWithAtMostTwoRealReadbacks() async throws {
        try await checkChangedRevisionRollback(stableSecondRevision: false)
    }

    private func checkChangedRevisionRollback(stableSecondRevision: Bool) async throws {
        let reads = Mutex(0)
        let userID = "revision-recovery-\(UUID())"
        let user = Data("{\"id\":\"\(userID)\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\",\"isAdmin\":false}".utf8)
        let detail = Data(#"{"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg","thumbhash":"revision-two","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z","isFavorite":false,"isTrashed":false,"visibility":"timeline"}"#.utf8)
        let bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { request in
            if request.path == "/api/users/me" { return .init(body: user) }
            if request.method == "PUT" { return .init(status: 400) }
            if request.path == "/api/assets/same-id" {
                let count = reads.withLock { $0 += 1; return $0 }
                let payload = !stableSecondRevision && count > 1
                    ? Data(String(decoding: detail, as: UTF8.self).replacingOccurrences(of: "revision-two", with: "revision-three").utf8) : detail
                return .init(body: payload)
            }
            if request.path.contains("/thumbnail") { return .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
            return .init(status: 503)
        }
        try await server.start(); defer { server.stop() }
        let session = SessionStore()
        await session.logIn(apiURL: server.apiURL, response: .init(accessToken: "revision-fixture", userId: userID,
            userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false, profileImagePath: "", shouldChangePassword: false))
        session.backup?.shutdown(); session.realtime?.shutdown(); session.favorites?.shutdown(); session.cachedLaunchHandle?.cancel()
        let client = try XCTUnwrap(session.client)
        var value = asset(); value.fileCreatedAt = try XCTUnwrap(APIDate.parse("2023-11-14T00:00:00Z"))
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
        model.suppliedLaunchContext = "revision-proof-fixture"; model.attach(client)
        let old = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        let host = UIViewController(); host.view = grid; host.modalPresentationStyle = .fullScreen
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parent.present(host, animated: false) { continuation.resume() }
        }
        func finish() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                host.dismiss(animated: false) { continuation.resume() }
            }
            await session.logOut(reportRemoteFailure: false)
        }
        do {
            grid.update(side: 132, tailPadding: 0, context: .init(session: session, columns: 3,
                targetPixelSize: 416, showsBackupBadge: false, usesOriginalAspectRatio: false, isSelecting: false,
                selection: [], reduceMotion: true, registry: AssetTileRegistry(), motion: GridMotion(),
                isSelectable: { _ in true }, isSelectableAssetID: { _ in true },
                actions: .init(toggleSelection: { _ in }, menu: { _ in UIMenu(children: []) }, makeViewer: { _, _, _ in nil }),
                toggleDay: { _, _ in }), animated: false)
            grid.layoutIfNeeded()
            var removal: TimelineRemoval?, blocked: MediaDisplayKeyV1?
            let outcome: Void? = await OptimisticAction.perform(errorMessage: "revision fixture", apply: {
                removal = model.removeAssetsForOptimisticAction(ids: [value.id])
                blocked = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            }, rollback: { if let removal { model.restore(removal) } },
                request: { try await client.setVisibility(ids: [value.id], .archive) }, reportFailure: { _, _ in })
            XCTAssertNil(outcome)
            func tiles(_ view: UIView) -> [TimelineTileView] {
                (view as? TimelineTileView).map { [$0] } ?? view.subviews.flatMap { tiles($0) }
            }
            // No manual reproject/layout after proof: the actual model/grid producer must adopt R2.
            for _ in 0..<200 {
                if stableSecondRevision {
                    if tiles(grid).contains(where: { $0.asset?.thumbhash == "revision-two" && ($0.makeZoomReplica() as? UIImageView)?.image != nil }) { break }
                } else if model.flatAssets.first?.thumbhash == "revision-three"
                    && tiles(grid).contains(where: { $0.asset?.thumbhash == "revision-three" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let current = try XCTUnwrap(model.flatAssets.first)
            XCTAssertEqual(current.thumbhash, stableSecondRevision ? "revision-two" : "revision-three")
            let key = MediaPresentationCoordinator.gridKey(asset: current, client: client, pixels: 416)
            XCTAssertEqual(key.isCurrentContent, stableSecondRevision)
            let tile = try XCTUnwrap(tiles(grid).first { $0.asset?.id == value.id })
            XCTAssertEqual(tile.asset?.thumbhash, current.thumbhash)
            if stableSecondRevision {
                XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image?.cgImage)
                XCTAssertNotNil(tile.checkpointSurface(for: key, client: client))
            } else {
                XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image)
                XCTAssertNil(tile.checkpointSurface(for: key, client: client))
                XCTAssertFalse(server.received.contains { $0.path.contains("/thumbnail") && ($0.path.contains("revision-two") || $0.path.contains("revision-three")) })
            }
            XCTAssertFalse(old.isCurrentContent); XCTAssertFalse(try XCTUnwrap(blocked).isCurrentContent)
            let restarted = MediaContentGenerations(root: LaunchPreviewStore.rootDirectory)
            XCTAssertTrue(restarted.isRetired(scope: key.scope, subject: key.subject, sourceRevision: "revision-one"))
            XCTAssertEqual(restarted.isCurrent(scope: key.scope, subject: key.subject, sourceRevision: current.thumbhash ?? "", generation: key.contentGeneration, visibilityPolicy: "timeline"), stableSecondRevision)
            XCTAssertEqual(server.received.filter { $0.path == "/api/assets/same-id" }.count, 2)
            if stableSecondRevision { XCTAssertTrue(server.received.contains { $0.path.contains("/thumbnail") && $0.path.contains("revision-two") }) }
            else { XCTAssertTrue(restarted.isRetired(scope: key.scope, subject: key.subject, sourceRevision: "revision-two")) }
        } catch { await finish(); throw error }
        await finish()
    }

    func testCurrentPhotoKitProofRestoresLocalRollbackWithoutGrantingFromMetadataAlone() async throws {
        let (local, _) = try await createSurfaceFixture()
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("local-rollback-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        var value = asset(); value.localIdentifier = local
        value.localImageVersion = try XCTUnwrap(LocalImageLoader.currentModificationRevision(local))
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
        model.suppliedLaunchContext = "local-rollback-fixture"; model.attach(client)
        let old = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let removal = model.removeAssetsForOptimisticAction(ids: [value.id])
        let denied = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        XCTAssertFalse(denied.isCurrentContent)
        model.restore(removal)
        for _ in 0..<100 {
            if MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
        XCTAssertFalse(old.isCurrentContent); XCTAssertFalse(denied.isCurrentContent)
        // A still-present row cannot turn a retired local revision into proof.
        var stale = value; stale.localImageVersion = "not-the-current-PhotoKit-revision"
        model.updateAssets(ids: [value.id]) { $0 = stale }
        let again = model.removeAssetsForOptimisticAction(ids: [value.id]); model.restore(again)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: stale, client: client, pixels: 416).isCurrentContent)
    }

    func testDeniedAndUnknownReadbacksNeverClearPresentationBlock() async throws {
        for (status, visibility) in [(403, "timeline"), (404, "timeline"), (503, "timeline"), (200, "hidden"), (200, "locked"), (200, "unknown")] {
            let policy = visibility == "unknown" ? "" : ",\"visibility\":\"\(visibility)\""
            let detail = Data("{\"id\":\"same-id\",\"ownerId\":\"alice\",\"type\":\"IMAGE\",\"originalFileName\":\"fixture.jpg\",\"thumbhash\":\"revision-one\",\"fileCreatedAt\":\"2023-11-14T00:00:00Z\",\"localDateTime\":\"2023-11-14T00:00:00Z\",\"isFavorite\":false,\"isTrashed\":false\(policy)}".utf8)
            let server = try LocalHTTPServer { _ in .init(status: status, body: detail) }
            try await server.start(); defer { server.stop() }
            let client = ImoraClient(apiURL: server.apiURL, accessToken: "denied-proof-\(UUID())")
            client.confirmMediaAccount("denied-proof-\(UUID())")
            ImageLoader.shared.configure(client: client)
            defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
            let value = asset(), model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [asset()])
            model.suppliedLaunchContext = "denied-readback-fixture"; model.attach(client)
            let removal = model.removeAssetsForOptimisticAction(ids: [value.id]); model.restore(removal)
            for _ in 0..<100 {
                if server.received.contains(where: { $0.path == "/api/assets/same-id" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            // Also await an actual response to discriminate network absence
            // from a rejected/unknown policy. This API alone grants nothing.
            do { _ = try await client.assetDetail(id: value.id) }
            catch { if status == 200 { XCTFail("Unexpected fixture decode failure: \(error)") } }
            model.replaceSuppliedAssets([value], groupsByDate: true)
            XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent,
                "\(status)/\(visibility): cached/ordinary Asset arrays and rejected/unknown authority cannot reopen access")
            XCTAssertFalse(server.received.contains { $0.path.contains("/thumbnail") })
        }
    }

    func testLateAuthenticatedProofCannotCrossAnotherBlockOrClient() async throws {
        let detail = Data(#"{"id":"same-id","ownerId":"alice","type":"IMAGE","originalFileName":"fixture.jpg","thumbhash":"revision-one","fileCreatedAt":"2023-11-14T00:00:00Z","localDateTime":"2023-11-14T00:00:00Z","isFavorite":false,"isTrashed":false,"visibility":"timeline"}"#.utf8)
        let server = try LocalHTTPServer { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return .init(body: detail)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "late-proof-\(UUID())")
        client.confirmMediaAccount("late-proof-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset()
        ImageLoader.shared.invalidate(asset: value, client: client, retiresSourceRevisions: false, blocksAccess: true)
        let request = Task { try await client.authenticatedAsset(id: value.id) }
        for _ in 0..<100 where server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(server.received.isEmpty)
        ImageLoader.shared.invalidate(asset: value, client: client, retiresSourceRevisions: false, blocksAccess: true)
        let response = try await request.value
        response.authorizePresented([value], visibility: .timeline, using: client)
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
        let beforeCancellation = server.received.count
        let cancelled = Task { try await client.authenticatedAsset(id: value.id) }
        for _ in 0..<100 where server.received.count == beforeCancellation { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(server.received.count, beforeCancellation)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled readback produced positive evidence") }
        catch is CancellationError {}
        catch let error as URLError where error.code == .cancelled {}
        catch { XCTFail("Unexpected cancellation error: \(type(of: error)): \(error)") }
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
        let replacement = ImoraClient(apiURL: server.apiURL, accessToken: "different-client")
        replacement.confirmMediaAccount("different-account"); ImageLoader.shared.configure(client: replacement)
        defer { replacement.invalidate() }
        response.authorizePresented([value], visibility: .timeline, using: replacement)
        XCTAssertFalse(MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416).isCurrentContent)
    }

    func testOneProjectionReadsEachLocalRevisionOnceButNextProjectionRechecksAccess() async throws {
        let (localID, image) = try await createSurfaceFixture()
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("projection-read-fixture")
        defer { client.invalidate() }
        var value = asset()
        value.localIdentifier = localID
        value.localImageVersion = try XCTUnwrap(LocalImageLoader.currentModificationRevision(localID))
        let pixels: CGFloat = 416
        let source = AssetThumbnailSource(assetID: value.id, localIdentifier: localID,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil)
        LocalImageLoader.shared.installPrepared(image, localIdentifier: localID, targetPixelSize: pixels,
            cacheScope: MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels),
            permission: LocalImageLoader.shared.permissionGeneration)
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
        XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
        let reads = try observePhotoKitFetches(for: localID) {
            tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
        }
        XCTAssertEqual(reads, 1, "One unchanged synchronous projection must not fetch the same local revision twice")
        XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
        let deniedReads = try observePhotoKitFetches(for: localID, denyingRead: true) {
            tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
        }
        XCTAssertGreaterThan(deniedReads, 0, "The next projection must obtain fresh proof, not reuse prior-call authorization")
        XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image, "A newly unreadable resource must clear the actual visible surface")
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: pixels)
        XCTAssertNil(tile.checkpointSurface(for: key, client: client))
    }

    func testCompletedLaunchProbeStopsPollingButLayoutAndCheckpointCanRefreshPrimingSnapshot() async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let parent = try XCTUnwrap(window.rootViewController)
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        let host = UIViewController()
        host.view = grid
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parent.present(host, animated: false) { continuation.resume() }
        }
        let trace = LaunchPresentationTrace(grid: grid)
        func summary() throws -> [String: Any] {
            let text = try XCTUnwrap(grid.accessibilityValue)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        func dismiss() async {
            trace.stop()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
        do {
            trace.didCompleteLayout()
            for _ in 0..<700 {
                if (try summary())["observationComplete"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let finished = try summary()
            XCTAssertEqual(finished["observationComplete"] as? Bool, true)
            let finalAX = grid.accessibilityValue
            let frameCount = try XCTUnwrap(finished["sampledFrames"] as? Int)
            let traceID = try XCTUnwrap(finished["traceID"] as? String)
            let artifact = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "imora/launch-measurements/\(traceID).json")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: artifact.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let originalArtifact = try Data(contentsOf: artifact)
            defer { try? FileManager.default.removeItem(at: artifact) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(grid.accessibilityValue, finalAX, "Completing the bounded window must stop CAD/AX churn")
            trace.didCompleteLayout()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(grid.accessibilityValue, finalAX, "An unchanged layout must not publish a timestamp-only snapshot")
            grid.isUserInteractionEnabled = false
            trace.didCompleteLayout()
            for _ in 0..<100 {
                if (try summary())["latest"].flatMap({ $0 as? [String: Any] })?["viewInteractionEnabled"] as? Bool == false { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual((try summary())["latest"].flatMap { $0 as? [String: Any] }?["viewInteractionEnabled"] as? Bool, false)
            let client = client(UUID().uuidString)
            defer { client.invalidate() }
            let value = asset(), key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
            let checkpoint = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "probe-fixture",
                sort: "asc", anchor: value.id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
                visibleKeys: [key], metadata: Data())
            LaunchPresentationTrace.didCheckpoint(checkpoint)
            for _ in 0..<100 {
                if (try summary())["checkpointW0"] as? [String] == [value.id] { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let primed = try summary()
            XCTAssertEqual(primed["checkpointW0"] as? [String], [value.id], "A changed real checkpoint must refresh priming evidence after launch polling stops")
            XCTAssertEqual(primed["sampledFrames"] as? Int, frameCount)
            XCTAssertEqual(try Data(contentsOf: artifact), originalArtifact, "Priming snapshots cannot rewrite the original first-gallery artifact")
        } catch {
            await dismiss()
            throw error
        }
        await dismiss()
    }

    func testCachedLaunchHandleSharesSuspendedPreparationAndRejectsChangedSelection() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("handle-fixture")
        defer { client.invalidate() }
        let gate = LaunchPreparationGate()
        let handle = CachedLaunchHandle(client: client, source: "cloud", filter: "exact-filter") {
            await gate.prepare()
            return nil
        }
        XCTAssertNil(handle.preparedIfReady(client: client, source: "cloud", filter: "exact-filter"))
        XCTAssertFalse(handle.matches(client: client, source: "device", filter: "exact-filter"))
        XCTAssertFalse(handle.matches(client: client, source: "cloud", filter: "changed-sort"))
        let first = Task { await handle.value(client: client, source: "cloud", filter: "exact-filter") }
        let second = Task { await handle.value(client: client, source: "cloud", filter: "exact-filter") }
        await gate.waitForStart()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1, "Scene construction and model load must share one local preparation")
        await gate.release()
        let one = await first.value, two = await second.value
        XCTAssertNil(one); XCTAssertNil(two)
        await handle.waitUntilReleased()
        XCTAssertTrue(handle.isReleased, "A miss releases startup reconciliation without a timer")
    }

    func testCachedLaunchHandleRevalidatesAccessContentLayoutAndCancellation() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("ready-handle-fixture")
        defer { client.invalidate() }
        let asset = asset()
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 416)
        let layout = LaunchViewportSnapshot.Layout(width: 390, height: 700, scale: 3, columns: 3)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "exact",
            sort: "asc", anchor: asset.id, layout: layout, visibleKeys: [key], metadata: try JSONEncoder().encode([asset]))
        let prepared = PreparedViewport(snapshot: snapshot, assets: [asset], access: MediaPresentationCoordinator.access(for: client),
            images: [key: UIImage()], missingKeys: [], checkpointMiss: false)
        let handle = CachedLaunchHandle(client: client, source: "cloud", filter: "exact") { prepared }
        let ready = await handle.value(client: client, source: "cloud", filter: "exact")
        XCTAssertNotNil(ready)
        XCTAssertNotNil(handle.preparedIfReady(client: client, source: "cloud", filter: "exact", layout: layout))
        XCTAssertNil(handle.preparedIfReady(client: client, source: "cloud", filter: "exact",
            layout: .init(width: 390, height: 600, scale: 3, columns: 3)))
        LocalImageLoader.shared.noteLibraryChange()
        XCTAssertNil(handle.preparedIfReady(client: client, source: "cloud", filter: "exact"), "Prepared authorization cannot cross a local access generation")
        handle.cancel()
        await handle.waitUntilReleased()
        XCTAssertTrue(handle.isReleased)
        let gate = LaunchPreparationGate()
        let suspended = CachedLaunchHandle(client: client, source: "cloud", filter: "exact") { await gate.prepare(); return nil }
        await gate.waitForStart()
        suspended.cancel()
        await suspended.waitUntilReleased()
        XCTAssertTrue(suspended.isReleased, "Cancellation releases reconciliation even when a dependency is suspended")
        await gate.release()
    }

    func testReadyBootstrapPublishesMetadataBeforeLoadAndRealGeometryCanRetireIt() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("model-bootstrap-fixture")
        defer { client.invalidate() }
        let filter = TimelineFilter(order: "asc")
        let keyString = try XCTUnwrap(TimelineCache.key(for: filter))
        let value = asset()
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let layout = LaunchViewportSnapshot.Layout(width: 390, height: 700, scale: 3, columns: 3)
        var snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: keyString,
            sort: "asc", anchor: value.id, layout: layout, visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        snapshot.bucketList = try JSONEncoder().encode([TimeBucket(timeBucket: "2026-11", count: 1)])
        snapshot.bucketIDByAssetID = [value.id: "2026-11"]
        snapshot.bucketLeadingAssetCounts = ["2026-11": 0]
        let prepared = PreparedViewport(snapshot: snapshot, assets: [value], access: MediaPresentationCoordinator.access(for: client),
            images: [key: UIImage()], missingKeys: [], checkpointMiss: false)
        let handle = CachedLaunchHandle(client: client, source: "cloud", filter: keyString) { prepared }
        _ = await handle.value(client: client, source: "cloud", filter: keyString)
        let model = TimelineModel(filter: filter)
        model.attachCachedLaunch(handle, client: client, backup: nil)
        XCTAssertEqual(model.sections.reduce(0) { $0 + $1.count }, 1, "First body must not publish a false zero while awaiting load()")
        XCTAssertEqual(model.flatAssets.map(\.id), [value.id])
        XCTAssertTrue(model.hasRestoredLaunchViewport)
        XCTAssertFalse(handle.isReleased, "A temporary SwiftUI initial model cannot consume the shared handle")
        model.launchLayout = .init(width: 390, height: 600, scale: 3, columns: 3)
        XCTAssertTrue(model.rows.isEmpty, "A different actual UIKit viewport must reject the preadopted W0 before mounting")
        XCTAssertFalse(model.hasRestoredLaunchViewport)
        XCTAssertTrue(handle.isReleased)

        let gate = LaunchPreparationGate()
        let abandoned = CachedLaunchHandle(client: client, source: "cloud", filter: keyString) { await gate.prepare(); return prepared }
        let leavingModel = TimelineModel(filter: filter)
        leavingModel.attachCachedLaunch(abandoned, client: client, backup: nil)
        await gate.waitForStart()
        leavingModel.releaseCachedLaunch()
        await abandoned.waitUntilReleased()
        XCTAssertTrue(abandoned.isReleased, "Leaving Photos must release backup reconciliation even before preparation returns")
        await gate.release()
        let late = await abandoned.value(client: client, source: "cloud", filter: keyString)
        XCTAssertNil(late, "A late preparation cannot republish after navigation cancellation")
        XCTAssertTrue(leavingModel.rows.isEmpty)
    }

    func testDecodedBootstrapCannotPublishAfterItsPairingEvidenceIsRetired() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("late-proof-fixture")
        defer { client.invalidate() }
        let filter = TimelineFilter(order: "asc")
        let filterKey = try XCTUnwrap(TimelineCache.key(for: filter))
        let value = asset(), allowed = LaunchEvidenceFlag()
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: filterKey,
            sort: "asc", anchor: value.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        let prepared = PreparedViewport(snapshot: snapshot, assets: [value], access: MediaPresentationCoordinator.access(for: client),
            images: [key: UIImage()], missingKeys: [], checkpointMiss: false,
            localEvidenceIsCurrent: { allowed.value.withLock { $0 } })
        let handle = CachedLaunchHandle(client: client, source: "cloud", filter: filterKey) { prepared }
        _ = await handle.value(client: client, source: "cloud", filter: filterKey)
        allowed.value.withLock { $0 = false }
        let model = TimelineModel(filter: filter)
        model.attachCachedLaunch(handle, client: client, backup: nil)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.hasRestoredLaunchViewport, "Decode completion is not authorization at later metadata adoption")
        handle.cancel()
    }

    func testBootstrapSourceProofRejectsRemoteOriginalWhenCurrentSelectionIsPairedLocal() async throws {
        let client = client(UUID().uuidString), account = "selection-proof-fixture"
        client.confirmMediaAccount(account)
        defer { client.invalidate() }
        let root = FileManager.default.temporaryDirectory.appending(path: "bootstrap-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = BackupIndex(fileURL: root.appending(path: "index.json"))
        _ = await index.load(serverHost: client.serverKey, userId: account, generation: client.context.id)
        let value = asset()
        await index.setHashed(localId: "selected-local", isLivePhoto: false, primaryChecksum: "fixture",
            motionChecksum: nil, modificationDate: .now)
        await index.setPrimaryRemoteId(localId: "selected-local", value.id)
        let backup = BackupManager(client: client, index: index)
        backup.userId = account
        defer { backup.shutdown() }
        let evidence = backup.launchSurfaceValidator()
        let loaded = await evidence.prepare()
        XCTAssertTrue(loaded)
        let original = await evidence.validateRemote(value)
        XCTAssertFalse(original, "A remote original cannot stand in for the current paired-local render without its provenance")
        var edited = value; edited.isEdited = true
        let committedRemote = await evidence.validateRemote(edited)
        XCTAssertTrue(committedRemote, "A current remote edited render remains eligible despite the original pair")
        XCTAssertTrue(evidence.isCurrent())
        index.revokeCleanupAuthority()
        XCTAssertFalse(evidence.isCurrent(), "Known pairing changes must reject a decoded result before MainActor adoption")
    }

    func testProtectedLaunchEventIsRememberedAndReleasesLateEarlyFalseAndCancelledWaiters() async throws {
        let early = LaunchProtectionGate()
        early.resolve(true)
        let remembered = await early.value()
        XCTAssertTrue(remembered, "An observer arriving after didFinishLaunching must not miss its state")
        early.resolve(true)
        XCTAssertTrue(early.isAvailable)
        let late = LaunchProtectionGate()
        let waiting = Task { await late.value() }
        await Task.yield()
        late.resolve(true)
        let delivered = await waiting.value
        XCTAssertTrue(delivered)
        let locked = LaunchProtectionGate()
        locked.resolve(false)
        let denied = await locked.value()
        XCTAssertFalse(denied, "Actual protected-data unavailability is an explicit exception, never guessed true")
        let cancelledGate = LaunchProtectionGate()
        let cancelled = Task { await cancelledGate.value() }
        await Task.yield(); cancelled.cancel()
        let cancelledValue = await cancelled.value
        XCTAssertFalse(cancelledValue, "Leaving a scene cannot strand a preparation waiter before launch delivery")
        cancelledGate.resolve(true)
        let future = await cancelledGate.value()
        XCTAssertTrue(future, "Cancelling one waiter cannot consume the remembered event for later observers")
    }

    func testDeviceBootstrapKeepsFullCanonicalCountAndSlotsThroughFullLibraryMaterialization() throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("device-slots-fixture")
        defer { client.invalidate() }
        let values = (0..<120).map { index in
            var value = Asset(id: "local-slot-\(index)", ownerId: "", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            value.localIdentifier = "projection-only-\(index)"
            value.localImageVersion = "projection-revision"
            return value
        }
        let full = TimelineModel(filter: TimelineFilter(order: "asc"), suppliedAssets: values)
        full.showsDateHeaders = false
        let bucket = try XCTUnwrap(full.sections.first?.id)
        let w0 = Array(values[60..<78]), sourceKey = "device|all|date"
        let keys = w0.map { MediaPresentationCoordinator.gridKey(asset: $0, client: client, pixels: 416) }
        var snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "device", filter: sourceKey,
            sort: "asc", anchor: w0[0].id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: keys, metadata: try JSONEncoder().encode(w0))
        snapshot.bucketList = try JSONEncoder().encode([TimeBucket(timeBucket: bucket, count: 120)])
        snapshot.bucketIDByAssetID = Dictionary(uniqueKeysWithValues: w0.map { ($0.id, bucket) })
        snapshot.bucketLeadingAssetCounts = [bucket: 60]
        let prepared = PreparedViewport(snapshot: snapshot, assets: w0, access: MediaPresentationCoordinator.access(for: client),
            images: Dictionary(uniqueKeysWithValues: keys.map { ($0, UIImage()) }), missingKeys: [], checkpointMiss: false)
        let restored = TimelineModel(filter: full.filter, suppliedAssets: [])
        restored.suppliedLaunchContext = sourceKey
        restored.showsDateHeaders = false
        restored.attach(client, preparesLaunchViewport: true)
        XCTAssertTrue(restored.adoptPreparedViewport(prepared))
        let side = AssetGridLayout.tileSide(viewportWidth: 402, columns: 3)
        func assertCanonical(_ model: TimelineModel, _ stage: String) throws {
            XCTAssertEqual(model.sections.reduce(0) { $0 + $1.count }, 120, stage)
            let row = try XCTUnwrap(model.rowIndex(containingAnyOf: [w0[0].id]))
            let layout = TimelineRowLayout.build(rows: model.rows, side: side, version: 0)
            XCTAssertEqual(layout.starts[row], 20 * (side + 2), accuracy: 0.001, stage)
            let shown = model.rows[row...].prefix(6).flatMap { row -> [String] in
                if case .tiles(_, let runs) = row { return runs.flatMap(\.assets).map(\.id) }; return []
            }
            XCTAssertEqual(shown, w0.map(\.id), stage)
            if case .tiles(_, let runs) = model.rows[row] { XCTAssertEqual(runs.first?.colStart, 0, stage) }
        }
        try assertCanonical(restored, "prepared W0 before whole-library scan")
        XCTAssertEqual(restored.pendingLaunchAnchor?.id, w0[0].id)
        restored.replaceSuppliedAssets(values, groupsByDate: true)
        try assertCanonical(restored, "full PhotoKit metadata arrives")
    }

    func testMiddleAnchorFirstUIKitBindingUsesFinalsAfterPreviewEviction() async throws {
        let image = solidImage(pixels: 512), bytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let identifiers = try await createSyntheticSurfacePhotos(bytes: bytes, count: 21)
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("first-binding-fixture")
        defer { client.invalidate() }
        let values = try identifiers.enumerated().map { index, identifier -> Asset in
            var value = Asset(id: "local-\(identifier)", ownerId: "", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            value.localIdentifier = identifier
            value.localImageVersion = try XCTUnwrap(LocalImageLoader.currentModificationRevision(identifier))
            return value
        }
        let pixels: CGFloat = 416
        let keys = values.map { MediaPresentationCoordinator.gridKey(asset: $0, client: client, pixels: pixels) }
        let permission = LocalImageLoader.shared.permissionGeneration
        for value in values {
            let independentImage = solidImage(pixels: 512)
            LocalImageLoader.shared.installPrepared(independentImage, localIdentifier: value.localIdentifier!, targetPixelSize: pixels,
                cacheScope: MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels), permission: permission)
        }
        let previewMisses = values.filter { value in
            LocalImageLoader.shared.cachedPreview(localIdentifier: value.localIdentifier!,
                cacheScope: MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels)) == nil
        }
        XCTAssertFalse(previewMisses.isEmpty, "Establish real preview eviction, not a simulated missing bitmap")
        XCTAssertTrue(values.allSatisfy { value in
            LocalImageLoader.shared.cachedImage(localIdentifier: value.localIdentifier!, targetPixelSize: pixels,
                contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile,
                cacheScope: MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels)) != nil
        }, "All qualified exact-size final surfaces must remain available")
        let bucket = "2023-11-01", filter = "device|all|date"
        var snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "device", filter: filter,
            sort: "asc", anchor: values[0].id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: keys, metadata: try JSONEncoder().encode(values))
        snapshot.bucketList = try JSONEncoder().encode([TimeBucket(timeBucket: bucket, count: 120)])
        snapshot.bucketIDByAssetID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, bucket) })
        snapshot.bucketLeadingAssetCounts = [bucket: 60]
        snapshot.anchorOffset = 5.6666666667
        let model = TimelineModel(filter: TimelineFilter(order: "asc"), suppliedAssets: [])
        model.suppliedLaunchContext = filter; model.showsDateHeaders = false
        model.attach(client, preparesLaunchViewport: true)
        let prepared = PreparedViewport(snapshot: snapshot, assets: values, access: MediaPresentationCoordinator.access(for: client),
            images: Dictionary(uniqueKeysWithValues: keys.map { ($0, image) }), missingKeys: [], checkpointMiss: false)
        XCTAssertTrue(model.adoptPreparedViewport(prepared))
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        grid.contentInsetAdjustmentBehavior = .never; grid.usesFullPhotosCanvas = true
        let side = AssetGridLayout.tileSide(viewportWidth: 402, columns: 3)
        grid.update(side: side, tailPadding: 0, context: .init(session: SessionStore(), columns: 3,
            targetPixelSize: pixels, showsBackupBadge: false, usesOriginalAspectRatio: false, isSelecting: false,
            selection: [], reduceMotion: true, registry: AssetTileRegistry(), motion: GridMotion(),
            isSelectable: { _ in true }, isSelectableAssetID: { _ in true },
            actions: .init(toggleSelection: { _ in }, menu: { _ in UIMenu(children: []) }, makeViewer: { _, _, _ in nil }),
            toggleDay: { _, _ in }), animated: false)
        grid.layoutIfNeeded()
        XCTAssertNil(model.pendingLaunchAnchor, "Apply the saved anchor in the first UIKit layout before binding rows")
        XCTAssertEqual(grid.offsetY, 20 * (side + 2) + CGFloat(snapshot.anchorOffset), accuracy: 0.001)
        func tiles(in view: UIView) -> [TimelineTileView] {
            (view as? TimelineTileView).map { [$0] } ?? view.subviews.flatMap { tiles(in: $0) }
        }
        let mounted = tiles(in: grid)
        XCTAssertEqual(Set(mounted.compactMap { $0.asset?.id }), Set(values.map(\.id)))
        // projectImage is the exact production binding entry used by UIKit's
        // updateProperties. No await, runloop, PhotoKit delivery or CAD tick
        // is allowed between this first binding and the image assertions.
        for tile in mounted {
            let value = try XCTUnwrap(tile.asset)
            tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: value.localIdentifier,
                pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: ImageLoadRecovery.shared.generation, targetPixelSize: pixels)
        }
        let readyCount = mounted.filter { ($0.makeZoomReplica() as? UIImageView)?.image?.cgImage != nil }.count
        XCTAssertEqual(readyCount, 21, "First UIKit binding must use qualified finals even when preview eviction removes the leading tiles")
        for (value, key) in zip(values, keys) {
            let tile = try XCTUnwrap(mounted.first { $0.asset?.id == value.id })
            XCTAssertNotNil(tile.checkpointSurface(for: key, client: client), "First binding must capture the current source/access/revision")
        }
        var stale = values[0]
        stale.localImageVersion = "retired-local-source"
        let staleScope = MediaPresentationCoordinator.localScope(asset: stale, client: client, pixels: pixels)
        LocalImageLoader.shared.installPrepared(image, localIdentifier: stale.localIdentifier!, targetPixelSize: pixels,
            cacheScope: staleScope, permission: permission)
        let reused = try XCTUnwrap(mounted.first { $0.asset?.id == stale.id })
        reused.projectImage(asset: stale, source: .init(assetID: stale.id, localIdentifier: stale.localIdentifier,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: ImageLoadRecovery.shared.generation, targetPixelSize: pixels)
        XCTAssertNil((reused.makeZoomReplica() as? UIImageView)?.image,
            "An exact cache entry cannot bind under metadata whose source revision disagrees with current PhotoKit")
    }

    func testRestorePreparesActualBitmapAndSeedsFirstSynchronousGridLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase4-flow-\(UUID())")
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let userID = "alice-fixture-\(UUID())"
        let first = client(UUID().uuidString)
        first.confirmMediaAccount(userID)
        let asset = asset()
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: first, pixels: 416)
        XCTAssertTrue(key.isCurrentContent)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 416, height: 416)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 416, height: 416))
        }
        let encoded = await MediaPresentationCoordinator.encode(image: image, key: key)
        let record = try XCTUnwrap(encoded)
        let snapshot = LaunchViewportSnapshot(scope: first.mediaDisplayScope, source: "cloud", filter: "default",
            sort: "date-desc", anchor: asset.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([asset]))
        let store = LaunchPreviewStore(root: root)
        _ = try await store.checkpoint(snapshot: snapshot, images: [record])
        first.invalidate()
        let second = client(UUID().uuidString)
        second.confirmMediaAccount(userID)
        ImageLoader.shared.configure(client: second)
        defer { ImageLoader.shared.configure(client: nil); second.invalidate() }
        let coordinator = MediaPresentationCoordinator(store: LaunchPreviewStore(root: root))
        let prepared = try await coordinator.restore(client: second, filter: "default", layout: snapshot.layout)
        XCTAssertEqual(prepared?.images.count, 1)
        let bitmap = try XCTUnwrap(prepared?.images[key])
        XCTAssertNotNil(bitmap.cgImage)
        XCTAssertGreaterThanOrEqual(min(bitmap.size.width, bitmap.size.height) * bitmap.scale, 416)
        let lookup = ImageLoader.shared.cachedImage(for: second.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416)
        XCTAssertNotNil(lookup?.cgImage, "The very first grid lookup needs a real surface")
        XCTAssertNil(ImageLoader.shared.cachedImage(for: first.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416), "Stable identity must not authorize an old runtime URL")

        // Bitmap preparation is distinct from the product-grid frame test below.
        XCTAssertNotNil(bitmap.cgImage)

    }

    func testPreparedSurfaceDoesNotSurvivePermissionOrSessionGeneration() async throws {
        let client = client(UUID().uuidString)
        let coordinator = MediaPresentationCoordinator()
        let access = MediaPresentationCoordinator.access(for: client)
        client.invalidate()
        let key = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        XCTAssertNil(coordinator.presentation(for: key, access: access, client: client))
    }

    func testSmallNativeFinalImageEncodesWithoutInventingGridResolution() async throws {
        let client = client(UUID().uuidString)
        defer { client.invalidate() }
        let key = MediaDisplayKeyV1(scope: client.mediaDisplayScope,
            subject: .localAsset(installationID: "fixture-install", localIdentifier: "fixture-small-native"),
            sourceRevision: "native-revision", presentationRevision: "committed:native-revision", variant: .grid,
            pixelBucket: 416, fitMode: "fit-cover", orientationRevision: "source", colorProfile: "source")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let unproven = await MediaPresentationCoordinator.encode(image: small, key: key)
        XCTAssertNil(unproven, "A tiny derivative without native-source proof is insufficient")
        let native = NativeImageResolution(sourceRevision: "native-revision", pixelWidth: 16, pixelHeight: 16)
        let encoded = await MediaPresentationCoordinator.encode(image: small, key: key, nativeResolution: native)
        let result = try XCTUnwrap(encoded)
        XCTAssertEqual(result.key.pixelBucket, 416)
        XCTAssertEqual(result.pixelWidth, 16)
        XCTAssertEqual(result.pixelHeight, 16)
        XCTAssertTrue(result.isQualified)
    }

    func testHostSnapshotCannotVerifyANewCredential() {
        let first = client(UUID().uuidString), second = client(UUID().uuidString)
        first.confirmMediaAccount("alice")
        XCTAssertEqual(first.mediaDisplayScope.accountID, "alice")
        let restart = client(first.accessToken)
        XCTAssertEqual(restart.mediaDisplayScope.accountID, "alice", "Only the credential with persisted evidence may restore verified scope")
        restart.invalidate()
        XCTAssertNil(second.mediaDisplayScope.accountID)
        XCTAssertNotEqual(first.mediaDisplayScope, second.mediaDisplayScope)
        first.invalidate(); second.invalidate()
    }

    func testInitialGeometryWaitResumesOnRealLayoutAndCancelsWhenScreenLeaves() async throws {
        let model = TimelineModel(filter: TimelineFilter())
        var continued = false
        let waiting = Task { await model.waitForLaunchLayout(); continued = true }
        await Task.yield()
        XCTAssertFalse(continued)
        model.launchLayout = .init(width: 390, height: 700, scale: 3, columns: 3)
        await waiting.value
        XCTAssertTrue(continued)
        let leaving = TimelineModel(filter: TimelineFilter())
        let cancelled = Task { await leaving.waitForLaunchLayout() }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
    }

    func testActualPairedTileSuppliesItsBoundCommittedSurface() async throws {
        let (localID, image) = try await createSurfaceFixture()
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("paired-surface-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), pixels: CGFloat = 416
        let scope = MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels)
        LocalImageLoader.shared.installPrepared(image, localIdentifier: localID, targetPixelSize: pixels,
            cacheScope: scope, permission: LocalImageLoader.shared.permissionGeneration)
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: pixels)
        let projectedAccess = MediaPresentationCoordinator.access(for: client)
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: localID, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: pixels)
        for _ in 0..<100 {
            tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
                pairedLocalIdentifier: localID, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: 0, targetPixelSize: pixels)
            if tile.checkpointSurface(for: key, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client),
            "The actual paired tile's adequate local bitmap must be available to its committed W0 checkpoint; projected=\(projectedAccess), current=\(MediaPresentationCoordinator.access(for: client))")
        XCTAssertEqual(surface.key, key)
        XCTAssertEqual(surface.localProvenance?.localIdentifier, localID)
        XCTAssertFalse(surface.localProvenance?.modificationRevision.isEmpty ?? true)
        let provenance = try XCTUnwrap(surface.localProvenance)
        let root = FileManager.default.temporaryDirectory.appending(path: "paired-provider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = BackupIndex(fileURL: root.appending(path: "pair.json"))
        let account = try XCTUnwrap(client.mediaDisplayScope.accountID)
        _ = await index.load(serverHost: client.serverKey, userId: account)
        let revisionBits = try XCTUnwrap(UInt64(provenance.modificationRevision))
        await index.setHashed(localId: localID, isLivePhoto: false, primaryChecksum: "synthetic-fixture",
            motionChecksum: nil, modificationDate: Date(timeIntervalSinceReferenceDate: Double(bitPattern: revisionBits)))
        await index.setPrimaryRemoteId(localId: localID, value.id)
        let validator: LocalSurfaceValidator = { captured in
            await index.matchesLaunchPair(captured, server: client.serverKey, account: account)
        }
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "paired-provider",
            sort: "desc", anchor: value.id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        let store = LaunchPreviewStore(root: root.appending(path: "pack"))
        let coordinator = MediaPresentationCoordinator(store: store)
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client,
            surfaceProvider: { tile.checkpointSurface(for: $0, client: client) }, validateLocalSurface: validator)
        defer { coordinator.cancelCheckpoint() }
        var saved: [PreparedImageRecord] = []
        for _ in 0..<100 {
            tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
                pairedLocalIdentifier: localID, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
                client: client, generation: 0, targetPixelSize: pixels)
            if case .complete(_, let records) = try await store.restore(scope: client.mediaDisplayScope,
                context: .init(access: surface.access, protectedDataAvailable: true, filter: snapshot.filter, layout: snapshot.layout)) {
                saved = records; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(saved.first?.localProvenance, provenance, "The actual tile provider must persist its bound source revision")
        let restarted = MediaPresentationCoordinator(store: LaunchPreviewStore(root: root.appending(path: "pack")))
        let restored = try await restarted.restore(client: client, filter: snapshot.filter, layout: snapshot.layout,
            validateLocalSurface: validator)
        XCTAssertEqual(restored?.images.count, 1)
        let aliasURL = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: aliasURL, targetPixelSize: pixels))
        let beforeRebind = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
        var revised = value; revised.thumbhash = "revision-two"
        tile.projectImage(asset: revised, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: pixels)
        XCTAssertNil(tile.checkpointSurface(for: MediaPresentationCoordinator.gridKey(asset: revised, client: client, pixels: pixels), client: client),
            "Rebinding cannot tag the old UIImage with a new committed key")
        XCTAssertFalse(beforeRebind.isCurrent(), "A captured surface must be revoked when its tile is reused/rebound")
        LocalImageLoader.shared.noteLibraryChange()
        XCTAssertNil(ImageLoader.shared.cachedImage(for: aliasURL, targetPixelSize: pixels),
            "A remote cache alias must not bypass captured PhotoKit permission generation")
        XCTAssertFalse(surface.isCurrent())
        _ = await index.markRemoteEdited([value.id])
        let revoked = try await restarted.restore(client: client, filter: snapshot.filter, layout: snapshot.layout,
            validateLocalSurface: validator)
        XCTAssertEqual(revoked?.images.count, 0, "Revoked renderable pairing must reject persisted local bytes")
        let changedRevision = LocalSurfaceProvenance(localIdentifier: localID,
            modificationRevision: "not-the-captured-local-revision", remoteIdentifier: value.id)
        var staleRecord = try XCTUnwrap(saved.first)
        staleRecord.localProvenance = changedRevision
        let stale = try await restarted.prepareViewport(request: .init(snapshot: snapshot, assets: [value], records: [staleRecord],
            client: client, access: MediaPresentationCoordinator.access(for: client), checkpointMiss: false,
            validateLocalSurface: { _ in true }))
        XCTAssertTrue(stale.images.isEmpty, "An external local edit must invalidate the captured resource revision even if pairing is unchanged")
        staleRecord.localProvenance = .init(localIdentifier: "inaccessible-\(UUID())",
            modificationRevision: provenance.modificationRevision, remoteIdentifier: value.id)
        let inaccessible = try await restarted.prepareViewport(request: .init(snapshot: snapshot, assets: [value], records: [staleRecord],
            client: client, access: MediaPresentationCoordinator.access(for: client), checkpointMiss: false,
            validateLocalSurface: { _ in true }))
        XCTAssertTrue(inaccessible.images.isEmpty, "Unavailable PhotoKit access cannot authorize old persisted local bytes")
        let manifestURL = root.appending(path: "pack")
        let completeFile = try XCTUnwrap(FileManager.default.enumerator(at: manifestURL,
            includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "complete.json" })
        var legacyManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: completeFile)) as? [String: Any])
        legacyManifest["version"] = 1
        try JSONSerialization.data(withJSONObject: legacyManifest).write(to: completeFile)
        if case .complete = try await store.restore(scope: client.mediaDisplayScope,
            context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                filter: snapshot.filter, layout: snapshot.layout)) { XCTFail("A legacy pack without provider evidence cannot claim a complete current viewport") }
    }

    func testEditedPairedOriginalIsExcludedWhileCurrentRemoteEditedSurfaceIsEligible() async throws {
        let (localID, original) = try await createSurfaceFixture()
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("edited-surface-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        var value = asset(); value.isEdited = true
        let pixels: CGFloat = 416, key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        LocalImageLoader.shared.installPrepared(original, localIdentifier: localID, targetPixelSize: pixels,
            cacheScope: MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels),
            permission: LocalImageLoader.shared.permissionGeneration)
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: localID, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 0, targetPixelSize: pixels)
        XCTAssertNil(tile.checkpointSurface(for: key, client: client), "A paired original cannot represent a committed remote edit")
        ImageLoader.shared.installPrepared(solidImage(pixels: 416),
            url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: pixels, client: client)
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: nil, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil),
            client: client, generation: 1, targetPixelSize: pixels)
        let surface = try XCTUnwrap(tile.checkpointSurface(for: key, client: client),
            "An actual current remote edited render remains eligible")
        XCTAssertNil(surface.localProvenance)
        ImageLoader.shared.invalidate(asset: value, client: client)
        XCTAssertFalse(surface.isCurrent())
        XCTAssertNil(tile.checkpointSurface(for: key, client: client))
    }

    func testPairedTileRenewsItsCapturedAccessWhenTheSameSourceIsProjectedAgain() async throws {
        let (localID, image) = try await createSurfaceFixture()
        let remoteBytes = try XCTUnwrap(solidImage(pixels: 512).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: remoteBytes) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "renewed-source-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), pixels: CGFloat = 416
        let scope = MediaPresentationCoordinator.localScope(asset: value, client: client, pixels: pixels)
        let source = AssetThumbnailSource(assetID: value.id, localIdentifier: nil, pairedLocalIdentifier: localID,
            pairedRemoteIdentifier: nil, unavailableLocalIdentifier: nil)
        let tile = TimelineTileView(frame: .init(x: 0, y: 0, width: 132, height: 132))
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: pixels)
        LocalImageLoader.shared.installPrepared(image, localIdentifier: localID, targetPixelSize: pixels,
            cacheScope: scope, permission: LocalImageLoader.shared.permissionGeneration)
        tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
        for _ in 0..<100 {
            tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
            if tile.checkpointSurface(for: key, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(tile.checkpointSurface(for: key, client: client))
        LocalImageLoader.shared.noteLibraryChange()
        XCTAssertNil(tile.checkpointSurface(for: key, client: client))
        LocalImageLoader.shared.installPrepared(image, localIdentifier: localID, targetPixelSize: pixels,
            cacheScope: scope, permission: LocalImageLoader.shared.permissionGeneration)
        tile.projectImage(asset: value, source: source, client: client, generation: 0, targetPixelSize: pixels)
        for _ in 0..<100 {
            if tile.checkpointSurface(for: key, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(tile.checkpointSurface(for: key, client: client),
            "Identical content/source/load generations must still renew a revoked access binding")
        tile.applyLocalAccessRevision(nil)
        XCTAssertNil((tile.makeZoomReplica() as? UIImageView)?.image,
            "Loss of read access/hidden state must clear the actual locally derived visible UIImage")
        XCTAssertNil(tile.checkpointSurface(for: key, client: client))
        _ = ImageLoader.shared.invalidateSubjects(client: client, subjects: [.remoteAsset(value.id)], retiresSourceRevisions: false)
        let currentKey = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: pixels)
        XCTAssertNotEqual(currentKey.contentGeneration, key.contentGeneration)
        tile.projectImage(asset: value, source: .init(assetID: value.id, localIdentifier: nil,
            pairedLocalIdentifier: localID, pairedRemoteIdentifier: nil, unavailableLocalIdentifier: localID),
            client: client, generation: 0, targetPixelSize: pixels)
        for _ in 0..<100 {
            if tile.checkpointSurface(for: currentKey, client: client) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let remote = try XCTUnwrap(tile.checkpointSurface(for: currentKey, client: client),
            "After local revocation a genuine authorized endpoint render must bind under fresh content/access authority")
        XCTAssertNil(remote.localProvenance)
        XCTAssertEqual(remote.access, MediaPresentationCoordinator.access(for: client))
        XCTAssertFalse(server.received.isEmpty)
        XCTAssertNotNil((tile.makeZoomReplica() as? UIImageView)?.image)
    }

    func testPhotoKitChangeRetainsUnchangedDecodedImagesAndAccessGeneration() async throws {
        let (changedID, image) = try await createSurfaceFixture()
        let (unchangedID, _) = try await createSurfaceFixture()
        let changedAsset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [changedID], options: nil).firstObject)
        let loader = LocalImageLoader.fixture(manager: PHCachingImageManager())
        let permission = loader.permissionGeneration
        for id in [changedID, unchangedID] {
            loader.installPrepared(image, localIdentifier: id, targetPixelSize: 416, cacheScope: "change-fixture",
                permission: permission, sourceRevision: try XCTUnwrap(LocalImageLoader.currentModificationRevision(id)))
        }
        let unchanged = try XCTUnwrap(loader.cachedBoundImage(localIdentifier: unchangedID, targetPixelSize: 416,
            contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: "change-fixture"))
        let observer = SurfacePhotoChangeObserver()
        PHPhotoLibrary.shared().register(observer)
        defer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        try await favoriteSyntheticSurfacePhoto(identifier: changedID)
        var notification: PHChange?
        for _ in 0..<200 {
            notification = observer.changes.withLock { $0.first { $0.changeDetails(for: changedAsset) != nil } }
            if notification != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        loader.noteLibraryChange(try XCTUnwrap(notification))
        XCTAssertEqual(loader.permissionGeneration, permission, "An unrelated photo change must not retire every mounted image")
        XCTAssertTrue(unchanged.isCurrent)
        XCTAssertTrue(loader.cachedImage(localIdentifier: unchangedID, targetPixelSize: 416,
            contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: "change-fixture") === image)
        XCTAssertNil(loader.cachedImage(localIdentifier: changedID, targetPixelSize: 416,
            contentMode: DeviceTileRender.contentMode, coversTarget: DeviceTileRender.coversTile, cacheScope: "change-fixture"),
            "The photo whose modification revision advanced must still invalidate its own cache")
    }

    func testUIKitViewportReplacesShorterSwiftUIGeometryBeforeRestoration() {
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])
        model.launchLayout = .init(width: 402, height: 724, scale: 3, columns: 3)
        let grid = TimelineGridView(model: model, layoutBox: TimelineRowLayoutBox())
        grid.contentInsetAdjustmentBehavior = .never
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        grid.layoutSubviews()
        XCTAssertEqual(model.launchLayout?.width, 402)
        XCTAssertEqual(model.launchLayout?.height, 874,
            "Startup must cover the actual UIKit viewport, including the area extending behind bars")
        grid.contentInset = UIEdgeInsets(top: 30, left: 0, bottom: 20, right: 0)
        grid.layoutSubviews()
        XCTAssertEqual(model.launchLayout?.height, 824,
            "A real inset change must advance restoration geometry before preparing another viewport")
    }

    func testRestoredMiddleMonthKeepsGlobalSlotPhaseAsOtherBucketsMaterialize() throws {
        let values = (0..<120).map { index in
            Asset(id: "slot-\(index)", ownerId: "slot-fixture", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, thumbhash: "slot-revision", fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        }
        func full(_ index: Int) -> TimelineSection {
            .init(id: "month-\(index)", monthTitle: "month-\(index)", count: 10,
                days: [.init(id: "day-\(index)", title: "", assets: Array(values[(index * 10)..<(index * 10 + 10)]))])
        }
        var sections = (0..<12).map { TimelineSection(id: "month-\($0)", monthTitle: "month-\($0)", count: 10, days: nil) }
        sections[8].days = [.init(id: "day-8", title: "", assets: Array(values[87..<90]))]
        sections[8].leadingUnloadedAssetCount = 7
        sections[9] = full(9)
        sections[10].days = [.init(id: "day-10", title: "", assets: Array(values[100..<108]))]
        sections[10].trailingUnloadedAssetCount = 2
        let side = AssetGridLayout.tileSide(viewportWidth: 402, columns: 3)
        let expectedIDs = Array(values[87..<108]).map(\.id)
        for stage in 0..<4 {
            if stage == 1 { for index in 0..<6 { sections[index] = full(index) } }
            if stage == 2 { for index in 6..<8 { sections[index] = full(index) } }
            if stage == 3 { sections = (0..<12).map(full) }
            let rows = TimelineModel.compactProjection(sections, columns: 3).rows
            let anchor = try XCTUnwrap(rows.firstIndex { row in
                if case .tiles(_, let runs) = row { return runs.flatMap(\.assets).contains { $0.id == "slot-87" } }; return false
            })
            let layout = TimelineRowLayout.build(rows: rows, side: side, version: stage)
            XCTAssertEqual(layout.starts[anchor], 29 * (side + 2), accuracy: 0.001,
                "Stage\(stage): omitted leading assets must retain their original slots")
            let visible = rows[anchor...].prefix(7).flatMap { row -> [Asset] in
                if case .tiles(_, let runs) = row { return runs.flatMap(\.assets) }; return []
            }
            XCTAssertEqual(visible.map(\.id), expectedIDs, "Stage\(stage): loaded bucket boundaries cannot regroup actual W0")
            if case .tiles(_, let runs) = rows[anchor] {
                XCTAssertEqual(runs.first?.colStart, 0)
                XCTAssertEqual(runs.first?.assets.first?.id, "slot-87")
            }
            // With saved anchorOffset33.333 the actual first tile rectangle
            // must stay at this same y through each metadata-only stage.
            let restoredOffset = 29 * (side + 2) + 33.333
            XCTAssertEqual(layout.starts[anchor] - restoredOffset, -33.333, accuracy: 0.001)
        }
    }

    func testShortPhotosCanvasKeepsFirstRowBelowRegularBarAndAccessible() async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let parent = try XCTUnwrap(window.rootViewController)
        func tiles(in view: UIView) -> [TimelineTileView] {
            (view as? TimelineTileView).map { [$0] } ?? view.subviews.flatMap { tiles(in: $0) }
        }
        func dismiss(_ controller: UIViewController) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: false) { continuation.resume() }
            }
        }
        for count in [1, 2, 6] {
            let values = (0..<count).map { index in
                Asset(id: "short-\(count)-\(index)", ownerId: "short-fixture", isImage: true, isFavorite: false,
                    isTrashed: false, visibility: .timeline, fileCreatedAt: Date(timeIntervalSince1970: Double(index)),
                    localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
            }
            let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: values)
            model.showsDateHeaders = false
            let native = TimelineGridViewController(model: model, layoutBox: TimelineRowLayoutBox())
            native.title = "Short photos"
            let navigation = UINavigationController(rootViewController: native)
            navigation.navigationBar.prefersLargeTitles = false
            navigation.modalPresentationStyle = .fullScreen
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parent.present(navigation, animated: false) { continuation.resume() }
            }
            do {
                native.loadViewIfNeeded()
                native.grid.usesFullPhotosCanvas = true
                native.grid.contentInsetAdjustmentBehavior = .never
                navigation.view.layoutIfNeeded()
                native.view.layoutIfNeeded()
                let side = AssetGridLayout.tileSide(viewportWidth: native.grid.bounds.width, columns: 3)
                native.grid.update(side: side, tailPadding: 0, context: .init(session: SessionStore(), columns: 3,
                    targetPixelSize: 416, showsBackupBadge: false, usesOriginalAspectRatio: false, isSelecting: false,
                    selection: [], reduceMotion: true, registry: AssetTileRegistry(), motion: GridMotion(),
                    isSelectable: { _ in true }, isSelectableAssetID: { _ in true },
                    actions: .init(toggleSelection: { _ in }, menu: { _ in UIMenu(children: []) },
                        makeViewer: { _, _, _ in nil }), toggleDay: { _, _ in }), animated: false)
                native.grid.layoutIfNeeded()
                let first = try XCTUnwrap(tiles(in: native.grid).first { $0.asset?.id == values.first?.id })
                let frame = first.convert(first.bounds, to: window)
                let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                XCTAssertGreaterThanOrEqual(frame.minY, bar.maxY - 0.5, "\(count) items: first photo must not hide behind the regular navigation bar")
                XCTAssertTrue(first.isAccessibilityElement)
                let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                XCTAssertTrue(hit === first || hit?.isDescendant(of: first) == true, "\(count) items: the first tile remains an actual hit target")
                XCTAssertEqual(model.launchLayout?.height, Double(native.grid.bounds.height),
                    "Content padding must not shrink the canonical viewport")
            } catch {
                await dismiss(navigation)
                throw error
            }
            await dismiss(navigation)
            XCTAssertNil(parent.presentedViewController, "Each short-library fixture must finish its UIKit presentation")
        }
    }

    func testCompactPartialTailAndInconsistentSlotEvidenceAreHonest() {
        let values = (0..<11).map { index in
            Asset(id: "tail-\(index)", ownerId: "slot-fixture", isImage: true, isFavorite: false,
                isTrashed: false, visibility: .timeline, fileCreatedAt: Date(timeIntervalSince1970: Double(index)),
                localOffsetHours: 0, livePhotoVideoId: nil, ratio: 1, city: nil, country: nil)
        }
        var partial = TimelineSection(id: "tail", monthTitle: "tail", count: 7,
            days: [.init(id: "tail-day", title: "", assets: Array(values[9..<11]))])
        partial.leadingUnloadedAssetCount = 5
        let prefix = TimelineSection(id: "prefix", monthTitle: "prefix", count: 4, days: nil)
        let rows = TimelineModel.compactProjection([prefix, partial], columns: 3).rows
        let real = rows.flatMap { row -> [Asset] in if case .tiles(_, let runs) = row { return runs.flatMap(\.assets) }; return [] }
        XCTAssertEqual(real.map(\.id), ["tail-9", "tail-10"], "The final short row must not fabricate a third tile")
        partial.leadingUnloadedAssetCount = 6 //6 omitted +2 loaded cannot fit the advertised7 slots.
        let invalidRows = TimelineModel.compactProjection([prefix, partial], columns: 3).rows
        XCTAssertTrue(invalidRows.allSatisfy { if case .placeholder = $0 { return true }; return false },
            "Changed/mismatching source counts must remain placeholders rather than guessed committed cells")
    }

    func testConfiguredGridProviderCannotFallBackToAnotherRemoteRepresentation() async throws {
        let client = client(UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), key = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        ImageLoader.shared.installPrepared(solidImage(pixels: 416),
            url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: 416, client: client)
        let root = FileManager.default.temporaryDirectory.appending(path: "selected-provider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchPreviewStore(root: root), coordinator = MediaPresentationCoordinator(store: store)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "selected-provider",
            sort: "desc", anchor: value.id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client, surfaceProvider: { _ in nil })
        defer { coordinator.cancelCheckpoint() }
        try await Task.sleep(for: .milliseconds(500))
        if case .complete = try await store.restore(scope: client.mediaDisplayScope,
            context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                filter: snapshot.filter, layout: snapshot.layout)) {
            XCTFail("A selected grid provider miss must not be replaced by a different cached remote representation")
        }
    }

    func testRepeatedStationaryViewportNotificationsDoNotStarveDurableCheckpoint() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("stationary-fixture-\(UUID())")
        ImageLoader.shared.configure(client: client)
        let coordinator = MediaPresentationCoordinator.shared
        coordinator.cancelCheckpoint()
        defer { coordinator.cancelCheckpoint(); ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), filterKey = "stationary-\(UUID())"
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [value])
        model.suppliedLaunchContext = filterKey
        model.attach(client)
        let layout = LaunchViewportSnapshot.Layout(width: 402, height: 874, scale: 3, columns: 3)
        ImageLoader.shared.installPrepared(solidImage(pixels: 416),
            url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: 416, client: client)
        let rowIDs = model.rows.compactMap { row -> String? in
            if case .tiles = row { return row.id }; return nil
        }
        XCTAssertFalse(rowIDs.isEmpty)
        var completedDuringNotifications = false
        for _ in 0..<60 {
            model.checkpointViewport(rowIDs: rowIDs, layout: layout, pixels: 416, anchorOffset: 0, stable: true)
            if case .complete = try await LaunchPreviewStore.shared.restore(scope: client.mediaDisplayScope,
                context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                    filter: filterKey, layout: layout)) {
                completedDuringNotifications = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(completedDuringNotifications,
            "Repeated notifications of the same semantic viewport must not cancel its250ms checkpoint indefinitely")
    }

    func testPermissionCancelledCheckpointCanRetryTheSameViewport() async throws {
        let client = client(UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let value = asset(), key = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        ImageLoader.shared.installPrepared(solidImage(pixels: 416),
            url: client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash), targetPixelSize: 416, client: client)
        let root = FileManager.default.temporaryDirectory.appending(path: "permission-checkpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchPreviewStore(root: root), coordinator = MediaPresentationCoordinator(store: store)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "permission-retry",
            sort: "desc", anchor: value.id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client)
        LocalImageLoader.shared.noteLibraryChange()
        try await Task.sleep(for: .milliseconds(350))
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client)
        defer { coordinator.cancelCheckpoint() }
        var complete = false
        for _ in 0..<100 {
            if case .complete = try await store.restore(scope: client.mediaDisplayScope,
                context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                    filter: snapshot.filter, layout: snapshot.layout)) { complete = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(complete, "A completed/cancelled task handle must not suppress a fresh authorized checkpoint")
    }

    func testTimelineRestoresPreparedW0AndAnchorWhileServerIsOffline() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 503) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "launch-flow-\(UUID())")
        client.confirmMediaAccount("alice")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let asset = asset()
        let filter = TimelineFilter(order: "launch-flow-\(UUID())")
        let filterKey = try XCTUnwrap(TimelineCache.key(for: filter))
        let layout = LaunchViewportSnapshot.Layout(width: 390, height: 700, scale: 3, columns: 3)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 416, height: 416)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 416, height: 416))
        }
        let key = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 416)
        let encoded = await MediaPresentationCoordinator.encode(image: image, key: key)
        let record = try XCTUnwrap(encoded)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: filterKey,
            sort: "desc", anchor: asset.id, layout: layout, visibleKeys: [key], metadata: try JSONEncoder().encode([asset]))
        _ = try await LaunchPreviewStore.shared.checkpoint(snapshot: snapshot, images: [record])
        let model = TimelineModel(filter: filter)
        model.launchLayout = layout
        model.attach(client, preparesLaunchViewport: true)
        await model.load()
        XCTAssertEqual(model.flatAssets.map(\.id), [asset.id])
        XCTAssertEqual(model.pendingLaunchAnchor?.id, asset.id)
        XCTAssertNotNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash), targetPixelSize: 416)?.cgImage)
        XCTAssertTrue(server.received.allSatisfy { $0.method == "GET" })
        try await LaunchPreviewStore.shared.invalidate(scope: client.mediaDisplayScope)
    }

    func testKnownCommittedRevisionRetiresLaunchPackBeforeAnotherCheckpoint() async throws {
        let client = client(UUID().uuidString)
        defer { client.invalidate() }
        let saved = try await makeSavedPack(client: client)
        let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [asset()])
        model.suppliedLaunchContext = "edit-regression"
        model.attach(client)
        model.updateAssets(ids: [asset().id]) { $0.isFavorite = true }
        guard case .complete = try await readSavedPack(client: client, snapshot: saved) else {
            return XCTFail("Favorite-only metadata must not retire image content")
        }
        model.updateAssets(ids: [asset().id]) { $0.thumbhash = "revision-two" }
        let restartedStore = LaunchPreviewStore(root: LaunchPreviewStore.rootDirectory)
        let read = try await restartedStore.restore(scope: client.mediaDisplayScope,
            context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                filter: saved.filter, layout: saved.layout))
        if case .complete = read { XCTFail("A known old committed version survived an immediate restart") }
    }

    func testRealtimeEditInvalidationIsDurableBeforeReconciliation() async throws {
        let client = client(UUID().uuidString)
        defer { client.invalidate() }
        let saved = try await makeSavedPack(client: client)
        await client.invalidateMediaCache()
        let read = try await readSavedPack(client: client, snapshot: saved)
        if case .complete = read { XCTFail("Realtime edit kept the old startup revision authorized") }
    }

    func testRemovalRetiresEverySizedThumbnailAndPreviewVariant() async throws {
        let client = client(UUID().uuidString)
        client.confirmMediaAccount("alice-fixture-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let image = solidImage(pixels: 1280)
        let variants: [(String, CGFloat)] = [("thumbnail", 768), ("thumbnail", 1280), ("preview", 384), ("preview", 768)]
        for (variant, pixels) in variants {
            ImageLoader.shared.installPrepared(image, url: client.thumbnailURL(assetID: asset().id, size: variant,
                cacheKey: asset().thumbhash), targetPixelSize: pixels, client: client)
            XCTAssertNotNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset().id, size: variant,
                cacheKey: asset().thumbhash), targetPixelSize: pixels), "Retirement must start from a populated variant")
        }
        ImageLoader.shared.invalidate(asset: asset(), client: client)
        for (variant, pixels) in variants {
            XCTAssertNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset().id, size: variant,
                cacheKey: asset().thumbhash), targetPixelSize: pixels), "Surviving \(variant) at \(pixels) pixels")
        }
    }

    func testRemovalCancelsLateVariantAndCannotRefillStableCache() async throws {
        let bytes = try XCTUnwrap(solidImage(pixels: 768).jpegData(compressionQuality: 0.8))
        let server = try LocalHTTPServer { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return .init(headers: ["Content-Type": "image/jpeg"], body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let first = ImoraClient(apiURL: server.apiURL, accessToken: "retire-\(UUID())")
        let userID = "alice-fixture-\(UUID())"
        first.confirmMediaAccount(userID)
        ImageLoader.shared.configure(client: first)
        defer { ImageLoader.shared.configure(client: nil); first.invalidate() }
        let url = first.thumbnailURL(assetID: asset().id, size: "preview", cacheKey: asset().thumbhash)
        let loading = Task { try await ImageLoader.shared.image(for: url, targetPixelSize: 768) }
        for _ in 0..<100 where server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(server.received.isEmpty)
        ImageLoader.shared.invalidate(asset: asset(), client: first)
        do { _ = try await loading.value; XCTFail("Retired in-flight content was published") } catch {}
        XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 768))
        let restart = ImoraClient(apiURL: server.apiURL, accessToken: "new-runtime-\(UUID())")
        restart.confirmMediaAccount(userID)
        ImageLoader.shared.configure(client: restart)
        let disk = await ImageLoader.shared.diskImage(for: restart.thumbnailURL(assetID: asset().id, size: "preview",
            cacheKey: asset().thumbhash), targetPixelSize: 768)
        XCTAssertNil(disk)
        restart.invalidate()
    }

    func testOrdinaryRemoteLandscapePreviewFormsQualifiedDurableGridPack() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func jpeg(_ size: CGSize) -> Data {
            UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
        }
        let thumbnail = jpeg(.init(width: 333, height: 250)), preview = jpeg(.init(width: 2048, height: 1536))
        let server = try LocalHTTPServer { request in
            .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("size=preview") ? preview : thumbnail)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "landscape-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        var value = asset(); value.ratio = 4.0 / 3.0
        let url = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
        let loaded = try await ImageLoader.shared.gridThumbnail(thumbnailURL: url,
            previewURL: client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash),
            targetPixelSize: 416, aspectRatio: value.ratio)
        XCTAssertGreaterThanOrEqual(min(loaded.size.width, loaded.size.height) * loaded.scale, 416)
        let grid = try XCTUnwrap(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 416))
        XCTAssertGreaterThanOrEqual(min(grid.size.width, grid.size.height) * grid.scale, 416,
            "A displayed adequate preview must feed the grid checkpoint; 333×250 raw endpoint bytes do not cover416px")
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "landscape-\(UUID())",
            sort: "desc", anchor: value.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        let coordinator = MediaPresentationCoordinator()
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client)
        var complete = false
        for _ in 0..<100 {
            if case .complete = try await readSavedPack(client: client, snapshot: snapshot) { complete = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        coordinator.cancelCheckpoint()
        XCTAssertTrue(complete, "Ordinary landscape fallback never made a qualified durable pack")
    }

    func testDiskOnlyPreviewReadUsesPersistedEndpointBytesAtRequestedSizeAfterMemoryEviction() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: .init(width: 2048, height: 1536), format: format)
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
            }
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "image/jpeg"], body: bytes) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "disk-read-\(UUID())")
        client.confirmMediaAccount("disk-read-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        var value = asset(); value.ratio = 4.0 / 3.0
        let url = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
        let shown = try await ImageLoader.shared.image(for: url, targetPixelSize: 1024)
        XCTAssertGreaterThanOrEqual(min(shown.size.width, shown.size.height) * shown.scale, 768)
        let requests = server.received.count
        server.stop()
        try await assertEndpointBytesFlushed(bytes, url: url, client: client, asset: value)
        ImageLoader.shared.configure(client: client) // Evict decoded memory; retain real endpoint disk bytes.
        XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 1024))
        let disk = await ImageLoader.shared.diskImage(for: url, targetPixelSize: 768)
        let restored = try XCTUnwrap(disk, "Disk-only read must find storeOriginalData's unsized endpoint key")
        XCTAssertGreaterThanOrEqual(min(restored.size.width, restored.size.height) * restored.scale, 576)
        XCTAssertLessThanOrEqual(max(restored.size.width, restored.size.height) * restored.scale, 768,
            "Finding endpoint bytes must retain the requested decode size")
        XCTAssertNil(ImageLoader.shared.cachedImage(for: url, targetPixelSize: 768), "Disk lookup must not publish unchecked memory")
        let absentURL = client.thumbnailURL(assetID: "absent-\(UUID())", size: "preview", cacheKey: value.thumbhash)
        let absent = await ImageLoader.shared.diskImage(for: absentURL, targetPixelSize: 768)
        XCTAssertNil(absent, "A genuinely missing disk entry must remain an explicit cache miss")
        ImageLoader.shared.invalidate(asset: value, client: client)
        let retired = await ImageLoader.shared.diskImage(for: url, targetPixelSize: 768)
        XCTAssertNil(retired, "An old endpoint key must not refill a newer committed generation")
        XCTAssertEqual(server.received.count, requests, "Disk-only preparation must never request the network")
    }

    func testDiskResidentLandscapeCheckpointsAfterDecodedMemoryIsEvicted() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func jpeg(_ width: CGFloat, _ height: CGFloat) -> Data {
            UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format)
                .jpegData(withCompressionQuality: 0.8) { context in
                    UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
        }
        let thumbnail = jpeg(333, 250), preview = jpeg(2048, 1536)
        let server = try LocalHTTPServer { request in
            .init(headers: ["Content-Type": "image/jpeg"], body: request.path.contains("size=preview") ? preview : thumbnail)
        }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "disk-checkpoint-\(UUID())")
        client.confirmMediaAccount("disk-checkpoint-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        var value = asset(); value.ratio = 4.0 / 3.0
        let url = client.thumbnailURL(assetID: value.id, cacheKey: value.thumbhash)
        let previewURL = client.thumbnailURL(assetID: value.id, size: "preview", cacheKey: value.thumbhash)
        let shown = try await ImageLoader.shared.gridThumbnail(thumbnailURL: url, previewURL: previewURL,
            targetPixelSize: 416, aspectRatio: value.ratio)
        XCTAssertGreaterThanOrEqual(min(shown.size.width, shown.size.height) * shown.scale, 416)
        let requests = server.received.count
        server.stop()
        try await assertEndpointBytesFlushed(preview, url: previewURL, client: client, asset: value)
        ImageLoader.shared.configure(client: client)
        XCTAssertNil(ImageLoader.shared.cachedGridImage(thumbnailURL: url, previewURL: previewURL,
            targetPixelSize: 416, aspectRatio: value.ratio))
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "disk-checkpoint-\(UUID())",
            sort: "desc", anchor: value.id, layout: .init(width: 402, height: 874, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        let root = FileManager.default.temporaryDirectory.appending(path: "disk-checkpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchPreviewStore(root: root), coordinator = MediaPresentationCoordinator(store: LaunchPreviewStore(root: root))
        coordinator.checkpoint(snapshot: snapshot, assets: [value], client: client)
        defer { coordinator.cancelCheckpoint() }
        var complete = false
        for _ in 0..<100 {
            if case .complete = try await store.restore(scope: client.mediaDisplayScope,
                context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                    filter: snapshot.filter, layout: snapshot.layout)) { complete = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(complete, "A mounted adequate surface must remain checkpointable when decoded cache entries are evicted")
        XCTAssertEqual(server.received.count, requests, "Checkpoint must use existing disk derivatives without network")
        XCTAssertNotNil(shown.cgImage, "The displayed surface remains alive independently of decoded cache eviction")
    }

    func testLayoutAndSourceChangesCannotPublishSuspendedViewport() async throws {
        for change in ["layout", "source"] {
            let client = client(UUID().uuidString)
            ImageLoader.shared.configure(client: client)
            let snapshot = try await makeSavedPack(client: client)
            let model = TimelineModel(filter: TimelineFilter(), suppliedAssets: [])
            model.launchLayout = snapshot.layout
            model.suppliedLaunchContext = "initial-source"
            let gate = ImagePreparationGate(), image = solidImage(pixels: 416)
            let coordinator = MediaPresentationCoordinator(prepareImage: { _, key, _, _ in
                await gate.pause(); return (key, image)
            })
            let request = ViewportRequest(snapshot: snapshot, assets: [asset()], records: [], client: client,
                access: MediaPresentationCoordinator.access(for: client), checkpointMiss: false,
                isCurrent: { model.launchLayout == snapshot.layout && model.suppliedLaunchContext == "initial-source" })
            let loading = Task { try await coordinator.prepareViewport(request: request) }
            for _ in 0..<100 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            if change == "layout" { model.launchLayout = .init(width: 820, height: 700, scale: 2, columns: 5) }
            else { model.suppliedLaunchContext = "new-source" }
            await gate.release()
            do { _ = try await loading.value; XCTFail("Suspended \(change) viewport was published") } catch {}
            XCTAssertNil(ImageLoader.shared.cachedImage(for: client.thumbnailURL(assetID: asset().id,
                cacheKey: asset().thumbhash), targetPixelSize: 416))
            ImageLoader.shared.configure(client: nil); client.invalidate()
        }
    }

    func testRetiredUnseenSubjectCannotImportEpochZeroCredentialBytes() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 503) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "legacy-\(UUID())")
        client.confirmMediaAccount("alice-fixture-\(UUID())")
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let url = client.thumbnailURL(assetID: asset().id, cacheKey: asset().thumbhash)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let provisional = StableMediaScope.credential(try XCTUnwrap(client.offlineAccountKey), server: client.serverKey)
        let scopeHash = MediaDisplayKeyV1.digest(try encoder.encode(provisional))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var legacy = ImageRequest(url: url)
        legacy.imageID = "media-v1|\(scopeHash)|\(components.percentEncodedPath)|\(components.percentEncodedQuery ?? "")"
        legacy.thumbnail = .init(maxPixelSize: 768)
        let keyPipeline = ImagePipeline(configuration: .init())
        let dataKey = keyPipeline.cache.makeDataCacheKey(for: legacy)
        let disk = try DataCache(name: "imora-images")
        disk.storeData(try XCTUnwrap(solidImage(pixels: 768).jpegData(compressionQuality: 0.8)), for: dataKey)
        disk.flush()
        // This subject is absent from W0 and the current request index. The
        // unchanged c metadata is not proof that legacy bytes remain current.
        ImageLoader.shared.invalidateSubjects(client: client, subjects: [.remoteAsset(asset().id)])
        do { _ = try await ImageLoader.shared.image(for: url, targetPixelSize: 768); XCTFail("Epoch0 derivative was imported after known retirement") } catch {}
        XCTAssertFalse(server.received.isEmpty, "Retired legacy bytes bypassed the unavailable authoritative endpoint")
    }

    func testExplicitCacheClearDoesNotRestoreRetiredNamespace() async throws {
        let client = client(UUID().uuidString)
        ImageLoader.shared.configure(client: client)
        defer { ImageLoader.shared.configure(client: nil); client.invalidate() }
        let key = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        ImageLoader.shared.invalidate(asset: asset(), client: client)
        let retired = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        try await LaunchPreviewStore.shared.removeAll()
        ImageLoader.shared.clearCache()
        let after = MediaPresentationCoordinator.gridKey(asset: asset(), client: client, pixels: 416)
        XCTAssertEqual(after.contentGeneration, retired.contentGeneration)
        XCTAssertNotEqual(after.contentGeneration, key.contentGeneration)
        XCTAssertFalse(key.isCurrentContent)
    }

    private func solidImage(pixels: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }

    private func createSurfaceFixture() async throws -> (String, UIImage) {
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized)
        let image = solidImage(pixels: 512), bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        return (try await createSyntheticSurfacePhoto(bytes: bytes), image)
    }

    /// A separate cache instance cannot see the live pipeline's staged writes.
    /// Poll its real on-disk endpoint key before evicting decoded memory.
    private func assertEndpointBytesFlushed(_ bytes: Data, url: URL, client: ImoraClient, asset: Asset) async throws {
        let disk = try DataCache(name: "imora-images")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let scope = MediaDisplayKeyV1.digest(try encoder.encode(client.mediaDisplayScope))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let generation = MediaPresentationCoordinator.gridKey(asset: asset, client: client, pixels: 1).contentGeneration
        let endpointKey = "media-v1|\(scope)|\(components.percentEncodedPath)|\(components.percentEncodedQuery ?? "")|generation:\(generation)"
        for _ in 0..<150 {
            if disk.cachedData(for: endpointKey) == bytes { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The real pipeline endpoint bytes never reached the persistent cache")
    }

    private func makeSavedPack(client: ImoraClient) async throws -> LaunchViewportSnapshot {
        let value = asset()
        let key = MediaPresentationCoordinator.gridKey(asset: value, client: client, pixels: 416)
        let encoded = await MediaPresentationCoordinator.encode(image: solidImage(pixels: 416), key: key)
        let record = try XCTUnwrap(encoded)
        let snapshot = LaunchViewportSnapshot(scope: client.mediaDisplayScope, source: "cloud", filter: "edit-\(UUID())",
            sort: "desc", anchor: value.id, layout: .init(width: 390, height: 700, scale: 3, columns: 3),
            visibleKeys: [key], metadata: try JSONEncoder().encode([value]))
        _ = try await LaunchPreviewStore.shared.checkpoint(snapshot: snapshot, images: [record])
        return snapshot
    }

    private func readSavedPack(client: ImoraClient, snapshot: LaunchViewportSnapshot) async throws -> LaunchPackReadResult {
        try await LaunchPreviewStore(root: LaunchPreviewStore.rootDirectory).restore(scope: client.mediaDisplayScope,
            context: .init(access: MediaPresentationCoordinator.access(for: client), protectedDataAvailable: true,
                filter: snapshot.filter, layout: snapshot.layout))
    }
}

private nonisolated final class SurfacePhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let changes = Mutex<[PHChange]>([])
    func photoLibraryDidChange(_ changeInstance: PHChange) { changes.withLock { $0.append(changeInstance) } }
}

private final class RecordingPhotoKitManager: PHCachingImageManager, @unchecked Sendable {
    struct Request: Equatable {
        let assetID: String
        let target: CGSize
        let mode: Int
        let delivery: Int
        let resize: Int
        let allowsNetwork: Bool
    }
    let requests = Mutex<[Request]>([])

    override func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
        options: PHImageRequestOptions?, resultHandler: @escaping (UIImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID {
        requests.withLock { $0.append(.init(assetID: asset.localIdentifier, target: targetSize, mode: contentMode.rawValue,
            delivery: options?.deliveryMode.rawValue ?? -1, resize: options?.resizeMode.rawValue ?? -1,
            allowsNetwork: options?.isNetworkAccessAllowed ?? false)) }
        return super.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options, resultHandler: resultHandler)
    }
}

/// Observe the real synchronous PhotoKit boundary. The optional override can
/// only deny this fixture's read; it cannot invent a PHAsset or grant access.
@MainActor
private func observePhotoKitFetches(for identifier: String, denyingRead: Bool = false, _ body: () -> Void) throws -> Int {
    let selector = NSSelectorFromString("fetchAssetsWithLocalIdentifiers:options:")
    let method = try XCTUnwrap(class_getClassMethod(PHAsset.self, selector))
    let original = method_getImplementation(method)
    typealias Fetch = @convention(c) (AnyObject, Selector, NSArray, PHFetchOptions?) -> AnyObject
    let fetch = unsafeBitCast(original, to: Fetch.self)
    let count = Mutex(0)
    let missing = ["unreadable-fixture-\(UUID())"] as NSArray
    let replacement: @convention(block) (AnyObject, NSArray, PHFetchOptions?) -> AnyObject = { receiver, identifiers, options in
        let observed = Thread.isMainThread && (identifiers as? [String])?.contains(identifier) == true
        if observed { count.withLock { $0 += 1 } }
        return fetch(receiver, selector, observed && denyingRead ? missing : identifiers, options)
    }
    let installed = imp_implementationWithBlock(replacement)
    method_setImplementation(method, installed)
    defer { method_setImplementation(method, original); imp_removeBlock(installed) }
    body()
    return count.withLock { $0 }
}

@concurrent
private nonisolated func favoriteSyntheticSurfacePhoto(identifier: String) async throws {
    let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).isFavorite = true }
}

@concurrent
private nonisolated func createSyntheticSurfacePhoto(bytes: Data) async throws -> String {
    let identifier = Mutex<String?>(nil)
    try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: bytes, options: nil)
        identifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
    }
    return try XCTUnwrap(identifier.withLock { $0 })
}

@concurrent
private nonisolated func createSyntheticSurfacePhotos(bytes: Data, count: Int) async throws -> [String] {
    let identifiers = Mutex<[String]>([])
    try await PHPhotoLibrary.shared().performChanges {
        for _ in 0..<count {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: bytes, options: nil)
            if let id = request.placeholderForCreatedAsset?.localIdentifier { identifiers.withLock { $0.append(id) } }
        }
    }
    let result = identifiers.withLock { $0 }
    XCTAssertEqual(result.count, count)
    return result
}


private actor ImagePreparationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor LaunchPreparationGate {
    private(set) var calls = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func prepare() async {
        calls += 1
        started.forEach { $0.resume() }; started.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForStart() async {
        if calls > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private nonisolated final class LaunchEvidenceFlag: Sendable { let value = Mutex(true) }
