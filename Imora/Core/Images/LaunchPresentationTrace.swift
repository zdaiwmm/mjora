#if DEBUG || PHASE4_PERFORMANCE
import Foundation
import UIKit
import Synchronization

nonisolated enum LaunchPipelineTrace {
    struct Event: Codable, Sendable {
        let phase: String
        let started: Double
        let durationMS: Double
        let items: Int
    }
    static let enabled = ProcessInfo.processInfo.environment["IMORA_LAUNCH_TRACE"] == "1"
    private static let events = Mutex<[Event]>([])
    static func record(_ phase: String, since start: Double, items: Int = 1) {
        guard enabled else { return }
        let event = Event(phase: phase, started: start,
            durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000, items: items)
        events.withLock { if $0.count < 512 { $0.append(event) } }
    }
    static func snapshot() -> [Event] { events.withLock { $0 } }
    static func mark(_ phase: String, items: Int = 1) {
        record(phase, since: ProcessInfo.processInfo.systemUptime, items: items)
    }
}

/// Opt-in diagnostic evidence, not a shipping readiness flag or a GPU timer.
/// Root captures the simulator framebuffer separately to corroborate these
/// actual mounted-tile/bitmap observations.
nonisolated struct GridFrameObservation: Codable, Sendable {
    struct Tile: Codable, Sendable, Equatable {
        let assetID: String
        let rect: [Double]
        let bitmapPixels: [Int]
        let requestedPixels: Int
        let realBitmap: Bool
        let adequatePixels: Bool
        let sourceRevision: String
        let contentGeneration: String
    }
    /// Schema3 uses actual observation uptime for both origins.
    let timestamp: Double
    let observationOrigin: String
    let cadDisplayTimestamp: Double?
    let applicationActive: Bool
    let viewInteractionEnabled: Bool
    let offset: Double
    let viewport: [Double]
    let rowVersion: Int
    let tiles: [Tile]
    let placeholderRows: Int
    let expectedW0: [String]
    let expectedAnchor: String?
    let restoredComplete: Bool
    let interactive: Bool
    let serverIdentity: String?
    let accountID: String?
    let galleryVisible: Bool
    let loadingOverlayVisible: Bool
    let reportedItemCount: Int

    var hasContent: Bool { !tiles.isEmpty || placeholderRows > 0 }
    var complete: Bool {
        !tiles.isEmpty && placeholderRows == 0 && tiles.allSatisfy { $0.realBitmap && $0.adequatePixels }
            && (expectedW0.isEmpty || Set(expectedW0) == Set(tiles.map(\.assetID)))
    }

    /// Event-driven priming evidence ignores observation-clock changes.
    func depictsSameGallery(as other: Self) -> Bool {
        applicationActive == other.applicationActive && viewInteractionEnabled == other.viewInteractionEnabled
            && offset == other.offset && viewport == other.viewport && rowVersion == other.rowVersion
            && tiles == other.tiles && placeholderRows == other.placeholderRows && expectedW0 == other.expectedW0
            && expectedAnchor == other.expectedAnchor && restoredComplete == other.restoredComplete
            && interactive == other.interactive && serverIdentity == other.serverIdentity && accountID == other.accountID
            && galleryVisible == other.galleryVisible && loadingOverlayVisible == other.loadingOverlayVisible
            && reportedItemCount == other.reportedItemCount
    }
}

@MainActor
final class LaunchPresentationTrace: NSObject {
    static let enabled = ProcessInfo.processInfo.environment["IMORA_LAUNCH_TRACE"] == "1"
    private(set) static var began = ProcessInfo.processInfo.systemUptime
    private(set) static var checkpoint: LaunchViewportSnapshot?
    static func begin() { began = ProcessInfo.processInfo.systemUptime; LaunchPipelineTrace.mark("app-init") }
    private static let observers = NSHashTable<LaunchPresentationTrace>.weakObjects()
    static func didCheckpoint(_ snapshot: LaunchViewportSnapshot) {
        guard checkpoint != snapshot else { return }
        checkpoint = snapshot
        for observer in observers.allObjects { observer.schedulePrimingSnapshot() }
    }

    private weak var grid: TimelineGridView?
    private var link: CADisplayLink?
    private var beforeWaiting: CFRunLoopObserver?
    private var frames: [GridFrameObservation] = []
    private var first: GridFrameObservation?
    private var firstInteractive: GridFrameObservation?
    private var firstQualifiedGrid: GridFrameObservation?
    private var finished = false
    private var stopped = false
    private var snapshotTask: Task<Void, Never>?
    private var lastPublishedFrame: GridFrameObservation?
    private var lastPublishedCheckpoint: LaunchViewportSnapshot?
    private let traceID = UUID().uuidString

