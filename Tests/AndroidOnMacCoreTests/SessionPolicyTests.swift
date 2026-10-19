import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite
struct SessionPolicyTests {
    @Test
    func testFiniteBackoffBudgetIsNotResetBySuccessfulReconnects() {
        var policy = SessionPolicy()
        var generation = policy.begin()
        for (index, delay) in [1.0, 2.0, 4.0].enumerated() {
            #expect(policy.markConnected(generation: generation))
            let previous = generation
            let decision = policy.failure(generation: generation, reason: .connectionLost)
            generation = policy.generation
            #expect(decision == .retry(after: delay, attempt: index + 1, generation: generation))
            #expect(generation != previous)
            #expect(!(policy.accepts(generation: previous)))
        }
        let exhausted = policy.failure(generation: generation, reason: .connectionLost)
        #expect(exhausted == .stop(reason: .retryLimitReached))
        #expect(!(policy.isActive))
        #expect(policy.retryCount == 3)
        let afterExhaustion = policy.failure(generation: generation, reason: .connectionLost)
        #expect(afterExhaustion == .ignore)
    }

    @Test
    func testAuthorizationAndPermanentFailuresDoNotRetry() {
        let cases: [(SessionFailure, SessionStopReason)] = [
            (.unauthorized, .unauthorized), (.deviceUnavailable, .deviceUnavailable), (.launchFailed, .launchFailed)
        ]
        for (failure, stop) in cases {
            var policy = SessionPolicy()
            let generation = policy.begin()
            let decision = policy.failure(generation: generation, reason: failure)
            #expect(decision == .stop(reason: stop))
            #expect(policy.retryCount == 0)
            #expect(!(policy.isActive))
        }
    }

    @Test
    func testManualStopInvalidatesPendingRetryAndExitCallbacks() {
        var policy = SessionPolicy()
        let initial = policy.begin()
        _ = policy.failure(generation: initial, reason: .connectionLost)
        let pending = policy.generation
        policy.stop()
        #expect(!(policy.accepts(generation: pending)))
        #expect(!(policy.markConnected(generation: pending)))
        let afterStop = policy.failure(generation: pending, reason: .connectionLost)
        #expect(afterStop == .ignore)
        let finished = policy.finish(generation: pending)
        #expect(!finished)
    }

    @Test
    func testNewSessionIgnoresPreviousGenerationAndRestoresBudget() {
        var policy = SessionPolicy(retryDelays: [1])
        let old = policy.begin()
        _ = policy.failure(generation: old, reason: .connectionLost)
        let next = policy.begin()
        #expect(policy.retryCount == 0)
        let staleFailure = policy.failure(generation: old, reason: .unauthorized)
        #expect(staleFailure == .ignore)
        #expect(policy.isActive)
        #expect(policy.markConnected(generation: next))
        let finished = policy.finish(generation: next)
        #expect(finished)
        let afterFinish = policy.failure(generation: next, reason: .connectionLost)
        #expect(afterFinish == .ignore)
    }

    @Test
    func testNoRetriesAndInvalidDelayInputs() {
        var immediate = SessionPolicy(retryDelays: [])
        let first = immediate.begin()
        let immediateDecision = immediate.failure(generation: first, reason: .connectionLost)
        #expect(immediateDecision == .stop(reason: .retryLimitReached))
        var clamped = SessionPolicy(retryDelays: [-1, .infinity, .nan])
        _ = clamped.begin()
        for attempt in 1...3 {
            let previous = clamped.generation
            let decision = clamped.failure(generation: previous, reason: .connectionLost)
            #expect(decision == .retry(after: 0, attempt: attempt, generation: previous + 1))
        }
    }
}
