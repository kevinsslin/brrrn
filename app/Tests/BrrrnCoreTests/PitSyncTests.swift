import XCTest
@testable import BrrrnCore

final class PitSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoSubmitWithoutData() {
        XCTAssertFalse(PitSync.submitDue(PitSyncState(), signature: nil, now: now))
    }

    func testNoSubmitWhenSignatureUnchanged() {
        let state = PitSyncState(lastSubmitSignature: "sig", lastSubmitAt: now.addingTimeInterval(-10_000))
        XCTAssertFalse(PitSync.submitDue(state, signature: "sig", now: now))
    }

    func testSubmitsWhenSignatureChangedAndIntervalElapsed() {
        let state = PitSyncState(
            lastSubmitSignature: "old",
            lastSubmitAt: now.addingTimeInterval(-(PitSync.submitMinInterval + 1))
        )
        XCTAssertTrue(PitSync.submitDue(state, signature: "new", now: now))
    }

    func testHoldsSubmitWithinMinInterval() {
        let state = PitSyncState(lastSubmitSignature: "old", lastSubmitAt: now.addingTimeInterval(-30))
        XCTAssertFalse(PitSync.submitDue(state, signature: "new", now: now))
    }

    func testFirstSubmitNeedsNoPriorTimestamp() {
        XCTAssertTrue(PitSync.submitDue(PitSyncState(), signature: "new", now: now))
    }

    func testSafetyFlushResubmitsUnchangedWindowAfterMaxGap() {
        // Nothing the signature can see has changed, but the model breakdown
        // might have; a re-push is due once the max gap elapses.
        let state = PitSyncState(
            lastSubmitSignature: "sig",
            lastSubmitAt: now.addingTimeInterval(-(PitSync.maxSubmitGap + 1))
        )
        XCTAssertTrue(PitSync.submitDue(state, signature: "sig", now: now))
    }

    func testNoFlushBeforeMaxGap() {
        let state = PitSyncState(
            lastSubmitSignature: "sig",
            lastSubmitAt: now.addingTimeInterval(-(PitSync.maxSubmitGap - 60))
        )
        XCTAssertFalse(PitSync.submitDue(state, signature: "sig", now: now))
    }

    func testBackoffWindowGrowsAndCaps() {
        var state = PitSyncState()

        PitSync.recordFailure(&state, now: now)
        XCTAssertEqual(state.retryAfter, now.addingTimeInterval(PitSync.backoffBase))
        XCTAssertTrue(PitSync.inBackoff(state, now: now.addingTimeInterval(PitSync.backoffBase - 1)))
        XCTAssertFalse(PitSync.inBackoff(state, now: now.addingTimeInterval(PitSync.backoffBase)))

        PitSync.recordFailure(&state, now: now)
        XCTAssertEqual(state.retryAfter, now.addingTimeInterval(PitSync.backoffBase * 2))

        for _ in 0..<20 { PitSync.recordFailure(&state, now: now) }
        XCTAssertEqual(state.retryAfter, now.addingTimeInterval(PitSync.backoffCap))
    }

    func testSuccessClearsBackoffAndRecordsSubmit() {
        var state = PitSyncState()
        PitSync.recordFailure(&state, now: now)
        PitSync.recordSuccess(&state, submittedSignature: "sig", now: now)

        XCTAssertEqual(state.failureCount, 0)
        XCTAssertNil(state.retryAfter)
        XCTAssertFalse(PitSync.inBackoff(state, now: now))
        XCTAssertEqual(state.lastSubmitSignature, "sig")
        XCTAssertEqual(state.lastSubmitAt, now)
    }

    func testSuccessWithoutSubmitKeepsPriorSignature() {
        var state = PitSyncState(lastSubmitSignature: "sig", lastSubmitAt: now.addingTimeInterval(-100))
        PitSync.recordFailure(&state, now: now)
        PitSync.recordSuccess(&state, submittedSignature: nil, now: now)

        XCTAssertNil(state.retryAfter)
        XCTAssertEqual(state.lastSubmitSignature, "sig")
        XCTAssertEqual(state.lastSubmitAt, now.addingTimeInterval(-100))
    }
}
