import XCTest
@testable import Imora

@MainActor
final class BackgroundTaskDiagnosticsTests: XCTestCase {
    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "background-diagnostics-tests-\(UUID().uuidString)/diagnostics.json")
    }

    func testProgressWritesWaitFiveSecondsButExpirationImmediatelyPersistsTheLatestMeasurements() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now: TimeInterval = 100
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        diagnostics.beginAttempt(phase: .hashing)
        let initial = try Data(contentsOf: url)
        now = 101
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 10, total: 100))
        now = 104
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 20, total: 100))
        XCTAssertEqual(try Data(contentsOf: url), initial)
        now = 105
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 30, total: 100))
        let checkpoint = try Data(contentsOf: url)
        XCTAssertNotEqual(checkpoint, initial)
        now = 106
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 40, total: 100))
        XCTAssertEqual(try Data(contentsOf: url), checkpoint)
        now = 106.5
        diagnostics.record(.expired, phase: .hashing, success: false)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        let event = try XCTUnwrap(reloaded.events.last)
        XCTAssertEqual(event.lifecycle, .expired)
        XCTAssertEqual(event.progress?.completed, 40)
        XCTAssertEqual(try XCTUnwrap(event.callbackAgeSeconds), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event.advanceAgeSeconds), 0.5, accuracy: 0.0001)
        XCTAssertEqual(event.success, false)
        let terminal = try Data(contentsOf: url)
        now = 107
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 50, total: 100))
        XCTAssertEqual(diagnostics.events.last?.lifecycle, .expired, "Late callbacks must not replace the terminal diagnosis")
        XCTAssertEqual(try Data(contentsOf: url), terminal)
    }

    func testUnchangedCallbacksDoNotResetTheAgeOfNumericalAdvancement() throws {
        var now: TimeInterval = 1_000
        let diagnostics = BackgroundTaskDiagnostics(clock: { now })
        diagnostics.beginAttempt(phase: .hashing)
        now = 1_001
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 20, total: 100))
        now = 1_002
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 20, total: 100))
        now = 1_008
        // A terminal snapshot is not another callback or an advancement.
        diagnostics.record(.expired, phase: .hashing, progress: .init(completed: 20, total: 100))
        let event = try XCTUnwrap(diagnostics.events.last)
        XCTAssertEqual(event.elapsedSeconds, 8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event.callbackAgeSeconds), 6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event.advanceAgeSeconds), 7, accuracy: 0.0001)
    }

    func testChangingProgressUnitsWithoutAdvancingTheFractionIsNotAnAdvancement() throws {
        var now: TimeInterval = 10
        let diagnostics = BackgroundTaskDiagnostics(clock: { now })
        diagnostics.beginAttempt(phase: .checking)
        now = 11
        diagnostics.record(.progress, phase: .checking, progress: .init(completed: 1, total: 5))
        now = 13
        diagnostics.record(.progress, phase: .checking, progress: .init(completed: 200_000, total: 1_000_000))
        now = 15
        diagnostics.record(.expired, phase: .checking)
        let event = try XCTUnwrap(diagnostics.events.last)
        XCTAssertEqual(try XCTUnwrap(event.callbackAgeSeconds), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event.advanceAgeSeconds), 4, accuracy: 0.0001)
    }

    func testPersistedHistoryStaysWithinTheEventAndByteLimitsAndUsesPrivateFilePermissions() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now: TimeInterval = 0
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        diagnostics.beginAttempt(phase: .scanning)
        for index in 1...90 {
            now = Double(index)
            diagnostics.record(index.isMultiple(of: 2) ? .foregrounded : .backgrounded, phase: .hashing,
                environment: .init(lowPowerMode: false, thermalState: .nominal, protectedDataAvailable: true))
        }
        diagnostics.record(.completed, phase: .error, success: false,
            failure: .init(category: .urlSession, code: -1001))
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 32 * 1_024)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertLessThanOrEqual(reloaded.events.count, 64)
        XCTAssertGreaterThan(reloaded.events.count, 1)
        XCTAssertEqual(reloaded.events.last?.lifecycle, .completed)
        XCTAssertEqual(reloaded.events.last?.failure?.category, .urlSession)
        XCTAssertEqual(reloaded.events.last?.failure?.code, -1001)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testNewAttemptDoesNotReuseOldFailureProgressOrAges() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now: TimeInterval = 10
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        diagnostics.beginAttempt(phase: .hashing)
        let oldAttempt = try XCTUnwrap(diagnostics.attemptID)
        now = 12
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 4, total: 10))
        diagnostics.record(.expired, phase: .hashing, success: false)
        now = 50
        diagnostics.beginAttempt(phase: .scanning)
        XCTAssertNotEqual(diagnostics.attemptID, oldAttempt)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertEqual(reloaded.attemptID, diagnostics.attemptID)
        XCTAssertEqual(reloaded.events.count, 1)
        let first = try XCTUnwrap(reloaded.events.first)
        XCTAssertEqual(first.lifecycle, .submitted)
        XCTAssertEqual(first.elapsedSeconds, 0)
        XCTAssertNil(first.progress)
        XCTAssertNil(first.callbackAgeSeconds)
        XCTAssertNil(first.advanceAgeSeconds)
        XCTAssertNil(first.failure)
    }

    func testPersistedSchemaHasOnlyApprovedTypedFields() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { 20 })
        diagnostics.beginAttempt(phase: .uploading)
        diagnostics.record(.completed, phase: .error, progress: .init(completed: 1, total: 2), success: false,
            failure: .init(category: .photoKit, code: 3),
            environment: .init(lowPowerMode: true, thermalState: .serious, protectedDataAvailable: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["schemaVersion", "attemptID", "events"]))
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.last)
        XCTAssertTrue(Set(event.keys).isSubset(of: ["sequence", "lifecycle", "phase", "elapsedSeconds", "progress", "callbackAgeSeconds", "advanceAgeSeconds", "success", "failure", "environment"]))
        let failure = try XCTUnwrap(event["failure"] as? [String: Any])
        XCTAssertEqual(Set(failure.keys), ["category", "code"])
        let environment = try XCTUnwrap(event["environment"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), ["lowPowerMode", "thermalState", "protectedDataAvailable"])
        let progress = try XCTUnwrap(event["progress"] as? [String: Any])
        XCTAssertEqual(Set(progress.keys), ["completed", "total"])
    }

    func testInvalidClockAndNegativeProgressCannotPreventATerminalRecord() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now = Double.nan
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        diagnostics.beginAttempt(phase: .hashing)
        now = -1
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: -4, total: -10))
        now = .infinity
        diagnostics.record(.expired, phase: .hashing, success: false)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        let event = try XCTUnwrap(reloaded.events.last)
        XCTAssertEqual(event.lifecycle, .expired)
        XCTAssertEqual(event.elapsedSeconds, 0)
        XCTAssertEqual(event.progress?.completed, 0)
        XCTAssertEqual(event.progress?.total, 1)
        XCTAssertEqual(event.callbackAgeSeconds, 0)
        XCTAssertNil(event.advanceAgeSeconds)
    }

    func testOversizedExistingFileIsNotLoadedEvenWhenItContainsValidJSON() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { 0 })
        diagnostics.beginAttempt(phase: .hashing)
        var oversized = try Data(contentsOf: url)
        oversized.append(Data(repeating: 0x20, count: 32 * 1_024))
        try oversized.write(to: url)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertNil(reloaded.attemptID)
        XCTAssertTrue(reloaded.events.isEmpty)
    }
}
