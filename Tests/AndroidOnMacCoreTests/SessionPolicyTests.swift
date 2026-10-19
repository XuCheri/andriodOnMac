import XCTest
@testable import AndroidOnMacCore

final class SessionPolicyTests: XCTestCase {
    func testFiniteBackoffBudgetIsNotResetBySuccessfulReconnects() {
        var policy = SessionPolicy()
        var generation = policy.begin()
        for (index, delay) in [1.0, 2.0, 4.0].enumerated() {
            XCTAssertTrue(policy.markConnected(generation: generation))
            let previous = generation
            let decision = policy.failure(generation: generation, reason: .connectionLost)
            generation = policy.generation
            XCTAssertEqual(decision, .retry(after: delay, attempt: index + 1, generation: generation))
            XCTAssertNotEqual(generation, previous)
            XCTAssertFalse(policy.accepts(generation: previous))
        }
        XCTAssertEqual(policy.failure(generation: generation, reason: .connectionLost), .stop(reason: .retryLimitReached))
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.retryCount, 3)
        XCTAssertEqual(policy.failure(generation: generation, reason: .connectionLost), .ignore)
    }

    func testAuthorizationAndPermanentFailuresDoNotRetry() {
        let cases: [(SessionFailure, SessionStopReason)] = [
            (.unauthorized, .unauthorized), (.deviceUnavailable, .deviceUnavailable), (.launchFailed, .launchFailed)
        ]
        for (failure, stop) in cases {
            var policy = SessionPolicy()
            let generation = policy.begin()
            XCTAssertEqual(policy.failure(generation: generation, reason: failure), .stop(reason: stop))
            XCTAssertEqual(policy.retryCount, 0)
            XCTAssertFalse(policy.isActive)
        }
    }

    func testManualStopInvalidatesPendingRetryAndExitCallbacks() {
        var policy = SessionPolicy()
        let initial = policy.begin()
        _ = policy.failure(generation: initial, reason: .connectionLost)
        let pending = policy.generation
        policy.stop()
        XCTAssertFalse(policy.accepts(generation: pending))
        XCTAssertFalse(policy.markConnected(generation: pending))
        XCTAssertEqual(policy.failure(generation: pending, reason: .connectionLost), .ignore)
        XCTAssertFalse(policy.finish(generation: pending))
    }

    func testNewSessionIgnoresPreviousGenerationAndRestoresBudget() {
        var policy = SessionPolicy(retryDelays: [1])
        let old = policy.begin()
        _ = policy.failure(generation: old, reason: .connectionLost)
        let next = policy.begin()
        XCTAssertEqual(policy.retryCount, 0)
        XCTAssertEqual(policy.failure(generation: old, reason: .unauthorized), .ignore)
        XCTAssertTrue(policy.isActive)
        XCTAssertTrue(policy.markConnected(generation: next))
        XCTAssertTrue(policy.finish(generation: next))
        XCTAssertEqual(policy.failure(generation: next, reason: .connectionLost), .ignore)
    }

    func testNoRetriesAndInvalidDelayInputs() {
        var immediate = SessionPolicy(retryDelays: [])
        let first = immediate.begin()
        XCTAssertEqual(immediate.failure(generation: first, reason: .connectionLost), .stop(reason: .retryLimitReached))
        var clamped = SessionPolicy(retryDelays: [-1, .infinity, .nan])
        _ = clamped.begin()
        for attempt in 1...3 {
            let previous = clamped.generation
            XCTAssertEqual(clamped.failure(generation: previous, reason: .connectionLost),
                           .retry(after: 0, attempt: attempt, generation: previous + 1))
        }
    }
}
