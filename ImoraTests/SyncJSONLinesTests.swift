import XCTest
@testable import Imora

final class SyncJSONLinesTests: XCTestCase {
    func testChunkedLinesRetainExactServerAcknowledgements() throws {
        var parser = RemoteSyncJSONLines()
        XCTAssertTrue(try parser.append(Data(#"{"type":"SyncComp"#.utf8)).isEmpty)
        let records = try parser.append(Data("leteV1\",\"ack\":\"SyncCompleteV1|123\",\"data\":{}}\n".utf8))
        XCTAssertEqual(records.map(\.ack), ["SyncCompleteV1|123"])
        try parser.finish()
    }

    func testUnfinishedAndOversizedRecordsFailClosed() throws {
        var parser = RemoteSyncJSONLines()
        _ = try parser.append(Data("{".utf8))
        XCTAssertThrowsError(try parser.finish())
        XCTAssertThrowsError(try parser.append(Data(repeating: 32, count: 256 * 1024)))
    }

    func testUnknownRecordCannotBeAcknowledged() {
        var parser = RemoteSyncJSONLines()
        XCTAssertThrowsError(try parser.append(Data("{\"type\":\"AssetV99\",\"ack\":\"opaque\",\"data\":{}}\n".utf8)))
    }
}
