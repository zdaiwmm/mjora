import XCTest
@testable import Imora

private func localDeltaAsset(_ id: String) -> DeviceAsset {
    DeviceAsset(localIdentifier: id, isVideo: false, isLivePhoto: false, isScreenshot: false, creationDate: nil,
        modificationDate: nil, isFavorite: false, durationMs: 0, pixelWidth: 10, pixelHeight: 10)
}
actor SyntheticLibraryDeltaSource: LocalLibraryDeltaSource {
    var events: [String] = []
    var permission = "authorized"
    var token = Data([1])
    func permissionScope() async -> String { permission }
    func currentToken() async throws -> Data { events.append("boundary"); return token }
    func fullScan() async throws -> [DeviceAsset] { events.append("scan"); return [localDeltaAsset("before")] }
    func changes(since token: Data) async throws -> LocalLibraryDelta {
        events.append("changes-\(token.first!)")
        self.token = Data([2])
        return LocalLibraryDelta(upserts: [localDeltaAsset("during")], deletedIDs: ["before"], nextToken: self.token)
    }
    func setPermission(_ value: String) { permission = value }
}
final class LocalLibraryDeltaStoreTests: XCTestCase, @unchecked Sendable {
    func testCapturesBoundaryBeforeFirstScanAndCommitsConsumedTokenAcrossColdStart() async throws {
        let source = SyntheticLibraryDeltaSource()
        let store = try SyncStateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
        let local = LocalLibraryDeltaStore(store: store, source: source)
        let delta = try await local.loadChanges()
        XCTAssertEqual(delta.upserts.map(\.localIdentifier), ["during"])
        XCTAssertEqual(delta.nextToken, Data([2]))
        let first = await source.events
        XCTAssertEqual(first, ["boundary", "scan", "changes-1"])
        let cold = LocalLibraryDeltaStore(store: store, source: source)
        _ = try await cold.loadChanges()
        let events = await source.events
        XCTAssertEqual(events.last, "changes-2")
        XCTAssertEqual(events.filter { $0 == "scan" }.count, 1)
    }
    func testPermissionChangesForceOneMetadataBaselineWithoutErasingSnapshot() async throws {
        let source = SyntheticLibraryDeltaSource()
        let store = try SyncStateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
        let local = LocalLibraryDeltaStore(store: store, source: source)
        _ = try await local.loadChanges()
        await source.setPermission("limited")
        do { _ = try await local.loadChanges(); XCTFail() } catch {}
        await source.setPermission("authorized")
        _ = try await local.loadChanges()
        _ = try await local.loadChanges()
        let events = await source.events
        XCTAssertEqual(events.filter { $0 == "scan" }.count, 2)
    }
    func testConcurrentConsumersShareOneScan() async throws {
        let source = SyntheticLibraryDeltaSource()
        let store = try SyncStateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
        let local = LocalLibraryDeltaStore(store: store, source: source)
        async let first = local.loadChanges()
        async let second = local.loadChanges()
        _ = try await (first, second)
        let events = await source.events
        XCTAssertEqual(events.filter { $0 == "scan" }.count, 1)
    }
}

extension LocalLibraryDeltaStoreTests {
    func testCorruptLocalSnapshotRunsOneMetadataRebuild() async throws {
        let source = SyntheticLibraryDeltaSource()
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite")
        let store = try SyncStateStore(fileURL: file)
        let local = LocalLibraryDeltaStore(store: store, source: source)
        _ = try await local.loadChanges()
        try corruptSyncFixtureDatabase(file, sql: "UPDATE sync_state SET value='corrupt' WHERE kind='local'")
        _ = try await local.loadChanges()
        _ = try await local.loadChanges()
        let events = await source.events
        XCTAssertEqual(events.filter { $0 == "scan" }.count, 2)
    }
}
