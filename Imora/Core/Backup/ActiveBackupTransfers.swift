import Foundation
import Synchronization

nonisolated enum BackupTransferStage: Sendable, Equatable {
    case preparing
    case downloadingOriginal
    case uploading
    case verifying
}

/// Metadata and progress from an existing PhotoKit resource request. No extra
/// original is requested to populate the backup screens.
nonisolated struct BackupResourceProgress: Sendable {
    let resourceID: UUID
    let filename: String
    let stage: BackupTransferStage
    let fraction: Double?
}

/// A rolling measurement of actual URLSession bytes over measured callback
/// intervals. The first callback establishes a baseline, not an invented rate.
nonisolated struct UploadTransferMeter: Sendable {
    private struct Baseline: Sendable { let total: Int64; let time: TimeInterval }
    private struct Interval: Sendable { let start: TimeInterval; let end: TimeInterval; let bytes: Double }
    private var baselines: [UUID: Baseline] = [:]
    private var intervals: [Interval] = []
    private var measurementStart: TimeInterval?
    private var latestTime: TimeInterval?
    private let window: TimeInterval = 3

    @discardableResult
    mutating func record(_ sample: UploadByteProgress) -> Bool {
        guard sample.timestamp.isFinite, sample.timestamp >= 0,
              sample.bytesSent >= 0, sample.totalBytesSent >= sample.bytesSent,
              sample.totalBytesExpectedToSend == -1 || sample.totalBytesExpectedToSend >= sample.totalBytesSent,
              latestTime.map({ sample.timestamp >= $0 }) ?? true else { return false }
        if let baseline = baselines[sample.transferID] {
            guard sample.timestamp > baseline.time, sample.totalBytesSent > baseline.total,
                  sample.bytesSent > 0, sample.totalBytesSent - baseline.total >= sample.bytesSent else { return false }
            intervals.append(Interval(start: baseline.time, end: sample.timestamp,
                bytes: Double(sample.totalBytesSent - baseline.total)))
            if measurementStart == nil { measurementStart = baseline.time }
        }
        baselines[sample.transferID] = Baseline(total: sample.totalBytesSent, time: sample.timestamp)
        latestTime = sample.timestamp
        intervals.removeAll { $0.end <= sample.timestamp - window }
        // HTTP chunk requests have separate cumulative counters. Retain only
        // recent baselines so a long video cannot grow this map indefinitely.
        if baselines.count > 64 {
            let retained = Set(baselines.sorted { $0.value.time > $1.value.time }.prefix(64).map(\.key))
            baselines = baselines.filter { retained.contains($0.key) }
        }
        return true
    }

    func bytesPerSecond(at now: TimeInterval) -> Double? {
        guard now.isFinite, let latestTime, now >= latestTime, let measurementStart else { return nil }
        let start = max(measurementStart, now - window)
        let duration = now - start
        guard duration > 0 else { return nil }
        let bytes = intervals.reduce(0.0) { total, interval in
            let overlap = max(0, min(now, interval.end) - max(start, interval.start))
            return total + interval.bytes * overlap / (interval.end - interval.start)
        }
        return bytes / duration
    }
}

nonisolated struct BackupTransferEvent: Sendable {
    let sequence: UInt64
    let filename: String?
    let stage: BackupTransferStage
    let fraction: Double?
    var meter: UploadTransferMeter? = nil

    static func normalized(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }
}

nonisolated struct ActiveBackupTransfer: Identifiable, Sendable {
    let id: String
    let attempt: UUID
    let order: UInt64
    var filename: String?
    var stage: BackupTransferStage = .preparing
    var fraction: Double?
    var sequence: UInt64 = 0
    var meter: UploadTransferMeter?

    func bytesPerSecond(at now: TimeInterval) -> Double? {
        stage == .uploading ? meter?.bytesPerSecond(at: now) : nil
    }
}

/// Attempt tokens and event ordering keep cancelled or completed workers from
/// reviving rows or overwriting the progress of a later attempt for that asset.
nonisolated struct ActiveBackupTransfers: Sendable {
    private var entries: [String: ActiveBackupTransfer] = [:]
    private var nextOrder: UInt64 = 0
    var items: [ActiveBackupTransfer] { entries.values.sorted { $0.order < $1.order } }

    mutating func begin(localIdentifier: String) -> UUID {
        let attempt = UUID()
        nextOrder += 1
        entries[localIdentifier] = ActiveBackupTransfer(id: localIdentifier, attempt: attempt, order: nextOrder)
        return attempt
    }

    @discardableResult
    mutating func apply(_ event: BackupTransferEvent, localIdentifier: String, attempt: UUID) -> Bool {
        guard var entry = entries[localIdentifier], entry.attempt == attempt, event.sequence > entry.sequence else { return false }
        entry.sequence = event.sequence
        if let filename = event.filename { entry.filename = filename }
        entry.stage = event.stage
        entry.fraction = event.stage == .verifying ? nil : BackupTransferEvent.normalized(event.fraction)
        if event.stage == .uploading {
            if let meter = event.meter { entry.meter = meter }
        } else { entry.meter = nil }
        entries[localIdentifier] = entry
        return true
    }

    mutating func finish(localIdentifier: String, attempt: UUID) {
        guard entries[localIdentifier]?.attempt == attempt else { return }
        entries[localIdentifier] = nil
    }

    mutating func removeAll() { entries.removeAll() }

    func bytesPerSecond(at now: TimeInterval) -> Double? {
        let uploads = items.filter { $0.stage == .uploading }
        guard !uploads.isEmpty else { return nil }
        let measured = uploads.compactMap { $0.bytesPerSecond(at: now) }
        guard measured.count == uploads.count else { return nil }
        return measured.reduce(0, +)
    }
}

