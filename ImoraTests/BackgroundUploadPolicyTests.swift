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

    func testRuntimePolicyReducesBackgroundAndWarmPreparationAndPausesBeforeCriticalHeat() {
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .nominal), 8)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: true, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .fair), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .serious), 0)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .critical), 0)
    }

    func testExplicitBackupCannotBypassAThermalPause() throws {
        for thermal in [ProcessInfo.ThermalState.nominal, .fair] {
            XCTAssertNoThrow(try BackupRuntimePolicy.requireThermalBudget(thermal))
        }
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            XCTAssertThrowsError(try BackupRuntimePolicy.requireThermalBudget(thermal)) { error in
                XCTAssertTrue(error is BackupThermalHold)
            }
        }
    }
}
