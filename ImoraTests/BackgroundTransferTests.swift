import XCTest
@testable import Imora

final class BackgroundTransferTests: XCTestCase {
    func testDurableUploaderDoesNotFollowMutationRedirect() async throws {
        let receiver = try LocalHTTPServer { _ in .init(body: Data("{\"id\":\"fixture-remote\",\"status\":\"created\"}".utf8)) }
        try await receiver.start()
        defer { receiver.stop() }
        let server = try LocalHTTPServer { _ in .init(status: 307, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
        try await server.start()
        defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "fixture-background-token")
        let file = BackgroundUploader.bodyDirectory.appending(path: "fixture-\(UUID().uuidString)")
        try Data("synthetic-upload-body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = BackupEntry(modificationDate: nil, isLivePhoto: false, primaryChecksum: "fixture-checksum")
        let ticket = BackgroundUploader.Ticket(account: "fixture", localId: "fixture-local", isMotion: false, bodyPath: file.path, source: source)
        let request = try client.authorizedRequest(url: server.apiURL.appending(path: "assets"), method: "POST")
        _ = try? await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await BackgroundUploader.shared.upload(request, fromFile: file, ticket: ticket, context: client.context, onProgress: nil)
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        XCTAssertEqual(server.received.count, 1, "the valid initial upload must reach its configured server")
        XCTAssertTrue(receiver.received.isEmpty, "sensitive upload crossed the configured origin")
    }
}
