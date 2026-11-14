import XCTest
@testable import Imora

final class AccountRequestContextTests: XCTestCase {
    func testQueuedMediaCannotAcquireNextAccountsTokenOnSameServer() throws {
        let url = URL(string: "https://photos.example.com/api")!
        let old = AccountRequestContext(apiURL: url, token: "old-token")
        let next = AccountRequestContext(apiURL: url, token: "new-token")
        let queued = old.mediaURL(url.appending(path: "assets/1/thumbnail"))
        XCTAssertThrowsError(try next.authorize(URLRequest(url: queued)))
        let original = try old.authorize(URLRequest(url: queued))
        XCTAssertEqual(original.value(forHTTPHeaderField: "Authorization"), "Bearer old-token")
        XCTAssertNil(original.url?.fragment)
        old.invalidate()
        XCTAssertThrowsError(try old.authorize(URLRequest(url: queued)))
        XCTAssertThrowsError(try old.authorize(URLRequest(url: url.appending(path: "assets"))))
    }

    func testOnlyExplicitLANRootCanBeAuthorized() throws {
        let context = AccountRequestContext(apiURL: URL(string: "https://photos.example.com/api")!, token: "token")
        let local = URL(string: "http://192.168.50.10:2283/api")!
        let request = URLRequest(url: local.appending(path: "assets"))
        XCTAssertThrowsError(try context.authorize(request))
        XCTAssertEqual(try context.authorize(request, localAPIURL: local).value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertThrowsError(try context.authorize(URLRequest(url: URL(string: "http://192.168.50.10:2284/api/assets")!), localAPIURL: local))
    }
}
