import XCTest
import Synchronization
@testable import Imora

final class BackgroundTransferTests: XCTestCase {
    func testUploadReportsActualTransportByteSamplesWithStableTransferIdentity() async throws {
        let server = try LocalHTTPServer { _ in .init(body: Data("{\"id\":\"fixture-remote\",\"status\":\"created\"}".utf8)) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-byte-progress")
        defer { client.invalidate() }
        try ProtectedTemporaryFiles.prepareDirectory(BackgroundUploader.bodyDirectory)
        let file = BackgroundUploader.bodyDirectory.appending(path: "byte-fixture-\(UUID().uuidString)")
        let body = Data(repeating: 97, count: 256 * 1024)
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ticket = BackgroundUploader.Ticket(account: "fixture", localId: "byte-progress", isMotion: false, bodyPath: file.path)
        let request = try client.authorizedRequest(url: server.apiURL.appending(path: "assets"), method: "POST")
        let samples = Mutex<[UploadByteProgress]>([])
        _ = try await BackgroundUploader.shared.upload(request, fromFile: file, ticket: ticket, context: client.context,
            onByteProgress: { sample in samples.withLock { $0.append(sample) } }, onProgress: nil)
        let recorded = samples.withLock { $0 }
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertEqual(Set(recorded.map(\.transferID)).count, 1)
        XCTAssertEqual(recorded.last?.totalBytesSent, Int64(body.count))
        XCTAssertEqual(recorded.last?.totalBytesExpectedToSend, Int64(body.count))
        XCTAssertEqual(recorded.reduce(Int64(0)) { $0 + $1.bytesSent }, Int64(body.count))
        XCTAssertTrue(recorded.allSatisfy { $0.timestamp > 0 && $0.timestamp <= ProcessInfo.processInfo.systemUptime })
        XCTAssertEqual(server.received.first?.body, body)
    }

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
