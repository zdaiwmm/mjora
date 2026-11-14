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
        XCTAssertEqual(reloaded.previousAttempt?.attemptID, oldAttempt)
        XCTAssertEqual(reloaded.previousAttempt?.events.last?.lifecycle, .expired)
        XCTAssertEqual(reloaded.previousAttempt?.events.last?.progress?.completed, 4)
        now = 55
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 1, total: 10))
        let afterProgress = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertEqual(afterProgress.previousAttempt?.attemptID, oldAttempt)
        XCTAssertEqual(afterProgress.previousAttempt?.events.last?.lifecycle, .expired)
    }

    func testPersistedSchemaHasOnlyApprovedTypedFields() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { 20 })
        diagnostics.beginAttempt(phase: .uploading)
        diagnostics.record(.completed, phase: .error, progress: .init(completed: 1, total: 2), success: false,
            failure: .init(category: .photoKit, code: 3),
            environment: .init(lowPowerMode: true, thermalState: .serious, protectedDataAvailable: false,
                residentMemoryBytes: 200, availableMemoryBytes: 300, availableDiskBytes: 400, processIdentifier: 42))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["schemaVersion", "attemptID", "events", "previousAttempt"]))
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.last)
        XCTAssertTrue(Set(event.keys).isSubset(of: ["sequence", "lifecycle", "phase", "elapsedSeconds", "progress", "callbackAgeSeconds", "advanceAgeSeconds", "success", "failure", "environment"]))
        let failure = try XCTUnwrap(event["failure"] as? [String: Any])
        XCTAssertEqual(Set(failure.keys), ["category", "code"])
        let environment = try XCTUnwrap(event["environment"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), ["lowPowerMode", "thermalState", "protectedDataAvailable",
            "residentMemoryBytes", "availableMemoryBytes", "availableDiskBytes", "processIdentifier"])
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
        diagnostics.record(.expired, phase: .hashing, success: false,
            environment: .init(lowPowerMode: false, thermalState: .unknown, protectedDataAvailable: true,
                residentMemoryBytes: -1, availableMemoryBytes: -2, availableDiskBytes: -3, processIdentifier: -4))
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        let event = try XCTUnwrap(reloaded.events.last)
        XCTAssertEqual(event.lifecycle, .expired)
        XCTAssertEqual(event.elapsedSeconds, 0)
        XCTAssertEqual(event.progress?.completed, 0)
        XCTAssertEqual(event.progress?.total, 1)
        XCTAssertEqual(event.callbackAgeSeconds, 0)
        XCTAssertNil(event.advanceAgeSeconds)
        XCTAssertNil(event.environment?.residentMemoryBytes)
        XCTAssertNil(event.environment?.availableMemoryBytes)
        XCTAssertNil(event.environment?.availableDiskBytes)
        XCTAssertNil(event.environment?.processIdentifier)
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

    func testRetryAfterProcessRestartRetainsAnUnterminatedAttemptWithoutInventingAFailure() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now: TimeInterval = 100
        let firstProcess = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        firstProcess.beginAttempt(phase: .uploading)
        let firstID = try XCTUnwrap(firstProcess.attemptID)
        now = 444.664
        firstProcess.record(.progress, phase: .uploading, progress: .init(completed: 800, total: 1_000),
            environment: .init(lowPowerMode: false, thermalState: .nominal, protectedDataAvailable: true, processIdentifier: 41))
        now = 1_000
        let nextProcess = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        nextProcess.beginAttempt(phase: .scanning)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertEqual(reloaded.previousAttempt?.attemptID, firstID)
        let prior = try XCTUnwrap(reloaded.previousAttempt?.events.last)
        XCTAssertEqual(prior.lifecycle, .progress)
        XCTAssertEqual(prior.elapsedSeconds, 344.664, accuracy: 0.0001)
        XCTAssertEqual(prior.environment?.processIdentifier, 41)
        XCTAssertNil(prior.failure)
        XCTAssertNil(prior.success)
        XCTAssertEqual(reloaded.events.last?.lifecycle, .submitted)
        XCTAssertEqual(reloaded.events.last?.elapsedSeconds, 0)
    }

    func testCurrentAndPreviousHistoriesShareTheSameEventAndByteBudgets() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var now: TimeInterval = 0
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { now })
        diagnostics.beginAttempt(phase: .hashing)
        for index in 1...90 {
            now = Double(index)
            diagnostics.record(.backgrounded, phase: .hashing)
        }
        diagnostics.record(.expired, phase: .hashing, success: false)
        let oldID = try XCTUnwrap(diagnostics.attemptID)
        now = 200
        diagnostics.beginAttempt(phase: .uploading)
        for index in 1...90 {
            now = 200 + Double(index)
            diagnostics.record(.foregrounded, phase: .uploading,
                environment: .init(lowPowerMode: false, thermalState: .fair, protectedDataAvailable: true,
                    residentMemoryBytes: 200_000_000, availableMemoryBytes: 800_000_000,
                    availableDiskBytes: 60_000_000_000, processIdentifier: 42))
        }
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        let previous = try XCTUnwrap(reloaded.previousAttempt)
        XCTAssertEqual(previous.attemptID, oldID)
        XCTAssertEqual(previous.events.count, 8)
        XCTAssertEqual(previous.events.last?.lifecycle, .expired)
        XCTAssertLessThanOrEqual(reloaded.events.count + previous.events.count, 64)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 32 * 1_024)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let previousJSON = try XCTUnwrap(object["previousAttempt"] as? [String: Any])
        XCTAssertEqual(Set(previousJSON.keys), ["attemptID", "events"])
    }

    func testResourceProviderIsSampledOnlyForWrittenEventsAndMergesExplicitLifecycleContext() throws {
        var now: TimeInterval = 0
        var samples = 0
        let diagnostics = BackgroundTaskDiagnostics(clock: { now }, environmentProvider: {
            samples += 1
            return .init(lowPowerMode: false, thermalState: .nominal, protectedDataAvailable: true,
                residentMemoryBytes: Int64(samples * 100), availableMemoryBytes: 900,
                availableDiskBytes: 1_000, processIdentifier: 42)
        })
        diagnostics.beginAttempt(phase: .hashing)
        XCTAssertEqual(samples, 1)
        for index in 1...4 {
            now = Double(index)
            diagnostics.record(.progress, phase: .hashing, progress: .init(completed: Int64(index), total: 10))
        }
        XCTAssertEqual(samples, 1)
        now = 5
        diagnostics.record(.progress, phase: .hashing, progress: .init(completed: 5, total: 10))
        XCTAssertEqual(samples, 2)
        XCTAssertEqual(diagnostics.events.last?.environment?.residentMemoryBytes, 200)
        now = 6
        diagnostics.record(.expired, phase: .hashing,
            environment: .init(lowPowerMode: true, thermalState: .serious, protectedDataAvailable: false))
        XCTAssertEqual(samples, 3)
        let environment = try XCTUnwrap(diagnostics.events.last?.environment)
        XCTAssertTrue(environment.lowPowerMode)
        XCTAssertEqual(environment.thermalState, .serious)
        XCTAssertFalse(environment.protectedDataAvailable)
        XCTAssertEqual(environment.residentMemoryBytes, 300)
        XCTAssertEqual(environment.processIdentifier, 42)
    }

    func testLegacySchemaOneLoadsAndItsRecordSurvivesTheFirstSchemaTwoRetry() throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let legacy = #"{"schemaVersion":1,"attemptID":"00000000-0000-0000-0000-000000000001","events":[{"sequence":1,"lifecycle":"expired","phase":"hashing","elapsedSeconds":12,"success":false}]}"#
        try Data(legacy.utf8).write(to: url)
        let diagnostics = BackgroundTaskDiagnostics(fileURL: url, clock: { 100 })
        XCTAssertEqual(diagnostics.attemptID, oldID)
        diagnostics.beginAttempt(phase: .scanning)
        let reloaded = BackgroundTaskDiagnostics(fileURL: url)
        XCTAssertEqual(reloaded.previousAttempt?.attemptID, oldID)
        XCTAssertEqual(reloaded.previousAttempt?.events.last?.lifecycle, .expired)
    }
}
