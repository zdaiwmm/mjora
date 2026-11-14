import Foundation
import XCTest
@testable import Imora

final class AccountCacheIsolationTests: XCTestCase {
    func testClientCacheIdentityCannotChangeToTheNextAccount() {
        let root = URL(string: "https://cache.fixture.invalid:8443/api")!
        SessionCache.noteUserId("a")
        let old = ImoraClient(apiURL: root, accessToken: "synthetic-a")
        let original = old.offlineAccountKey
        SessionCache.noteUserId("b")
        let next = ImoraClient(apiURL: root, accessToken: "synthetic-b")
        XCTAssertEqual(old.offlineAccountKey, original)
        XCTAssertNotEqual(old.offlineAccountKey, next.offlineAccountKey)
        XCTAssertNotEqual(old.offlineAccountKey, ImoraClient(apiURL: URL(string: "https://cache.fixture.invalid:8444/api")!, accessToken: "synthetic-a").offlineAccountKey)
        old.invalidate(); next.invalidate()
        SessionCache.clear()
    }
}
