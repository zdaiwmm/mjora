import XCTest
import Synchronization
@testable import Imora

final class UploadTransferMeterTests: XCTestCase {
    private func sample(_ id: UUID, _ delta: Int64, _ total: Int64, _ time: TimeInterval, expected: Int64 = 10_000) -> UploadByteProgress {
        .init(transferID: id, bytesSent: delta, totalBytesSent: total, totalBytesExpectedToSend: expected, timestamp: time)
    }

    func testRateUsesMeasuredByteIntervalsAndDecaysToZeroAfterThreeSecondsIdle() throws {
        var meter = UploadTransferMeter()
        let id = UUID()
        XCTAssertTrue(meter.record(sample(id, 100, 100, 10)))
        XCTAssertNil(meter.bytesPerSecond(at: 10), "The first callback has no measured prior interval")
        XCTAssertTrue(meter.record(sample(id, 200, 300, 11)))
        XCTAssertTrue(meter.record(sample(id, 200, 500, 12)))
        XCTAssertEqual(try XCTUnwrap(meter.bytesPerSecond(at: 12)), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(meter.bytesPerSecond(at: 13)), 400.0 / 3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(meter.bytesPerSecond(at: 14)), 200.0 / 3, accuracy: 0.001)
        XCTAssertEqual(meter.bytesPerSecond(at: 15), 0)
        XCTAssertEqual(meter.bytesPerSecond(at: 16), 0)
    }

    func testChunkRequestsHaveSeparateCumulativeCountersAndCannotInventBytesBetweenThem() throws {
        var meter = UploadTransferMeter()
        let first = UUID(), second = UUID()
        meter.record(sample(first, 100, 100, 1))
        meter.record(sample(first, 200, 300, 2))
        meter.record(sample(second, 50, 50, 3))
        meter.record(sample(second, 100, 150, 4))
        // Only second-through-fourth callbacks' measured intervals contribute;
        // the pause between HTTP requests contributes no invented transfer.
        XCTAssertEqual(try XCTUnwrap(meter.bytesPerSecond(at: 4)), 100, accuracy: 0.001)
    }

    func testInvalidDuplicateAndOutOfOrderSamplesCannotIncreaseTheMeasuredRate() throws {
        var meter = UploadTransferMeter()
        let id = UUID()
        meter.record(sample(id, 100, 100, 1))
        meter.record(sample(id, 200, 300, 2))
        let invalid: [UploadByteProgress] = [
            sample(id, -1, 301, 3), sample(id, 500, 400, 3),
            sample(id, 200, 300, 2), sample(id, 10, 310, 1.5),
            sample(id, 10, 310, .nan), sample(id, 10, 310, .infinity),
            sample(id, 10, 310, 3, expected: 300)
        ]
        for item in invalid { XCTAssertFalse(meter.record(item)) }
        XCTAssertEqual(try XCTUnwrap(meter.bytesPerSecond(at: 2)), 200, accuracy: 0.001)
        XCTAssertNil(meter.bytesPerSecond(at: .nan))
        XCTAssertNil(meter.bytesPerSecond(at: 1))
    }

    func testParallelFileSpeedsSumOnlyActualUploadsAndCleanupRejectsLateBytes() throws {
        var transfers = ActiveBackupTransfers()
        let first = transfers.begin(localIdentifier: "one"), second = transfers.begin(localIdentifier: "two")
        var meter = UploadTransferMeter()
        let id = UUID()
        meter.record(sample(id, 100, 100, 1))
        meter.record(sample(id, 200, 300, 2))
        let event = BackupTransferEvent(sequence: 1, filename: "movie.mov", stage: .uploading, fraction: 0.3, meter: meter)
        transfers.apply(event, localIdentifier: "one", attempt: first)
        transfers.apply(event, localIdentifier: "two", attempt: second)
        XCTAssertEqual(try XCTUnwrap(transfers.bytesPerSecond(at: 2)), 400, accuracy: 0.001)
        transfers.apply(.init(sequence: 2, filename: nil, stage: .downloadingOriginal, fraction: 0.5, meter: meter), localIdentifier: "two", attempt: second)
        XCTAssertNil(transfers.items[1].bytesPerSecond(at: 2), "PhotoKit/iCloud speed is not an upload speed")
        XCTAssertEqual(try XCTUnwrap(transfers.bytesPerSecond(at: 2)), 200, accuracy: 0.001)
        transfers.finish(localIdentifier: "one", attempt: first)
        XCTAssertFalse(transfers.apply(event, localIdentifier: "one", attempt: first))
        XCTAssertNil(transfers.bytesPerSecond(at: 2))
    }

    func testOldComponentByteCallbacksCannotLeakSpeedIntoPreparationOrVerification() throws {
        let events = Mutex<[BackupTransferEvent]>([])
        let reporter = BackupTransferProgressReporter { event in events.withLock { $0.append(event) } }
        let old = reporter.component()
        let id = UUID()
        old.uploadByteProgress(sample(id, 100, 100, 1))
        old.uploadByteProgress(sample(id, 200, 300, 2))
        XCTAssertEqual(try XCTUnwrap(events.withLock { $0.last?.meter?.bytesPerSecond(at: 2) }), 200, accuracy: 0.001)
        _ = reporter.component()
        let count = events.withLock { $0.count }
        old.uploadByteProgress(sample(id, 100, 400, 3))
        XCTAssertEqual(events.withLock { $0.count }, count)
        XCTAssertEqual(events.withLock { $0.last?.stage }, .preparing)
        XCTAssertNil(events.withLock { $0.last?.meter })
        reporter.verifying()
        old.uploadByteProgress(sample(id, 100, 500, 4))
        XCTAssertEqual(events.withLock { $0.last?.stage }, .verifying)
        XCTAssertNil(events.withLock { $0.last?.meter })
    }
}
