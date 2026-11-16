import CryptoKit
import XCTest
@testable import Imora

final class BackgroundUploadPolicyTests: XCTestCase {
    func testSealedPartContainsAuthenticatedCiphertextAndBindsItsOffset() throws {
        let key = Data(repeating: 7, count: 32)
        let original = Data("synthetic-private-video-bytes".utf8)
        let encrypted = try SealedUploadPart.seal(original, key: key.base64EncodedString(), id: "upload", offset: 8)
        XCTAssertEqual(encrypted.count, original.count + 28)
        XCTAssertNil(encrypted.range(of: original))
        let box = try AES.GCM.SealedBox(combined: encrypted)
        XCTAssertEqual(try AES.GCM.open(box, using: SymmetricKey(data: key),
            authenticating: Data("upload:8:\(original.count)".utf8)), original)
        XCTAssertThrowsError(try AES.GCM.open(box, using: SymmetricKey(data: key),
            authenticating: Data("upload:0:\(original.count)".utf8)))
    }

    func testRuntimePolicyReducesBackgroundAndHotPreparationAndStopsAtCriticalHeat() {
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .nominal), 8)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: true, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .serious), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .critical), 0)
    }
}
