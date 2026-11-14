import XCTest
@testable import Imora

final class BackupRemovalDisplayTests: XCTestCase {
    func testCloudRemovedRevisionIsNeitherPendingNorFailedEvenAfterEdit() {
        let asset = fixtureDevice()
        var entry = BackupEntry(modificationDate: asset.modificationDate, isLivePhoto: false, primaryChecksum: "checksum")
        entry.remoteDeletionDetected = true
        for revision in [asset.modificationDate, Date(timeIntervalSince1970: 999)] {
            entry.modificationDate = revision
            let status = BackupLibraryStatus(assets: [asset], entries: [asset.localIdentifier: entry])
            XCTAssertEqual(status.pending, 0)
            XCTAssertEqual(status.backedUp, 0)
            XCTAssertEqual(status.unindexed, 0)
        }
    }
}
