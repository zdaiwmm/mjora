import Darwin
import Foundation

/// A small, typed record of background runtime. This API deliberately accepts
/// no identifiers, URLs, filenames, messages, Error values, or userInfo.
@MainActor
final class BackgroundTaskDiagnostics {
    static let shared = BackgroundTaskDiagnostics(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/background-diagnostics.json"))

    nonisolated enum Phase: String, Codable, Sendable {
        case idle, scanning, hashing, checking, uploading, done, error, cancelled
    }

    nonisolated enum Lifecycle: String, Codable, Sendable {
        case submitted, accepted, denied, launched, progress, expired, invalidated, completed, backgrounded, foregrounded

        var isTerminal: Bool {
            switch self {
            case .denied, .expired, .invalidated, .completed: true
            default: false
            }
        }
    }

    nonisolated struct ProgressSnapshot: Codable, Equatable, Sendable {
        let completed: Int64
        let total: Int64

        init(completed: Int64, total: Int64) {
            self.total = max(1, total)
            self.completed = min(max(0, completed), self.total)
        }

        var fraction: Double { Double(completed) / Double(total) }
    }

    nonisolated enum FailureCategory: String, Codable, Sendable {
        case urlSession, photoKit, cocoa, backgroundTask, other
    }

    nonisolated struct Failure: Codable, Equatable, Sendable {
        let category: FailureCategory
        let code: Int
    }

    nonisolated enum ThermalState: String, Codable, Sendable {
        case nominal, fair, serious, critical, unknown
    }

    nonisolated struct Environment: Codable, Equatable, Sendable {
        let lowPowerMode: Bool
        let thermalState: ThermalState
        let protectedDataAvailable: Bool
    }

    nonisolated struct Event: Codable, Equatable, Sendable {
        let sequence: Int
        let lifecycle: Lifecycle
        let phase: Phase
        let elapsedSeconds: TimeInterval
        let progress: ProgressSnapshot?
        let callbackAgeSeconds: TimeInterval?
        let advanceAgeSeconds: TimeInterval?
        let success: Bool?
        let failure: Failure?
        let environment: Environment?
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let attemptID: UUID
        let events: [Event]
    }

    private static let maximumEvents = 64
    private static let maximumBytes = 32 * 1_024
    private static let progressWriteInterval: TimeInterval = 5

    private let fileURL: URL?
    private let clock: () -> TimeInterval
    private(set) var attemptID: UUID?
    private(set) var events: [Event] = []
    private var startedAt: TimeInterval?
    private var lastObservedTime: TimeInterval?
    private var lastPersistedAt: TimeInterval?
    private var lastCallbackAt: TimeInterval?
    private var lastAdvanceAt: TimeInterval?
    private var maximumFraction = 0.0
    private var latestProgress: ProgressSnapshot?
    private var sequence = 0
    private var ended = false

    /// The default is memory-only. Tests explicitly inject their temporary URL;
    /// only shared opts into the app's protected persistent destination.
    init(fileURL: URL? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fileURL = fileURL
        self.clock = clock
        load()
    }

    func beginAttempt(phase: Phase = .idle) {
        attemptID = UUID()
        events = []
        lastObservedTime = nil
        let now = readClock()
        startedAt = now
        lastPersistedAt = nil
        lastCallbackAt = nil
        lastAdvanceAt = nil
        maximumFraction = 0
        latestProgress = nil
        sequence = 0
        ended = false
        append(.submitted, phase: phase, now: now, success: nil, failure: nil, environment: nil)
    }

    func record(
        _ lifecycle: Lifecycle,
        phase: Phase,
        progress: ProgressSnapshot? = nil,
        success: Bool? = nil,
        failure: Failure? = nil,
        environment: Environment? = nil
    ) {
        guard startedAt != nil else { return }
        if lifecycle == .progress, ended { return }
        let now = readClock()
        if let progress { latestProgress = ProgressSnapshot(completed: progress.completed, total: progress.total) }
        if lifecycle == .progress {
            // Callback and numerical-advance ages remain accurate even when no
            // event or disk write is allocated for this callback.
            lastCallbackAt = now
            if let progress = latestProgress, progress.fraction > maximumFraction {
                maximumFraction = progress.fraction
                lastAdvanceAt = now
            }
            if let lastPersistedAt, now - lastPersistedAt < Self.progressWriteInterval { return }
        }
        append(lifecycle, phase: phase, now: now, success: success, failure: failure, environment: environment)
        if lifecycle.isTerminal { ended = true }
    }

    private func append(_ lifecycle: Lifecycle, phase: Phase, now: TimeInterval,
                        success: Bool?, failure: Failure?, environment: Environment?) {
        guard let startedAt else { return }
        sequence += 1
        events.append(Event(sequence: sequence, lifecycle: lifecycle, phase: phase,
            elapsedSeconds: max(0, now - startedAt), progress: latestProgress,
            callbackAgeSeconds: lastCallbackAt.map { max(0, now - $0) },
            advanceAgeSeconds: lastAdvanceAt.map { max(0, now - $0) },
            success: success, failure: failure, environment: environment))
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
        lastPersistedAt = now
        persist()
    }

    private func readClock() -> TimeInterval {
        let measured = clock()
        let finite = measured.isFinite && measured >= 0 ? measured : (lastObservedTime ?? 0)
        let now = max(lastObservedTime ?? finite, finite)
        lastObservedTime = now
        return now
    }

    private func load() {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= Int64(Self.maximumBytes),
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1 else { return }
        attemptID = document.attemptID
        events = document.events.suffix(Self.maximumEvents).map { event in
            Event(sequence: max(0, event.sequence), lifecycle: event.lifecycle, phase: event.phase,
                elapsedSeconds: Self.validAge(event.elapsedSeconds) ?? 0,
                progress: event.progress.map { ProgressSnapshot(completed: $0.completed, total: $0.total) },
                callbackAgeSeconds: Self.validAge(event.callbackAgeSeconds),
                advanceAgeSeconds: Self.validAge(event.advanceAgeSeconds),
                success: event.success, failure: event.failure, environment: event.environment)
        }
        // A restored record stays inspectable without appending a different
        // process's clock to it. Only an explicit new attempt starts recording.
    }

    private static func validAge(_ age: TimeInterval?) -> TimeInterval? {
        guard let age, age.isFinite else { return nil }
        return max(0, age)
    }

    private func persist() {
        guard let fileURL, let attemptID else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            var data = try encoder.encode(Document(schemaVersion: 1, attemptID: attemptID, events: events))
            while data.count > Self.maximumBytes, events.count > 1 {
                events.removeFirst()
                data = try encoder.encode(Document(schemaVersion: 1, attemptID: attemptID, events: events))
            }
            guard data.count <= Self.maximumBytes else { return }
            let directory = fileURL.deletingLastPathComponent()
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let temporary = directory.appending(path: ".background-diagnostics-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { return }
            // Atomic replacement retains the temporary file's private mode and
            // data-protection class, including when replacing an older record.
            _ = temporary.withUnsafeFileSystemRepresentation { source in
                fileURL.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return Int32(-1) }
                    return Darwin.rename(source, target)
                }
            }
        } catch {
            // Diagnostics never changes backup authorization or execution.
            // A later lifecycle event can try another bounded write.
        }
    }
}
