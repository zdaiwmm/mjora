import XCTest
import Synchronization
@testable import Imora

final class TransferIsolationTests: XCTestCase {
    func testAuthorityRequiresExactTargetTokenAndSessionGeneration() throws {
        let root = URL(string: "https://fixture.invalid/api")!
        let first = ShareCredentialIdentity(apiURL: root, token: "old-fixture-token", generation: UUID())
        let next = ShareCredentialIdentity(apiURL: root, token: "new-fixture-token", generation: UUID())
        var request = URLRequest(url: root.appending(path: "assets"))
        request.httpMethod = "POST"
        request.setValue("Bearer old-fixture-token", forHTTPHeaderField: "Authorization")
        XCTAssertTrue(first.permits(request, current: first))
        XCTAssertFalse(first.permits(request, current: next))
        XCTAssertFalse(first.permits(request, current: nil))
        var otherPort = request; otherPort.url = URL(string: "https://fixture.invalid:444/api/assets")!
        XCTAssertFalse(first.permits(otherPort, current: first))
        var otherRoot = request; otherRoot.url = URL(string: "https://fixture.invalid/private")!
        XCTAssertFalse(first.permits(otherRoot, current: first))
        var wrongToken = request; wrongToken.setValue("Bearer new-fixture-token", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(first.permits(wrongToken, current: first))
    }

    func testPersistedAuthorityNeverStoresTokenAndOldWorkCannotStartAfterSwitchOrRevoke() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShareCredentialStore(directory: directory)
        let root = URL(string: "https://fixture.invalid/api")!
        let first = ShareCredentialIdentity(apiURL: root, token: "sensitive-fixture-token", generation: UUID())
        let next = ShareCredentialIdentity(apiURL: root, token: "next-fixture-token", generation: UUID())
        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        let entered = Mutex(false)
        try store.withCurrent(first) { entered.withLock { $0 = true } }
        XCTAssertTrue(entered.withLock { $0 })
        try store.save(next)
        entered.withLock { $0 = false }
        XCTAssertThrowsError(try store.withCurrent(first) { entered.withLock { $0 = true } })
        XCTAssertFalse(entered.withLock { $0 })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data("sensitive-fixture-token".utf8)))
            XCTAssertNil(data.range(of: Data("next-fixture-token".utf8)))
        }
        try store.save(nil)
        XCTAssertNil(try store.load())
        XCTAssertThrowsError(try store.withCurrent(next) {})
    }

    func testMovedSensitiveFilesAreExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("synthetic-media".utf8).write(to: source)
        let destination = directory.appending(path: "body")
        try FileManager.default.moveItem(at: source, to: destination)
        try ProtectedTemporaryFiles.protect(destination)
        for url in [directory, destination] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }
    func testDataProtectionMetadataOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS simulator does not expose Data Protection metadata. Verify on a signed physical device.")
        #else
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ProtectedTemporaryFiles.prepareDirectory(directory)
        let file = directory.appending(path: "body")
        try Data("synthetic-media".utf8).write(to: file)
        try ProtectedTemporaryFiles.protect(file)
        for url in [directory, file] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let raw = attributes[.protectionKey]
            XCTAssertEqual((raw as? FileProtectionType)?.rawValue ?? (raw as? String), FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
        #endif
    }

}