    init(grid: TimelineGridView) {
        self.grid = grid
        super.init()
        Self.observers.add(self)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample(origin: "runloop-before-waiting", displayTimestamp: nil) }
        }
        beforeWaiting = observer
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        grid.accessibilityIdentifier = "phase4-launch-grid-probe"
    }

    func stop() {
        finishArtifact(reason: "stopped-before-window-complete")
        stopped = true
        snapshotTask?.cancel(); snapshotTask = nil
        Self.observers.remove(self)
        stopPolling()
    }

    private func stopPolling() {
        link?.invalidate(); link = nil
        if let beforeWaiting { CFRunLoopRemoveObserver(CFRunLoopGetMain(), beforeWaiting, .commonModes) }
        beforeWaiting = nil
    }

    /// Called at the real end of UIKit grid layout after mounted tile bindings,
    /// independently of CAD delivery, readiness or application-active state.
    func didCompleteLayout() {
        if finished { schedulePrimingSnapshot() }
        else { sample(origin: "uikit-layout", displayTimestamp: nil) }
    }

    private func schedulePrimingSnapshot() {
        guard finished, !stopped, snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer { self.snapshotTask = nil }
            guard !Task.isCancelled, !self.stopped else { return }
            self.sample(origin: "priming-event", displayTimestamp: nil, primingSnapshot: true)
        }
    }

    private func finishArtifact(reason: String) {
        guard !finished, !frames.isEmpty else { return }
        finished = true
        stopPolling()
        let artifact = Artifact(schemaVersion: 3, traceID: traceID, began: Self.began, frames: frames,
            firstInteractive: firstInteractive, firstQualifiedGrid: firstQualifiedGrid,
            finishReason: reason, pipeline: LaunchPipelineTrace.snapshot())
        Task.detached(priority: .utility) { try? Self.write(artifact) }
    }

    @objc private func tick(_ sender: CADisplayLink) {
        sample(origin: "cad", displayTimestamp: sender.timestamp)
        if first != nil, let beforeWaiting {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), beforeWaiting, .commonModes)
            self.beforeWaiting = nil
        }
    }

    private func sample(origin: String, displayTimestamp: Double?, primingSnapshot: Bool = false) {
        guard !stopped, !finished || primingSnapshot else { return }
        guard let grid, grid.window != nil else { stop(); return }
        let frame = grid.presentationObservation(timestamp: ProcessInfo.processInfo.systemUptime,
            origin: origin, displayTimestamp: displayTimestamp)
        if finished, let lastPublishedFrame, frame.depictsSameGallery(as: lastPublishedFrame),
           Self.checkpoint == lastPublishedCheckpoint { return }
        // The visible gallery shell is user-visible content even before it
        // has tiles. Excluding it would hide loading/false-empty exposure.
        if !finished, first == nil, frame.galleryVisible {
            first = frame
            LaunchPipelineTrace.mark("first-visible-gallery")
        }
        if !finished, firstInteractive == nil, frame.galleryVisible, frame.interactive {
            firstInteractive = frame
            LaunchPipelineTrace.mark("first-interactive-gallery")
        }
        if !finished, firstQualifiedGrid == nil, frame.galleryVisible, !frame.loadingOverlayVisible, frame.reportedItemCount > 0, frame.complete, frame.interactive {
            firstQualifiedGrid = frame
            LaunchPipelineTrace.mark("first-qualified-grid")
        }
        if !finished, first != nil {
            frames.append(frame)
            if let firstQualifiedGrid, frame.timestamp - firstQualifiedGrid.timestamp >= 2 {
                finishArtifact(reason: "two-seconds-after-qualified-interactive")
            } else if let first, frame.timestamp - first.timestamp >= 5 {
                finishArtifact(reason: "bounded-five-second-incomplete-window")
            }
        }

        let summary = Summary(traceID: traceID, observationComplete: finished, first: first, latest: frame, firstInteractive: firstInteractive,
            checkpointAnchor: Self.checkpoint?.anchor, checkpointW0: Self.checkpoint?.visibleKeys.map { key -> String in
                switch key.subject {
                case .remoteAsset(let id): id
                case .localAsset(_, let id): "local-\(id)"
                case .artwork(_, let id, _): id
                }
            } ?? [], processToFirstContentMS: firstQualifiedGrid.map { ($0.timestamp - Self.began) * 1000 },
            appInitToFirstGalleryMS: first.map { ($0.timestamp - Self.began) * 1000 },
            sampledFrames: frames.count, incompleteFrames: frames.filter { !$0.complete || !$0.viewInteractionEnabled || !$0.galleryVisible || $0.loadingOverlayVisible || $0.reportedItemCount <= 0 || $0.reportedItemCount != first?.reportedItemCount }.count)
        // No disk IO on this path. Only the opt-in AX probe is updated.
        if let data = try? JSONEncoder().encode(summary) {
            grid.accessibilityValue = String(decoding: data, as: UTF8.self)
            lastPublishedFrame = frame
            lastPublishedCheckpoint = Self.checkpoint
        }
    }

    private struct Summary: Codable {
        let traceID: String
        let observationComplete: Bool
        let first: GridFrameObservation?
        let latest: GridFrameObservation
        let firstInteractive: GridFrameObservation?
        let checkpointAnchor: String?
        let checkpointW0: [String]
        let processToFirstContentMS: Double?
        let appInitToFirstGalleryMS: Double?
        let sampledFrames: Int
        let incompleteFrames: Int
    }
    private nonisolated struct Artifact: Codable, Sendable {
        let schemaVersion: Int
        let traceID: String
        let began: Double
        let frames: [GridFrameObservation]
        let firstInteractive: GridFrameObservation?
        let firstQualifiedGrid: GridFrameObservation?
        let finishReason: String
        let pipeline: [LaunchPipelineTrace.Event]
    }
    private nonisolated static func write(_ artifact: Artifact) throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/launch-measurements")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(max(0, files.count - 39)) {
            try? FileManager.default.removeItem(at: file)
        }
        try JSONEncoder().encode(artifact).write(to: root.appending(path: "\(artifact.traceID).json"), options: .atomic)
    }
}
#endif
