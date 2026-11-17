#if DEBUG || PHASE4_PERFORMANCE
import Foundation
import Darwin
import UIKit

nonisolated private struct GalleryFrameRecord: Codable, Sendable {
    let phase: String
    let durationMS: Double
    let firstCallbackMS: Double?
    let intervalsMS: [Double]
    let expectedIntervalsMS: [Double]
    let beganUptimeMS: Double?
    let endedUptimeMS: Double?
    let correlationID: UUID?
}

nonisolated struct GalleryFrameSpanToken: Sendable {
    fileprivate let name: String
    fileprivate let correlationID: UUID?
    fileprivate let phase: String?
    fileprivate let began: Double
    fileprivate let beganCPU: Double?
}

nonisolated private struct GalleryFrameSpan: Codable, Sendable {
    let name: String
    let correlationID: UUID?
    let phase: String?
    let beganUptimeMS: Double
    let endedUptimeMS: Double
    let wallMS: Double
    let threadCPUMS: Double?
    let values: [String: Double]?
}

nonisolated private struct GalleryFrameWorkSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let processID: Int32
    let frames: [GalleryFrameRecord]
    let spans: [GalleryFrameSpan]
}

/// Opt-in main-run-loop evidence when XCTest does not supply hitch metrics.
/// This measures CAD callback spacing, not GPU presentation or physical-device FPS.
@MainActor
final class GalleryFrameMetrics: NSObject {
    static let shared = GalleryFrameMetrics()
    private static let spansEnabled = ProcessInfo.processInfo.environment["IMORA_VIEWER_SPANS"] == "1"
    private static let enabled = ProcessInfo.processInfo.environment["IMORA_FRAME_TRACE"] == "1" || spansEnabled
    private var link: CADisplayLink?
    private var phase: String?
    private var correlationID: UUID?
    private var began = 0.0
    private var previous: Double?
    private var firstCallback: Double?
    private var intervals: [Double] = []
    private var expected: [Double] = []
    private var records: [GalleryFrameRecord] = []
    private var spans: [GalleryFrameSpan] = []
    private var writeTask: Task<Void, Never>?

    func begin(_ phase: String, correlationID: UUID? = nil) {
        guard Self.enabled else { return }
        if let current = self.phase { end(current) }
        self.phase = phase
        self.correlationID = correlationID
        began = ProcessInfo.processInfo.systemUptime
        previous = nil; firstCallback = nil
        intervals = []; expected = []
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func end(_ phase: String) {
        guard Self.enabled, self.phase == phase else { return }
        link?.invalidate(); link = nil
        let ended = ProcessInfo.processInfo.systemUptime
        records.append(.init(phase: phase, durationMS: (ended - began) * 1_000,
            firstCallbackMS: firstCallback, intervalsMS: intervals, expectedIntervalsMS: expected,
            beganUptimeMS: Self.spansEnabled ? began * 1_000 : nil,
            endedUptimeMS: Self.spansEnabled ? ended * 1_000 : nil,
            correlationID: correlationID))
        if records.count > 128 { records.removeFirst() }
        self.phase = nil
        correlationID = nil
        let snapshot = records
        let work = Self.spansEnabled ? GalleryFrameWorkSnapshot(schemaVersion: 1,
            processID: ProcessInfo.processInfo.processIdentifier, frames: records, spans: spans) : nil
        let previousWrite = writeTask
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "gallery-frame-metrics-\(ProcessInfo.processInfo.processIdentifier).json")
        let workURL = url.deletingLastPathComponent()
            .appending(path: "gallery-work-spans-\(ProcessInfo.processInfo.processIdentifier).json")
        writeTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
            if let work, let data = try? JSONEncoder().encode(work) { try? data.write(to: workURL, options: .atomic) }
        }
    }

    /// Only synchronous work may use this token's thread CPU clock.
    func beginSpan(_ name: String, correlationID: UUID? = nil) -> GalleryFrameSpanToken? {
        guard Self.spansEnabled else { return nil }
        return .init(name: name, correlationID: correlationID, phase: phase,
                     began: ProcessInfo.processInfo.systemUptime, beganCPU: Self.threadCPUTime())
    }

    func endSpan(_ token: GalleryFrameSpanToken?) {
        guard let token else { return }
        let cpu = Self.threadCPUTime()
        let ended = ProcessInfo.processInfo.systemUptime
        append(.init(name: token.name, correlationID: token.correlationID, phase: token.phase,
            beganUptimeMS: token.began * 1_000, endedUptimeMS: ended * 1_000,
            wallMS: (ended - token.began) * 1_000,
            threadCPUMS: token.beganCPU.flatMap { start in cpu.map { max(0, $0 - start) * 1_000 } },
            values: nil))
    }

    func measure<T>(_ name: String, correlationID: UUID? = nil, _ body: () throws -> T) rethrows -> T {
        let token = beginSpan(name, correlationID: correlationID)
        defer { endSpan(token) }
        return try body()
    }

    /// Queueing and async suspension use wall-clock markers, never thread CPU.
    func mark(_ name: String, correlationID: UUID? = nil,
              values: @autoclosure () -> [String: Double]? = nil) {
        guard Self.spansEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime * 1_000
        append(.init(name: name, correlationID: correlationID, phase: phase,
                     beganUptimeMS: now, endedUptimeMS: now, wallMS: 0, threadCPUMS: nil,
                     values: values()))
    }

    private func append(_ span: GalleryFrameSpan) {
        spans.append(span)
        if spans.count > 512 { spans.removeFirst(spans.count - 512) }
    }

    private static func threadCPUTime() -> Double? {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return nil }
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @objc private func tick(_ sender: CADisplayLink) {
        if firstCallback == nil { firstCallback = (ProcessInfo.processInfo.systemUptime - began) * 1_000 }
        if let previous, intervals.count < 2_000 {
            intervals.append((sender.timestamp - previous) * 1_000)
            expected.append((sender.targetTimestamp - sender.timestamp) * 1_000)
        }
        previous = sender.timestamp
    }
}
#endif
