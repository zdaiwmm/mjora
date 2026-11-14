import XCTest
@testable import Imora

final class ContinuedSubmissionStateTests: XCTestCase {
    func testAcceptedRequestBlocksDuplicateSubmissionsUntilItFinishes() throws {
        var state = ContinuedSubmissionState()
        let owner = UUID()
        let submission = try XCTUnwrap(state.beginSubmission(owner: owner))
        XCTAssertEqual(state.status, .accepting)
        XCTAssertNil(state.beginSubmission(owner: owner))
        state.completeSubmission(submission, failure: nil)
        XCTAssertEqual(state.status, .accepted)
        XCTAssertNil(state.beginSubmission(owner: owner))
        XCTAssertTrue(state.didStart(submission, owner: owner))
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.beginSubmission(owner: owner))
        state.didFinish(submission, paused: false)
        XCTAssertNotNil(state.beginSubmission(owner: owner))
    }

    func testLaunchBeforeSubmissionCompletionCannotRegressRunningState() throws {
        var state = ContinuedSubmissionState()
        let owner = UUID()
        let submission = try XCTUnwrap(state.beginSubmission(owner: owner))
        XCTAssertTrue(state.didStart(submission, owner: owner))
        state.completeSubmission(submission, failure: nil)
        XCTAssertEqual(state.status, .running)
    }

    func testOldSubmissionFailureCannotCancelANewExplicitRequest() throws {
        var state = ContinuedSubmissionState()
        let owner = UUID()
        let expired = try XCTUnwrap(state.beginSubmission(owner: owner))
        XCTAssertTrue(state.didStart(expired, owner: owner))
        state.didFinish(expired, paused: true)
        XCTAssertEqual(state.status, .paused)
        let fresh = try XCTUnwrap(state.beginSubmission(owner: owner))
        state.completeSubmission(expired, failure: .systemUnavailable)
        XCTAssertEqual(state.status, .accepting)
        state.completeSubmission(fresh, failure: nil)
        XCTAssertEqual(state.status, .accepted)
    }

    func testDeniedRequestRemainsVisibleAndAllowsExplicitRetry() throws {
        var state = ContinuedSubmissionState()
        let owner = UUID()
        let submission = try XCTUnwrap(state.beginSubmission(owner: owner))
        state.completeSubmission(submission, failure: .systemBusy)
        XCTAssertEqual(state.status, .denied(.systemBusy))
        XCTAssertFalse(state.didStart(submission, owner: owner))
        XCTAssertNotNil(state.beginSubmission(owner: owner))
    }

    func testReplacementOwnerCannotLaunchAnEarlierOwnersAcceptedRequest() throws {
        var state = ContinuedSubmissionState()
        let firstOwner = UUID(), replacementOwner = UUID()
        let request = try XCTUnwrap(state.beginSubmission(owner: firstOwner))
        state.completeSubmission(request, failure: nil)
        XCTAssertFalse(state.didStart(request, owner: replacementOwner))
        XCTAssertTrue(state.didStart(request, owner: firstOwner))
    }

    func testOwnerInvalidationRejectsOldLaunchAndCompletionWithoutTouchingANewRequest() throws {
        var state = ContinuedSubmissionState()
        let firstOwner = UUID(), replacementOwner = UUID()
        let old = try XCTUnwrap(state.beginSubmission(owner: firstOwner))
        state.completeSubmission(old, failure: nil)
        state.invalidateOwner()
        XCTAssertEqual(state.status, .idle)
        XCTAssertFalse(state.didStart(old, owner: replacementOwner))
        let fresh = try XCTUnwrap(state.beginSubmission(owner: replacementOwner))
        state.completeSubmission(old, failure: .systemUnavailable)
        XCTAssertEqual(state.status, .accepting)
        XCTAssertTrue(state.didStart(fresh, owner: replacementOwner))
        state.didFinish(old, paused: true)
        XCTAssertEqual(state.status, .running)
    }

    func testClearingOwnerWhileSubmissionIsInFlightDoesNotLeaveAnAcceptedRequestBehind() throws {
        var state = ContinuedSubmissionState()
        let request = try XCTUnwrap(state.beginSubmission(owner: UUID()))
        state.invalidateOwner()
        state.completeSubmission(request, failure: nil)
        XCTAssertEqual(state.status, .idle)
        XCTAssertNotNil(state.beginSubmission(owner: UUID()))
    }
}
