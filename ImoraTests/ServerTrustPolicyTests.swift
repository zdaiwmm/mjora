import XCTest
@testable import Imora

final class ServerTrustPolicyTests: XCTestCase {
    func testRejectsCredentialsInServerURL() {
        XCTAssertFalse(ImoraClient.supportsTransport(to: URL(string: "https://user:password@example.com/api")!))
    }

    func testRejectsInvalidPorts() {
        XCTAssertFalse(ImoraClient.supportsTransport(to: URL(string: "https://example.com:65536/api")!))
        XCTAssertFalse(ImoraClient.supportsTransport(to: URL(string: "http://example.com:0/api")!))
    }

    func testExplicitHTTPRemainsSupported() {
        XCTAssertTrue(ImoraClient.supportsTransport(to: URL(string: "http://192.168.50.10:2283/api")!))
    }
}

extension ServerTrustPolicyTests {
    func testOriginAndAPIRootAreExact() throws {
        let policy = ServerTrustPolicy(apiURL: URL(string: "https://photos.example.com/api")!)
        for value in ["https://PHOTOS.example.com:443/api/assets/1?edited=false", "https://photos.example.com/api"] {
            XCTAssertTrue(policy.contains(URL(string: value)!), value)
        }
        for value in [
            "https://photos.example.com.evil/api/assets", "https://photos.example.com:444/api/assets",
            "http://photos.example.com/api/assets", "https://photos.example.com/api-evil/assets",
            "https://photos.example.com/other/assets", "https://user@photos.example.com/api/assets",
            "https://photos.example.com/api/%2e%2e/private", "https://photos.example.com/api/a%2fb",
            "file:///api/assets", "https://photos.example.com/api/a%5cb"
        ] {
            XCTAssertFalse(policy.contains(URL(string: value)!), value)
        }
        var request = URLRequest(url: URL(string: "https://evil.example/api/assets")!)
        request.setValue("Bearer stale", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try policy.authorize(request, token: "test-only-token"))
        let allowed = try policy.authorize(URLRequest(url: URL(string: "https://photos.example.com/api/assets")!), token: "test-only-token")
        XCTAssertEqual(allowed.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
    }

    func testRedirectsRequireReadOnlySameOriginAndRoot() {
        let policy = ServerTrustPolicy(apiURL: URL(string: "https://photos.example.com/api")!)
        let redirect = RedirectPolicy(policy: policy)
        let source = URL(string: "https://photos.example.com/api/assets/one/thumbnail")!
        for status in [301, 302, 303, 307, 308] {
            let response = HTTPURLResponse(url: source, statusCode: status, httpVersion: nil, headerFields: nil)!
            for method in ["POST", "PUT", "PATCH", "DELETE"] {
                var original = URLRequest(url: source)
                original.httpMethod = method
                XCTAssertFalse(redirect.permits(original: original, response: response, proposed: URLRequest(url: source), redirects: 0))
            }
            let original = URLRequest(url: source)
            XCTAssertTrue(redirect.permits(original: original, response: response, proposed: URLRequest(url: URL(string: "https://photos.example.com/api/assets/one/original")!), redirects: 0))
            for target in ["https://other.example/api/assets", "https://photos.example.com:444/api/assets", "http://photos.example.com/api/assets", "https://photos.example.com/private"] {
                XCTAssertFalse(redirect.permits(original: original, response: response, proposed: URLRequest(url: URL(string: target)!), redirects: 0))
            }
            XCTAssertFalse(redirect.permits(original: original, response: response, proposed: original, redirects: 5))
        }
    }
}
