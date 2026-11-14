import XCTest
import Synchronization
@testable import Imora

final class ActiveBackupTransfersTests: XCTestCase {
    func testSmallMeasuredPreparationAndUploadChangesAreReportedWithoutWaitingForOnePercent() throws {
        let events = Mutex<[BackupTransferEvent]>([])
        let time = Mutex<TimeInterval>(10)
        let reporter = BackupTransferProgressReporter(clock: { time.withLock { $0 } }) { event in events.withLock { $0.append(event) } }
        let component = reporter.component()
        let resource = UUID()
        component.resourceProgress(.init(resourceID: resource, filename: "synthetic.mov", stage: .preparing, fraction: nil))
        component.resourceProgress(.init(resourceID: resource, filename: "synthetic.mov", stage: .preparing, fraction: 0.4))
        time.withLock { $0 += 0.55 }
        component.resourceProgress(.init(resourceID: resource, filename: "synthetic.mov", stage: .preparing, fraction: 0.400001))
        XCTAssertEqual(try XCTUnwrap(events.withLock { $0.last?.fraction }), 0.400001)
        component.uploading()
        component.uploadProgress(0.5)
        time.withLock { $0 += 0.55 }
        component.uploadProgress(0.500001)
        XCTAssertEqual(try XCTUnwrap(events.withLock { $0.last?.fraction }), 0.500001)
    }

    func testMeasuredProgressIsCoalescedByTimeAndFinalFractionIsAlwaysEmitted() throws {
        let events = Mutex<[BackupTransferEvent]>([])
        let time = Mutex<TimeInterval>(10)
        let reporter = BackupTransferProgressReporter(clock: { time.withLock { $0 } }) { event in events.withLock { $0.append(event) } }
        let component = reporter.component()
        component.uploading()
        component.uploadProgress(0.2)
        let initialCount = events.withLock { $0.count }
        for index in 1...100 { component.uploadProgress(0.2 + Double(index) / 100_000) }
        XCTAssertEqual(events.withLock { $0.count }, initialCount)
        time.withLock { $0 += 0.5 }
        component.uploadProgress(0.201001)
        XCTAssertEqual(try XCTUnwrap(events.withLock { $0.last?.fraction }), 0.201001)
        component.uploadProgress(1)
        XCTAssertEqual(events.withLock { $0.last?.fraction }, 1)
    }

    func testPreparationHasNoInventedPercentageAndKeepsOriginalFilename() throws {
        var transfers = ActiveBackupTransfers()
        let attempt = transfers.begin(localIdentifier: "video")
        XCTAssertEqual(transfers.items.first?.stage, .preparing)
        XCTAssertNil(transfers.items.first?.fraction)
        let originalName = "家庭视频 2026.MOV"
        XCTAssertTrue(transfers.apply(.init(sequence: 1, filename: originalName, stage: .preparing, fraction: nil),
            localIdentifier: "video", attempt: attempt))
        XCTAssertEqual(transfers.items.first?.filename, originalName)
        XCTAssertNil(transfers.items.first?.fraction)
        XCTAssertTrue(transfers.apply(.init(sequence: 2, filename: originalName, stage: .downloadingOriginal, fraction: 0.36),
            localIdentifier: "video", attempt: attempt))
        XCTAssertEqual(try XCTUnwrap(transfers.items.first?.fraction), 0.36, accuracy: 0.0001)
        XCTAssertTrue(transfers.apply(.init(sequence: 3, filename: nil, stage: .uploading, fraction: 0.71),
            localIdentifier: "video", attempt: attempt))
        XCTAssertEqual(transfers.items.first?.filename, originalName)
        XCTAssertEqual(transfers.items.first?.stage, .uploading)
        XCTAssertTrue(transfers.apply(.init(sequence: 4, filename: nil, stage: .verifying, fraction: 1),
            localIdentifier: "video", attempt: attempt))
        XCTAssertEqual(transfers.items.first?.stage, .verifying)
        XCTAssertNil(transfers.items.first?.fraction, "Sent bytes cannot stand in for verified backup progress")
    }

    func testParallelWorkersKeepTheirOwnStageAndProgress() throws {
        var transfers = ActiveBackupTransfers()
        let first = transfers.begin(localIdentifier: "first")
        let second = transfers.begin(localIdentifier: "second")
        transfers.apply(.init(sequence: 1, filename: "one.mov", stage: .uploading, fraction: 0.4), localIdentifier: "first", attempt: first)
        transfers.apply(.init(sequence: 1, filename: "two.jpg", stage: .preparing, fraction: nil), localIdentifier: "second", attempt: second)
        XCTAssertEqual(transfers.items.map(\.id), ["first", "second"])
        XCTAssertEqual(try XCTUnwrap(transfers.items[0].fraction), 0.4, accuracy: 0.0001)
        XCTAssertNil(transfers.items[1].fraction)
        transfers.finish(localIdentifier: "first", attempt: first)
        XCTAssertEqual(transfers.items.map(\.id), ["second"])
        XCTAssertEqual(transfers.items[0].filename, "two.jpg")
    }

