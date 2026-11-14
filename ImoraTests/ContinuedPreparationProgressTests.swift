import XCTest
@testable import Imora

final class ContinuedPreparationProgressTests: XCTestCase {
    func testMeasuredPreparationAdvancesProgressBeforeAnyAssetFinishes() {
        let progress = ContinuedProgress.preparation(completed: 0, total: 1, inFlightFractions: [0.25])
        XCTAssertEqual(progress.completedUnitCount, 50_000_000_000)
        XCTAssertEqual(progress.totalUnitCount, 1_000_000_000_000)
    }

    func testPreparationCountsCompletedAndConcurrentInFlightAssetsWithoutExceedingItsShare() {
        let progress = ContinuedProgress.preparation(completed: 1, total: 4, inFlightFractions: [0.5, 0.25])
        XCTAssertEqual(progress.completedUnitCount, 87_500_000_000)
        XCTAssertEqual(ContinuedProgress.preparation(completed: 2, total: 2, inFlightFractions: [1]).completedUnitCount, 200_000_000_000)
    }

    func testUnknownOrInvalidPreparationDoesNotInventNumericalProgress() {
        let progress = ContinuedProgress.preparation(completed: 0, total: 2, inFlightFractions: [nil, Double.nan, Double.infinity, -1])
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertEqual(ContinuedProgress.preparation(completed: 0, total: 0, inFlightFractions: [0.8]).completedUnitCount, 0)
    }

    func testSmallMeasuredVideoChangesRemainVisibleInALargeLibrary() {
        let before = ContinuedProgress(fraction: 0.3 + 0.7 * 0.1000000 / 6_000)
        let after = ContinuedProgress(fraction: 0.3 + 0.7 * 0.1000001 / 6_000)
        XCTAssertGreaterThan(after.completedUnitCount, before.completedUnitCount,
            "Real transferred bytes must not disappear when the library is large")
    }

    func testCheckingAdvancesOnlyForCompletedWorkAndDoesNotOverlapUploadBudget() {
        XCTAssertEqual(ContinuedProgress.checking(completed: 0, total: 100).fractionCompleted, 0.2)
        XCTAssertEqual(ContinuedProgress.checking(completed: 50, total: 100).fractionCompleted, 0.25)
        XCTAssertEqual(ContinuedProgress.checking(completed: 100, total: 100).fractionCompleted, 0.3)
        XCTAssertEqual(ContinuedProgress.checking(completed: 100, total: 0).fractionCompleted, 0.2)
        XCTAssertEqual(ContinuedProgress.checking(completed: -1, total: 100).fractionCompleted, 0.2)
        XCTAssertEqual(ContinuedProgress.checking(completed: 200, total: 100).fractionCompleted, 0.3)
    }
}
