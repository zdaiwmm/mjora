import CoreGraphics
import XCTest
@testable import Imora

final class PhotoMonthCompositionTests: XCTestCase {
    func testSingleAndTwoDayBandsUseFullThreeToTwoHeight() {
        let single = PhotoMonthComposition(dayCount: 1, contentWidth: 362)
        XCTAssertEqual(single.frames, [CGRect(x: 0, y: 0, width: 362, height: 241.33333333333331)])
        XCTAssertEqual(single.bandCounts, [1])
        let pair = PhotoMonthComposition(dayCount: 2, contentWidth: 362)
        XCTAssertEqual(pair.frames.count, 2)
        XCTAssertEqual(pair.frames[0].width, 179)
        XCTAssertEqual(pair.frames[1].minX, 183)
        XCTAssertEqual(pair.frames[1].maxX, 362)
        XCTAssertEqual(pair.size.height, single.size.height)
        XCTAssertEqual(pair.frames[0].height, pair.size.height)
    }

    func testThreeDayBandHasLargeLeftAndTwoEqualRightCards() {
        let layout = PhotoMonthComposition(dayCount: 3, contentWidth: 362)
        let large = layout.frames[0], upper = layout.frames[1], lower = layout.frames[2]
        XCTAssertEqual(large.height, layout.size.height)
        XCTAssertEqual(large.width / upper.width, 2, accuracy: 0.000001)
        XCTAssertEqual(upper.minX - large.maxX, 4)
        XCTAssertEqual(upper.width, lower.width)
        XCTAssertEqual(upper.height, lower.height)
        XCTAssertEqual(lower.minY - upper.maxY, 4)
        XCTAssertEqual(lower.maxY, layout.size.height, accuracy: 0.000001)
    }

    func testFourDayBandIsTwoByTwoWithFourPointGaps() {
        let layout = PhotoMonthComposition(dayCount: 4, contentWidth: 362)
        XCTAssertEqual(layout.frames[0].size, layout.frames[3].size)
        XCTAssertEqual(layout.frames[0].width, 179)
        XCTAssertEqual(layout.frames[1].minX, 183)
        XCTAssertEqual(layout.frames[2].minX, 0)
        XCTAssertEqual(layout.frames[2].minY - layout.frames[0].maxY, 4)
        XCTAssertEqual(layout.frames[3].maxX, 362)
        XCTAssertEqual(layout.frames[3].maxY, layout.size.height, accuracy: 0.000001)
    }

    func testFiveThroughTenDaysAreBalancedWithoutOneDayTailBands() {
        let expected = [[3, 2], [3, 3], [4, 3], [4, 4], [3, 3, 3], [4, 3, 3]]
        for (offset, counts) in expected.enumerated() {
            let layout = PhotoMonthComposition(dayCount: offset + 5, contentWidth: 362)
            XCTAssertEqual(layout.bandCounts, counts)
            XCTAssertEqual(layout.frames.count, offset + 5)
            XCTAssertEqual(layout.size.height, CGFloat(counts.count) * (362 * (2.0 / 3.0)) + CGFloat(counts.count - 1) * 4,
                           accuracy: 0.000001)
            var index = 0
            var previousBottom: CGFloat = -4
            for count in counts {
                let band = Array(layout.frames[index..<(index + count)])
                let top = band.map(\.minY).min()!
                let bottom = band.map(\.maxY).max()!
                XCTAssertEqual(top - previousBottom, 4, accuracy: 0.000001)
                XCTAssertEqual(bottom - top, 362 * (2.0 / 3.0), accuracy: 0.000001)
                previousBottom = bottom
                index += count
            }
        }
    }

    func testEveryDayHasOnePositiveNonoverlappingBoundedFrameAcrossWidths() {
        for count in 1...62 {
            for width: CGFloat in [1, 8, 12, 200, 362, 728, 1024] {
                let layout = PhotoMonthComposition(dayCount: count, contentWidth: width)
                XCTAssertEqual(layout.frames.count, count)
                XCTAssertEqual(layout.bandCounts.reduce(0, +), count)
                XCTAssertEqual(layout.frames, PhotoMonthComposition(dayCount: count, contentWidth: width).frames)
                XCTAssertEqual(layout.size.width, width)
                for (index, frame) in layout.frames.enumerated() {
                    XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.000001)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.000001)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.000001)
                    XCTAssertLessThanOrEqual(frame.maxY, layout.size.height + 0.000001)
                    for later in layout.frames.dropFirst(index + 1) {
                        let overlap = frame.intersection(later)
                        XCTAssertTrue(overlap.isNull || overlap.width <= 0.000001 || overlap.height <= 0.000001)
                    }
                    if index > 0 { XCTAssertGreaterThanOrEqual(frame.minY, layout.frames[index - 1].minY) }
                }
                XCTAssertEqual(layout.frames.map(\.maxX).max()!, width, accuracy: 0.000001)
                XCTAssertEqual(layout.frames.map(\.maxY).max()!, layout.size.height, accuracy: 0.000001)
            }
        }
    }

    func testUnknownMonthCannotProduceACompleteCompositionAndInvalidWidthsStayFinite() {
        let unknown = PhotoMonthComposition(dayCount: nil, contentWidth: 362)
        XCTAssertTrue(unknown.frames.isEmpty)
        XCTAssertTrue(unknown.bandCounts.isEmpty)
        XCTAssertEqual(unknown.size.height, 0)
        for count in [0, -1] { XCTAssertTrue(PhotoMonthComposition(dayCount: count, contentWidth: 362).frames.isEmpty) }
        for width: CGFloat in [0, -1, .infinity, .nan] {
            let layout = PhotoMonthComposition(dayCount: 10, contentWidth: width)
            XCTAssertTrue(layout.frames.isEmpty)
            XCTAssertEqual(layout.size, .zero)
        }
    }
}
