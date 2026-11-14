import Foundation
import AVFoundation
import Synchronization
import XCTest
@testable import Imora

final class ControlledMediaCacheTests: XCTestCase {
    func testOrphansAreRemovedAndDownloadedCacheIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appending(path: "terminated-session")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("old-video".utf8).write(to: orphan.appending(path: "video"))
        let store = ControlledMediaStore(root: root, maximumBytes: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("file".utf8)) }
        try await server.start(); defer { server.stop() }
        let context = AccountRequestContext(apiURL: server.apiURL, token: "fixture")
        let request = try context.authorize(URLRequest(url: server.apiURL.appending(path: "first")))
        async let firstRequest = store.file(request: request, session: ControlledSession.noRedirect, context: context)
        async let sameRequest = store.file(request: request, session: ControlledSession.noRedirect, context: context)
        var first: ControlledMediaFile? = try await firstRequest
        var same: ControlledMediaFile? = try await sameRequest
        let firstURL = try XCTUnwrap(first?.url)
        XCTAssertEqual(first?.url, same?.url)
        XCTAssertEqual(ControlledMediaStore.diskUsage(root: root), 4)
        let second = try await store.file(request: context.authorize(URLRequest(url: server.apiURL.appending(path: "second"))), session: ControlledSession.noRedirect, context: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path), "An active consumer lost its file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        ControlledMediaStore.clearCache(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path), "Clear removed an active consumer")
        first = nil; same = nil
        // async-let storage retains results until scope exit; explicit lease
        // release is covered separately without async-let lifetime extension.
        await store.removeAll()
        XCTAssertEqual(ControlledMediaStore.diskUsage(root: root), 0)
    }

    func testReleasedConsumersBecomeEligibleForEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControlledMediaStore(root: root, maximumBytes: 4)
        let server = try LocalHTTPServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("file".utf8)) }
        try await server.start(); defer { server.stop() }
        let context = AccountRequestContext(apiURL: server.apiURL, token: "fixture")
        var first: ControlledMediaFile? = try await store.file(request: context.authorize(URLRequest(url: server.apiURL.appending(path: "a"))), session: ControlledSession.noRedirect, context: context)
        let path = try XCTUnwrap(first?.url)
        var playbackAsset: AVURLAsset? = first?.makeAsset()
        first = nil
        let second = try await store.file(request: context.authorize(URLRequest(url: server.apiURL.appending(path: "b"))), session: ControlledSession.noRedirect, context: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(playbackAsset?.url, path)
        playbackAsset = nil
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path.path) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(ControlledMediaStore.diskUsage(root: root), 4)
    }
}

extension ControlledMediaCacheTests {
    func testResponseStartedBeforeEditCannotReinstallInvalidatedMedia() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try LocalHTTPServer { _ in
            _ = gate.wait(timeout: .now() + 5)
            return .init(headers: ["Content-Type": "video/mp4"], body: Data("old-file".utf8))
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControlledMediaStore(root: root)
        let context = AccountRequestContext(apiURL: server.apiURL, token: "fixture")
        let request = try context.authorize(URLRequest(url: server.apiURL.appending(path: "file")))
        let operation = Task { try await store.file(request: request, session: ControlledSession.noRedirect, context: context) }
        for _ in 0..<100 where server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.received.count, 1)
        await store.invalidateCachedFiles()
        gate.signal()
        switch await operation.result {
        case .success: XCTFail("A pre-edit response escaped invalidation")
        case .failure: break
        }
        XCTAssertEqual(ControlledMediaStore.diskUsage(root: root), 0)
    }
}
