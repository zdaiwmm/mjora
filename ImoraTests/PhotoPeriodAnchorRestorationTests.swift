import XCTest
@testable import Imora

final class PhotoPeriodAnchorRestorationTests: XCTestCase {
    func testKnownDataRemainsPendingUntilTheMatchingDayIsLaidOut() {
        var restoration = PhotoPeriodAnchorRestoration()
        let request = restoration.begin(assetID: "photo", periodID: "2025-01")
        XCTAssertEqual(restoration.request, request, "Knowing a day exists does not register its lazy scroll target")
        XCTAssertTrue(restoration.consumeReachableDay(ticket: request.ticket, assetID: "photo", periodID: "2025-01"))
        XCTAssertNil(restoration.request)
        XCTAssertFalse(restoration.consumeReachableDay(ticket: request.ticket, assetID: "photo", periodID: "2025-01"))
    }

    func testAnotherMonthOrPhotoCannotCompleteThePendingRestoration() {
        var restoration = PhotoPeriodAnchorRestoration()
        let request = restoration.begin(assetID: "photo", periodID: "2025-01")
        XCTAssertFalse(restoration.consumeReachableDay(ticket: request.ticket, assetID: "other", periodID: "2025-01"))
        XCTAssertFalse(restoration.consumeReachableDay(ticket: request.ticket, assetID: "photo", periodID: "2025-02"))
        XCTAssertEqual(restoration.request, request)
    }

    func testSupersededLayoutCallbackCannotConsumeANewerRequestForTheSamePhoto() {
        var restoration = PhotoPeriodAnchorRestoration()
        let old = restoration.begin(assetID: "photo", periodID: "2025-01")
        let latest = restoration.begin(assetID: "photo", periodID: "2025-01")
        XCTAssertFalse(restoration.consumeReachableDay(ticket: old.ticket, assetID: "photo", periodID: "2025-01"))
        XCTAssertEqual(restoration.request, latest)
        XCTAssertTrue(restoration.consumeReachableDay(ticket: latest.ticket, assetID: "photo", periodID: "2025-01"))
    }

    func testUserScrollCancellationRejectsDelayedLayoutAndUnknownIndexStaysPending() {
        var restoration = PhotoPeriodAnchorRestoration()
        let unknown = restoration.begin(assetID: "photo", periodID: nil)
        XCTAssertFalse(restoration.consumeReachableDay(ticket: unknown.ticket, assetID: "photo", periodID: "2025-01"))
        restoration.cancel()
        XCTAssertNil(restoration.request)
        XCTAssertFalse(restoration.consumeReachableDay(ticket: unknown.ticket, assetID: "photo", periodID: "2025-01"))
    }
}
