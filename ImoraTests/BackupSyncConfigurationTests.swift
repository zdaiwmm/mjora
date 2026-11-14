import XCTest
@testable import Imora

final class BackupSyncConfigurationTests: XCTestCase {
    func testDefaultEnabledAndExplicitOverrideTakesPriority() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertTrue(BackupSyncConfiguration(defaults: defaults).incrementalEnabled)
        XCTAssertFalse(BackupSyncConfiguration(incrementalSyncEnabled: false, defaults: defaults).incrementalEnabled)
        defaults.register(defaults: [BackupSyncConfiguration.incrementalEnabledKey: false])
        XCTAssertTrue(BackupSyncConfiguration(incrementalSyncEnabled: true, defaults: defaults).incrementalEnabled)
    }

    func testPersistedSettingIsCapturedOnceAndDisabledSelectsCompatibility() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        // Registration domain exercises the real preference read without writing user preferences.
        defaults.register(defaults: [BackupSyncConfiguration.incrementalEnabledKey: false])
        let disabled = BackupSyncConfiguration(defaults: defaults)
        defaults.register(defaults: [BackupSyncConfiguration.incrementalEnabledKey: true])
        XCTAssertFalse(disabled.incrementalEnabled)
        XCTAssertThrowsError(try disabled.requireIncremental()) { error in
            XCTAssertEqual(error as? RemoteSyncError, .compatibilityRequired)
        }
        XCTAssertNoThrow(try BackupSyncConfiguration(defaults: defaults).requireIncremental())
    }
}
