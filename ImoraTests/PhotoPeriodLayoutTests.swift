import CoreGraphics
import Foundation
import XCTest
@testable import Imora

@MainActor
final class PhotoPeriodLayoutTests: XCTestCase {
    func testNativePhonePhotoFramesExcludeMonthHeadingAndScaleWithViewport() {
        let month = PhotoPeriodCardLayout(viewportWidth: 402, mode: .months)
        XCTAssertEqual(month.photoSize.width, 362)
        XCTAssertEqual(month.photoSize.height, 241.333333, accuracy: 0.001)
        let year = PhotoPeriodCardLayout(viewportWidth: 402, mode: .years)
        XCTAssertEqual(year.photoSize, CGSize(width: 362, height: 271.5))
        let wider = PhotoPeriodCardLayout(viewportWidth: 768, mode: .months)
        XCTAssertEqual(wider.photoSize.width, 728)
        XCTAssertEqual(wider.photoSize.height, 485.333333, accuracy: 0.001)
        XCTAssertEqual(PhotoPeriodCardLayout(viewportWidth: 20, mode: .months).photoSize, .zero)
        XCTAssertEqual(PhotoPeriodCardLayout(viewportWidth: .infinity, mode: .years).photoSize, .zero)
    }

    func testChronologicalPresentationRetainsEveryUnloadedPeriodAndItsCount() {
        let sections = [
            TimelineSection(id: "2026-11-01T00:00:00.000Z", monthTitle: "November", count: 3, days: nil),
            TimelineSection(id: "2018-03-01T00:00:00.000Z", monthTitle: "March", count: 1, days: nil),
            TimelineSection(id: "2026-01-01T00:00:00.000Z", monthTitle: "January", count: 2, days: nil)
        ]
        let months = PhotoPeriodCardLayout.oldestFirst(PhotoPeriod.months(in: sections))
        XCTAssertEqual(months.map(\.id), ["2018-03", "2026-01", "2026-11"])
        XCTAssertEqual(months.map(\.count), [1, 2, 3])
        let years = PhotoPeriodCardLayout.oldestFirst(PhotoPeriod.years(in: sections))
        XCTAssertEqual(years.map(\.year), [2018, 2026])
        XCTAssertEqual(years.map(\.count), [1, 5])
    }
}