    func testCompletedCancelledAndReplacedAttemptsIgnoreStaleCallbacks() {
        var transfers = ActiveBackupTransfers()
        let old = transfers.begin(localIdentifier: "asset")
        let fresh = transfers.begin(localIdentifier: "asset")
        let event = BackupTransferEvent(sequence: 9, filename: "old.mov", stage: .uploading, fraction: 0.9)
        XCTAssertFalse(transfers.apply(event, localIdentifier: "asset", attempt: old))
        transfers.finish(localIdentifier: "asset", attempt: old)
        XCTAssertEqual(transfers.items.count, 1)
        XCTAssertTrue(transfers.apply(.init(sequence: 2, filename: "fresh.mov", stage: .verifying, fraction: nil), localIdentifier: "asset", attempt: fresh))
        XCTAssertFalse(transfers.apply(.init(sequence: 1, filename: "fresh.mov", stage: .uploading, fraction: 0.5), localIdentifier: "asset", attempt: fresh))
        XCTAssertEqual(transfers.items[0].stage, .verifying)
        transfers.finish(localIdentifier: "asset", attempt: fresh)
        XCTAssertFalse(transfers.apply(event, localIdentifier: "asset", attempt: fresh))
        XCTAssertTrue(transfers.items.isEmpty)
        let cancelled = transfers.begin(localIdentifier: "cancelled")
        transfers.removeAll()
        XCTAssertFalse(transfers.apply(event, localIdentifier: "cancelled", attempt: cancelled))
        XCTAssertTrue(transfers.items.isEmpty)
    }

    func testUnknownOrNonFiniteProgressStaysIndeterminateAndKnownProgressIsBounded() {
        var transfers = ActiveBackupTransfers()
        let attempt = transfers.begin(localIdentifier: "asset")
        for (index, fraction) in [Double.nan, Double.infinity, -0.5, 2].enumerated() {
            transfers.apply(.init(sequence: UInt64(index + 1), filename: nil, stage: .uploading, fraction: fraction), localIdentifier: "asset", attempt: attempt)
            switch index {
            case 0, 1: XCTAssertNil(transfers.items[0].fraction)
            case 2: XCTAssertEqual(transfers.items[0].fraction, 0)
            default: XCTAssertEqual(transfers.items[0].fraction, 1)
            }
        }
    }

    func testReporterDropsOldResourceAndUploadCallbacksAfterTheNextComponentOrVerification() throws {
        let events = Mutex<[BackupTransferEvent]>([])
        let reporter = BackupTransferProgressReporter { event in events.withLock { $0.append(event) } }
        let motion = reporter.component()
        let firstResource = UUID()
        motion.resourceProgress(.init(resourceID: firstResource, filename: "motion.MOV", stage: .preparing, fraction: nil))
        motion.resourceProgress(.init(resourceID: firstResource, filename: "motion.MOV", stage: .downloadingOriginal, fraction: 0.6))
        motion.uploading()
        motion.uploadProgress(0.7)
        // A late iCloud callback must not put an upload back into downloading.
        let beforeLateDownload = events.withLock { $0.count }
        motion.resourceProgress(.init(resourceID: firstResource, filename: "motion.MOV", stage: .downloadingOriginal, fraction: 1))
        XCTAssertEqual(events.withLock { $0.count }, beforeLateDownload)
        let still = reporter.component()
        let secondResource = UUID()
        still.resourceProgress(.init(resourceID: secondResource, filename: "still.HEIC", stage: .preparing, fraction: nil))
        let beforeLateMotion = events.withLock { $0.count }
        motion.uploadProgress(1)
        XCTAssertEqual(events.withLock { $0.count }, beforeLateMotion)
        still.uploading()
        still.uploadProgress(1)
        reporter.verifying()
        let beforeLateUpload = events.withLock { $0.count }
        still.uploadProgress(1)
        XCTAssertEqual(events.withLock { $0.count }, beforeLateUpload)
        let result = events.withLock { $0 }
        XCTAssertEqual(result.last?.stage, .verifying)
        XCTAssertNil(result.last?.fraction)
        XCTAssertEqual(result.last?.filename, "still.HEIC")
        XCTAssertEqual(result.map(\.sequence), Array(1...UInt64(result.count)))
        XCTAssertTrue(result.contains { $0.stage == .preparing && $0.fraction == nil })
        XCTAssertTrue(result.contains { $0.stage == .uploading && $0.fraction == 0.7 })
    }
}
