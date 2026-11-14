import Foundation
import Synchronization
import XCTest
@testable import Imora

final class ThumbnailRevisionTests: XCTestCase {
    func testQueuedProviderGetsItsOwnDeadlineAfterCapacity() async throws {
        let slots = ThumbnailLoadLimiter(limit: 2)
        let first = try await slots.acquire(), second = try await slots.acquire()
        let events = Mutex<[String]>([])
        let work = Task {
            try await ThumbnailProviderStart.run(acquireCapacity: {
                let permit = try await slots.acquire()
                await slots.release(permit)
            }, startProvider: { events.withLock { $0.append("provider") } },
               armDeadline: {
                   events.withLock { $0.append("deadline") }
                   Task {
                       try? await Task.sleep(for: .milliseconds(20))
                       events.withLock { $0.append("expired") }
                   }
               })
        }
        // No provider-stall interval may begin while both local slots are held.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(events.withLock { $0 }, [])
        await slots.release(first)
        try await work.value
        XCTAssertEqual(events.withLock { $0 }, ["provider", "deadline"])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(events.withLock { $0 }, ["provider", "deadline", "expired"])
        await slots.release(second)
    }

    func testCancellationWhileQueuedStartsNeitherProviderNorDeadline() async throws {
        let slots = ThumbnailLoadLimiter(limit: 1)
        let permit = try await slots.acquire()
        let events = Mutex<[String]>([])
        let work = Task {
            try await ThumbnailProviderStart.run(acquireCapacity: {
                let acquired = try await slots.acquire(); await slots.release(acquired)
            }, startProvider: { events.withLock { $0.append("provider") } },
               armDeadline: { events.withLock { $0.append("deadline") } })
        }
        try await Task.sleep(for: .milliseconds(20))
        work.cancel()
        do { try await work.value; XCTFail("Queued cancellation succeeded") } catch is CancellationError {} 
        XCTAssertEqual(events.withLock { $0 }, [])
        await slots.release(permit)
    }

    func testSameIdentityAndDimensionsWithNewModificationDateInvalidatesHeldImage() {
        let before = device(modified: 100).asAsset(backedUp: false)
        let after = device(modified: 101).asAsset(backedUp: false)
        XCTAssertNil(before.thumbhash)
        XCTAssertNotEqual(before.localImageVersion, after.localImageVersion)
        XCTAssertNotEqual(before, after, "UIKit configure must observe the edit")
        let oldKey = AssetThumbnailSource.localCacheScope(accountKey: "a", version: before.localImageVersion, pixels: 600)
        let newKey = AssetThumbnailSource.localCacheScope(accountKey: "a", version: after.localImageVersion, pixels: 600)
        XCTAssertNotEqual(oldKey, newKey, "A held SwiftUI/local load key must be invalidated")
    }

    func testPrefetchMatchesVisibleScopeAndAccountRevisionPixelChangesRemainIsolated() {
        let asset = device(modified: 100).asAsset(backedUp: false)
        let visible = AssetThumbnailSource.localCacheScope(accountKey: "a", version: asset.localImageVersion, pixels: 600)
        let warmed = AssetThumbnailSource.prefetchScope(accountKey: "a", version: asset.localImageVersion, pixels: 600)
        let cache = [warmed: "warm-bitmap"]
        XCTAssertEqual(cache[visible], "warm-bitmap", "Visible lookup must consume the warmed namespace")
        XCTAssertNil(cache[AssetThumbnailSource.localCacheScope(accountKey: "b", version: asset.localImageVersion, pixels: 600)])
        XCTAssertNil(cache[AssetThumbnailSource.localCacheScope(accountKey: "a", version: "edited", pixels: 600)])
        XCTAssertNil(cache[AssetThumbnailSource.localCacheScope(accountKey: "a", version: asset.localImageVersion, pixels: 900)])
    }

    private func device(modified: TimeInterval) -> DeviceAsset {
        DeviceAsset(localIdentifier: "same-local", isVideo: false, isLivePhoto: false, isScreenshot: false,
                    creationDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: modified),
                    isFavorite: false, durationMs: 0, pixelWidth: 1200, pixelHeight: 1200)
    }
}
