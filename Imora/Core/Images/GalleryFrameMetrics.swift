#if DEBUG || PHASE4_PERFORMANCE
import Foundation
import UIKit

nonisolated private struct GalleryFrameRecord: Codable, Sendable {
    let phase: String
    let durationMS: Double
    let firstCallbackMS: Double?
    let intervalsMS: [Double]
    let expectedIntervalsMS: [Double]
}

/// Opt-in main-run-loop evidence when XCTest does not supply hitch metrics.
/// This measures CAD callback spacing, not GPU presentation or physical-device FPS.
@MainActor
final class GalleryFrameMetrics: NSObject {
    static let shared = GalleryFrameMetrics()
    private static let enabled = ProcessInfo.processInfo.environment["IMORA_FRAME_TRACE"] == "1"
    private var link: CADisplayLink?
    private var phase: String?
    private var began = 0.0
    private var previous: Double?
    private var firstCallback: Double?
    private var intervals: [Double] = []
    private var expected: [Double] = []
    private var records: [GalleryFrameRecord] = []
    private var writeTask: Task<Void, Never>?

    func begin(_ phase: String) {
        guard Self.enabled else { return }
        if let current = self.phase { end(current) }
        self.phase = phase
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
        records.append(.init(phase: phase, durationMS: (ProcessInfo.processInfo.systemUptime - began) * 1_000,
            firstCallbackMS: firstCallback, intervalsMS: intervals, expectedIntervalsMS: expected))
        if records.count > 128 { records.removeFirst() }
        self.phase = nil
        let snapshot = records
        let previousWrite = writeTask
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "gallery-frame-metrics-\(ProcessInfo.processInfo.processIdentifier).json")
        writeTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
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
