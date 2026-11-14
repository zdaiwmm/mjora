import XCTest
@testable import Imora

final class ContinuedPreparationProgressTests: XCTestCase {
    func testMeasuredPreparationAdvancesProgressBeforeAnyAssetFinishes() {
        let progress = ContinuedProgress.preparation(completed: 0, total: 1, inFlightFractions: [0.25])
        XCTAssertEqual(progress.completedUnitCount, 50_000)
        XCTAssertEqual(progress.totalUnitCount, 1_000_000)
    }

    func testPreparationCountsCompletedAndConcurrentInFlightAssetsWithoutExceedingItsShare() {
        let progress = ContinuedProgress.preparation(completed: 1, total: 4, inFlightFractions: [0.5, 0.25])
        XCTAssertEqual(progress.completedUnitCount, 87_500)
        XCTAssertEqual(ContinuedProgress.preparation(completed: 2, total: 2, inFlightFractions: [1]).completedUnitCount, 200_000)
    }

    func testUnknownOrInvalidPreparationDoesNotInventNumericalProgress() {
        let progress = ContinuedProgress.preparation(completed: 0, total: 2, inFlightFractions: [nil, Double.nan, Double.infinity, -1])
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertEqual(ContinuedProgress.preparation(completed: 0, total: 0, inFlightFractions: [0.8]).completedUnitCount, 0)
    }
}
