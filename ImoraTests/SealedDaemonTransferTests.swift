import XCTest
@testable import Imora

final class SealedDaemonTransferTests: XCTestCase {
    func testSystemHandoffIsScopedToTheQueuedAccountAndLocalAsset() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try LocalHTTPServer { _ in
            _ = gate.wait(timeout: .now() + 15)
            return .init(status: 204)
        }
        try await server.start(); defer { gate.signal(); server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-secret")
        defer { client.invalidate() }
        let ready = expectation(description: "System accepted the encrypted transfer")
        let account = "handoff-account-\(UUID().uuidString)"
        let localId = "handoff-local"
        let uploader = BackgroundUploader.shared
        uploader.setSystemHandoffHandler { value in if value == account { ready.fulfill() } }
        defer { uploader.setSystemHandoffHandler(nil); uploader.finishedPreparing(account: account, localId: localId) }
        try ProtectedTemporaryFiles.prepareDirectory(BackgroundUploader.bodyDirectory)
        let file = BackgroundUploader.bodyDirectory.appending(path: "handoff-\(UUID().uuidString)")
        let sealed = try SealedUploadPart.seal(Data("scope-fixture".utf8),
            key: Data(repeating: 7, count: 32).base64EncodedString(), id: "synthetic", offset: 0)
        try sealed.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: server.apiURL.appending(path: "parts"))
        request.httpMethod = "PUT"
        let queued = request
        let ticket = BackgroundUploader.Ticket(account: account, localId: localId, isMotion: false,
            bodyPath: file.path, isChunk: true, isSealed: true)
        let transfer = Task {
            try await uploader.upload(queued, fromFile: file, ticket: ticket, context: client.context, onProgress: nil)
        }
        defer { transfer.cancel() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertTrue(uploader.hasSystemTransfer(account: account, localIds: [localId]))
        XCTAssertFalse(uploader.hasSystemTransfer(account: "another-account", localIds: [localId]))
        XCTAssertFalse(uploader.hasSystemTransfer(account: account, localIds: ["another-local"]))
        gate.signal()
        _ = try await transfer.value
        XCTAssertFalse(uploader.hasSystemTransfer(account: account, localIds: [localId]))
    }

    func testRedirectedDaemonCarriesOnlyCiphertextAndCannotCreateACompletionReceipt() async throws {
        let receiver = try LocalHTTPServer { _ in .init(body: Data("{\"id\":\"forged\",\"status\":\"created\"}".utf8)) }
        try await receiver.start(); defer { receiver.stop() }
        let server = try LocalHTTPServer { _ in .init(status: 307, headers: ["Location": receiver.apiURL.appending(path: "capture").absoluteString]) }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-account-secret")
        defer { client.invalidate() }
        let plaintext = Data("synthetic-private-original".utf8)
        let sealed = try SealedUploadPart.seal(plaintext, key: Data(repeating: 1, count: 32).base64EncodedString(), id: "fixture", offset: 0)
        try ProtectedTemporaryFiles.prepareDirectory(BackgroundUploader.bodyDirectory)
        let file = BackgroundUploader.bodyDirectory.appending(path: "sealed-fixture-\(UUID().uuidString)")
        try sealed.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: server.apiURL.appending(path: "parts"))
        request.httpMethod = "PUT"
        request.setValue("opaque-staging-only-capability", forHTTPHeaderField: "X-Upload-Capability")
        let ticket = BackgroundUploader.Ticket(account: "synthetic", localId: "sealed-fixture", isMotion: false,
            bodyPath: file.path, isChunk: true, isSealed: true)
        let response = try await BackgroundUploader.shared.upload(request, fromFile: file, ticket: ticket,
            context: client.context, onProgress: nil)
        BackgroundUploader.shared.finishedPreparing(account: ticket.account, localId: ticket.localId)
        XCTAssertTrue(response.isEmpty, "A daemon response must never be trusted as asset proof")
        XCTAssertFalse(server.received.isEmpty)
        for request in server.received + receiver.received {
            XCTAssertNil(request.headers["authorization"])
            XCTAssertEqual(request.body, sealed)
            XCTAssertNil(request.body.range(of: plaintext))
        }
        XCTAssertFalse(UploadJournal().receipts().contains { $0.ticket.id == ticket.id })
    }

    func testDaemonRejectsAnAccountCredentialBeforeAnyNetworkRequest() async throws {
        let server = try LocalHTTPServer { _ in .init() }
        try await server.start(); defer { server.stop() }
        let client = ImoraClient(apiURL: server.apiURL, accessToken: "synthetic-secret")
        let request = try client.authorizedRequest(url: server.apiURL.appending(path: "parts"), method: "PUT")
        let ticket = BackgroundUploader.Ticket(account: "synthetic", localId: "credential-fixture", isMotion: false,
            bodyPath: "/does-not-exist", isChunk: true, isSealed: true)
        do {
            _ = try await BackgroundUploader.shared.upload(request, fromFile: URL(fileURLWithPath: ticket.bodyPath),
                ticket: ticket, context: client.context, onProgress: nil)
            XCTFail("Account credential reached daemon boundary")
        } catch {}
        XCTAssertTrue(server.received.isEmpty)
        client.invalidate()
    }
}
