import XCTest
@testable import Imora

@MainActor
final class ImageScopePerformanceTests: XCTestCase {
    func testLocalNamespaceChangesWhenAnUnconfirmedCredentialBecomesVerified() throws {
        let client = ImoraClient(apiURL: URL(string: "https://scope.fixture.invalid/api")!, accessToken: UUID().uuidString)
        defer { client.invalidate() }
        let credential = try XCTUnwrap(client.offlineAccountKey)
        let provisional = AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384)
        client.confirmMediaAccount("fixture-alice")
        let confirmed = AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384)
        XCTAssertNotEqual(provisional, confirmed)
        XCTAssertEqual(confirmed, referenceScope(account: credential, version: "r1", pixels: 384))
        client.confirmMediaAccount("fixture-bob")
        XCTAssertNotEqual(confirmed, AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384))
    }

    func testNamespacesShareVerifiedAccountButKeepVersionsPixelsAndAccountsDistinct() throws {
        let url = URL(string: "https://scope.fixture.invalid/api")!
        let first = ImoraClient(apiURL: url, accessToken: UUID().uuidString)
        let renewed = ImoraClient(apiURL: url, accessToken: UUID().uuidString)
        let other = ImoraClient(apiURL: url, accessToken: UUID().uuidString)
        defer { first.invalidate(); renewed.invalidate(); other.invalidate() }
        first.confirmMediaAccount("fixture-alice")
        renewed.confirmMediaAccount("fixture-alice")
        other.confirmMediaAccount("fixture-bob")
        func scope(_ client: ImoraClient, version: String = "r1", pixels: CGFloat = 384) -> String {
            AssetThumbnailSource.localCacheScope(accountKey: client.offlineAccountKey, version: version, pixels: pixels)
        }
        XCTAssertEqual(scope(first), scope(renewed))
        XCTAssertNotEqual(scope(first), scope(other))
        XCTAssertNotEqual(scope(first), scope(first, version: "r2"))
        XCTAssertNotEqual(scope(first), scope(first, pixels: 640))
    }

    func testConcurrentCompositionDoesNotRetainAScopeAfterBindingCompletes() async throws {
        let client = ImoraClient(apiURL: URL(string: "https://scope.fixture.invalid/api")!, accessToken: UUID().uuidString)
        defer { client.invalidate() }
        let credential = try XCTUnwrap(client.offlineAccountKey)
        client.confirmMediaAccount("fixture-initial")
        let reader = Task.detached {
            var values = Set<String>()
            for _ in 0..<2_000 {
                values.insert(AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384))
            }
            return values
        }
        for revision in 0..<20 {
            client.confirmMediaAccount("fixture-account-\(revision)")
            XCTAssertEqual(AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384),
                           referenceScope(account: credential, version: "r1", pixels: 384))
        }
        let observed = await reader.value
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { $0.hasSuffix("|r1|fit-cover|384") })
        XCTAssertEqual(AssetThumbnailSource.localCacheScope(accountKey: credential, version: "r1", pixels: 384),
                       referenceScope(account: credential, version: "r1", pixels: 384))
    }

    func testMainThreadScopeCompositionFor120VisibleTiles() throws {
        let client = ImoraClient(apiURL: URL(string: "https://scope.fixture.invalid/api")!, accessToken: UUID().uuidString)
        defer { client.invalidate() }
        client.confirmMediaAccount("fixture-performance")
        let credential = try XCTUnwrap(client.offlineAccountKey)
        let versions = (0..<120).map { "revision-\($0)" }
        let expected = versions.map { referenceScope(account: credential, version: $0, pixels: 384) }
        XCTAssertEqual(versions.map { AssetThumbnailSource.localCacheScope(accountKey: credential, version: $0, pixels: 384) }, expected)
        var baselineMS: [Double] = [], cachedMS: [Double] = []
        for run in 0..<5 {
            for cached in (run.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let start = ContinuousClock.now
                let result = versions.map {
                    cached ? AssetThumbnailSource.localCacheScope(accountKey: credential, version: $0, pixels: 384)
                        : referenceScope(account: credential, version: $0, pixels: 384)
                }
                let elapsed = milliseconds(start.duration(to: .now))
                if cached { cachedMS.append(elapsed) } else { baselineMS.append(elapsed) }
                XCTAssertEqual(result, expected)
            }
        }
        print("LOCAL_SCOPE_120_TILES baseline_ms=\(baselineMS) cached_ms=\(cachedMS) outputs_per_run=120 failures=0")
    }

    private func referenceScope(account: String?, version: String?, pixels: CGFloat) -> String {
        let verified = account.flatMap { SessionCache.verifiedMediaScope(credential: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stable = verified.flatMap { try? encoder.encode($0) }.map(MediaDisplayKeyV1.digest)
        return "\(stable ?? account ?? "device")|\(version ?? "")|fit-cover|\(Int(pixels.rounded(.up)))"
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
