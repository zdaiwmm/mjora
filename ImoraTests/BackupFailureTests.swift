import XCTest
@testable import Imora

final class BackupFailureTests: XCTestCase {
    func testFailureClassificationIgnoresLocalizedServerMessage() {
        for message in ["payload too large", "文件太大", "unrelated 401 network text"] {
            XCTAssertEqual(RepeatedBackupFailureKind(error: ImoraError.http(413, message)), .serverSizeLimit)
        }
        for code in [401, 403] {
            XCTAssertEqual(RepeatedBackupFailureKind(error: ImoraError.http(code, "网络失败")), .authorization)
        }
        XCTAssertEqual(RepeatedBackupFailureKind(error: URLError(.timedOut)), .connection)
        XCTAssertEqual(RepeatedBackupFailureKind(error: UploadSizeLimit.exceeded(actualBytes: 12, maximumBytes: 10)), .uploadLimit)
        XCTAssertEqual(RepeatedBackupFailureKind(error: ImoraError.decoding("network HTTP 401 413")), .other)
    }
}

extension BackupFailureTests {
    func testOfficialChecksumHeaderIsDefaultAndCustomRequiresDetection() {
        let url = URL(string: "https://fixture.invalid/api/assets")!
        let standard = UploadChecksumHeader.apply("synthetic-base64", verifiedProduct: nil, to: URLRequest(url: url))
        XCTAssertEqual(standard.value(forHTTPHeaderField: "x-immich-checksum"), "synthetic-base64")
        XCTAssertNil(standard.value(forHTTPHeaderField: "x-imora-checksum"))
        let custom = UploadChecksumHeader.apply("synthetic-base64", verifiedProduct: "imora", to: standard)
        XCTAssertEqual(custom.value(forHTTPHeaderField: "x-imora-checksum"), "synthetic-base64")
        XCTAssertNil(custom.value(forHTTPHeaderField: "x-immich-checksum"))
    }
}