/// Resource callbacks can arrive on PhotoKit and URLSession queues. The
/// component token rejects late motion/chunk callbacks after the next file or
/// verification begins, and snapshots bound main-actor updates during uploads.
nonisolated final class BackupTransferProgressReporter: Sendable {
    struct Component: Sendable {
        fileprivate let owner: BackupTransferProgressReporter
        fileprivate let id: UUID
        func resourceProgress(_ progress: BackupResourceProgress) { owner.resourceProgress(progress, component: id) }
        func uploading() { owner.uploading(component: id) }
        func uploadProgress(_ fraction: Double) { owner.uploadProgress(fraction, component: id) }
        func uploadByteProgress(_ sample: UploadByteProgress) { owner.uploadByteProgress(sample, component: id) }
    }

    private struct State: Sendable {
        var component: UUID?
        var resource: UUID?
        var sequence: UInt64 = 0
        var filename: String?
        var stage: BackupTransferStage = .preparing
        var fraction: Double?
        var meter = UploadTransferMeter()
        var lastMeterEmission: TimeInterval?
        mutating func event() -> BackupTransferEvent {
            sequence += 1
            return BackupTransferEvent(sequence: sequence, filename: filename, stage: stage, fraction: fraction,
                meter: stage == .uploading ? meter : nil)
        }
    }
    private let state = Mutex(State())
    private let onEvent: @Sendable (BackupTransferEvent) -> Void
    init(_ onEvent: @escaping @Sendable (BackupTransferEvent) -> Void) { self.onEvent = onEvent }

    func component() -> Component {
        let id = UUID()
        let event = state.withLock { value in
            value.component = id; value.resource = nil; value.stage = .preparing; value.fraction = nil
            value.meter = UploadTransferMeter(); value.lastMeterEmission = nil
            return value.event()
        }
        onEvent(event)
        return Component(owner: self, id: id)
    }

    func verifying(filename: String? = nil) {
        let event = state.withLock { value in
            value.component = nil; value.resource = nil; value.stage = .verifying; value.fraction = nil
            if let filename { value.filename = filename }
            value.meter = UploadTransferMeter(); value.lastMeterEmission = nil
            return value.event()
        }
        onEvent(event)
    }

    private func resourceProgress(_ progress: BackupResourceProgress, component: UUID) {
        let event = state.withLock { value -> BackupTransferEvent? in
            guard value.component == component else { return nil }
            switch progress.stage {
            case .preparing:
                if value.resource == progress.resourceID {
                    guard value.stage == .preparing else { return nil }
                } else {
                    guard progress.fraction == nil else { return nil }
                    value.resource = progress.resourceID
                    value.fraction = nil
                    value.meter = UploadTransferMeter(); value.lastMeterEmission = nil
                }
            case .downloadingOriginal:
                guard value.resource == progress.resourceID,
                      value.stage == .preparing || value.stage == .downloadingOriginal else { return nil }
            default: return nil
            }
            let fraction = BackupTransferEvent.normalized(progress.fraction)
            if value.filename == progress.filename, value.stage == progress.stage,
               Self.unchanged(value.fraction, fraction) { return nil }
            value.filename = progress.filename; value.stage = progress.stage; value.fraction = fraction
            return value.event()
        }
        if let event { onEvent(event) }
    }

    private func uploading(component: UUID) {
        let event = state.withLock { value -> BackupTransferEvent? in
            guard value.component == component, value.stage != .uploading else { return nil }
            value.stage = .uploading; value.fraction = nil
            return value.event()
        }
        if let event { onEvent(event) }
    }

    private func uploadProgress(_ fraction: Double, component: UUID) {
        guard let fraction = BackupTransferEvent.normalized(fraction) else { return }
        let event = state.withLock { value -> BackupTransferEvent? in
            guard value.component == component else { return nil }
            if value.stage == .uploading, Self.unchanged(value.fraction, fraction) { return nil }
            value.stage = .uploading; value.fraction = fraction
            return value.event()
        }
        if let event { onEvent(event) }
    }

    private func uploadByteProgress(_ sample: UploadByteProgress, component: UUID) {
        let event = state.withLock { value -> BackupTransferEvent? in
            guard value.component == component, value.meter.record(sample) else { return nil }
            let changedStage = value.stage != .uploading
            value.stage = .uploading
            if changedStage { value.fraction = nil }
            guard changedStage || value.lastMeterEmission.map({ sample.timestamp - $0 >= 0.5 }) ?? true else { return nil }
            value.lastMeterEmission = sample.timestamp
            return value.event()
        }
        if let event { onEvent(event) }
    }

    private static func unchanged(_ old: Double?, _ new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): true
        case (.some(let old), .some(let new)): abs(old - new) < 0.01 && new != 1
        default: false
        }
    }
}
