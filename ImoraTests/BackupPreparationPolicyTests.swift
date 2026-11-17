import XCTest
@testable import Imora

final class BackupPreparationPolicyTests: XCTestCase {
    func testLegacyHighRequestsMigrateToTheValueDisplayedByThePicker() throws {
        let name = "backup-preparation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "imora.backupHashWorkers"
        XCTAssertEqual(BackupRuntimePolicy.loadPreparationRequest(from: defaults, key: key), 2)
        for oldRequest in [5, 8, 16, 32] {
            defaults.set(oldRequest, forKey: key)
            XCTAssertEqual(BackupRuntimePolicy.loadPreparationRequest(from: defaults, key: key), 3)
            XCTAssertEqual(defaults.integer(forKey: key), 3)
            XCTAssertEqual(BackupRuntimePolicy.loadPreparationRequest(from: defaults, key: key), 3)
        }
        for request in [1, 2, 3] {
            defaults.set(request, forKey: key)
            XCTAssertEqual(BackupRuntimePolicy.loadPreparationRequest(from: defaults, key: key), request)
        }
        for invalid in [0, -1] {
            defaults.set(invalid, forKey: key)
            XCTAssertEqual(BackupRuntimePolicy.loadPreparationRequest(from: defaults, key: key), 2)
            XCTAssertEqual(defaults.integer(forKey: key), 2)
        }
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkerOptions, [1, 2, 3])
    }

    func testPreparationHasItsOwnCeilingWithoutChangingTransportOrVerificationBudgets() {
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: false, lowPower: false, thermal: .nominal), 3)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 2, background: false, lowPower: false, thermal: .nominal), 2)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 3, background: false, lowPower: false, thermal: .nominal), 3)
        XCTAssertEqual(BackupRuntimePolicy.workers(requested: 8, background: false, lowPower: false, thermal: .nominal), 8)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: true, lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: false, lowPower: true, thermal: .nominal), 1)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: false, lowPower: false, thermal: .fair), 1)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: false, lowPower: false, thermal: .serious), 0)
        XCTAssertEqual(BackupRuntimePolicy.preparationWorkers(requested: 32, background: false, lowPower: false, thermal: .critical), 0)
    }
}
