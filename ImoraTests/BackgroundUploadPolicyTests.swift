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

    func testRuntimePolicyReducesBackgroundWarmPreparationAndKeepsOneWorkerAtSeriousHeat() {
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .nominal), 8)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: true, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .fair), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .serious), 1)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: true, lowPower: false, thermal: .critical), 0)
    }

    func testExplicitBackupCannotBypassACriticalThermalPause() throws {
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious] {
            XCTAssertNoThrow(try BackupRuntimePolicy.requireThermalBudget(thermal))
        }
        XCTAssertThrowsError(try BackupRuntimePolicy.requireThermalBudget(.critical)) { error in
            XCTAssertTrue(error is BackupThermalHold)
        }
    }

    func testCriticalThermalCooldownPreventsImmediateRestartWhenTheDeviceOnlyDropsToFair() {
        let heated = BackupRuntimePolicy.thermalCooldownDeadline(
            current: 0, observedAt: 1_000, thermal: .critical)
        XCTAssertEqual(heated, 1_180)
        XCTAssertTrue(BackupRuntimePolicy.isCoolingDown(now: 1_150, deadline: heated, thermal: .fair))

        let cooledFair = BackupRuntimePolicy.thermalCooldownDeadline(
            current: heated, observedAt: 1_100, thermal: .fair)
        XCTAssertEqual(cooledFair, 1_180)
        XCTAssertTrue(BackupRuntimePolicy.isCoolingDown(now: 1_179, deadline: cooledFair, thermal: .nominal))
        XCTAssertFalse(BackupRuntimePolicy.isCoolingDown(now: 1_180, deadline: cooledFair, thermal: .nominal))
    }

    func testSeriousHeatWithoutACriticalEventDoesNotAddAThermalHold() {
        XCTAssertEqual(BackupRuntimePolicy.thermalCooldownDeadline(
            current: 0, observedAt: 1_000, thermal: .serious), 0)
        XCTAssertFalse(BackupRuntimePolicy.isCoolingDown(
            now: 1_000, deadline: 0, thermal: .serious))
    }

    func testStartingInFairWithoutAHeatEventDoesNotSilentlyAddCooldown() {
        XCTAssertEqual(BackupRuntimePolicy.thermalCooldownDeadline(
            current: 0, observedAt: 1_000, thermal: .fair), 0)
        XCTAssertFalse(BackupRuntimePolicy.isCoolingDown(now: 1_000, deadline: 0, thermal: .fair))
    }
}
