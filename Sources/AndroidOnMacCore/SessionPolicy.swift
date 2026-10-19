import Foundation

public enum SessionFailure: Equatable, Sendable {
    case connectionLost
    case unauthorized
    case deviceUnavailable
    case launchFailed
}

public enum SessionStopReason: Equatable, Sendable {
    case unauthorized
    case deviceUnavailable
    case launchFailed
    case retryLimitReached
}

public enum RetryDecision: Equatable, Sendable {
    case ignore
    case retry(after: TimeInterval, attempt: Int, generation: UInt64)
    case stop(reason: SessionStopReason)
}

/// One instance owns one user-requested session, including all reconnects.
/// Every retry changes the generation so late output/exit/timer callbacks from
/// an older process cannot restart or modify the current session.
public struct SessionPolicy: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var retryCount = 0
    public private(set) var isActive = false
    private let retryDelays: [TimeInterval]

    public init(retryDelays: [TimeInterval] = [1, 2, 4]) {
        self.retryDelays = retryDelays.map { $0.isFinite ? max(0, $0) : 0 }
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        retryCount = 0
        isActive = true
        return generation
    }

    public func accepts(generation: UInt64) -> Bool {
        isActive && generation == self.generation
    }

    /// Connecting successfully does not replenish the session's retry budget.
    public func markConnected(generation: UInt64) -> Bool { accepts(generation: generation) }

    public mutating func stop() {
        isActive = false
        generation &+= 1
    }

    @discardableResult
    public mutating func finish(generation: UInt64) -> Bool {
        guard accepts(generation: generation) else { return false }
        isActive = false
        return true
    }

    public mutating func failure(generation: UInt64, reason: SessionFailure) -> RetryDecision {
        guard accepts(generation: generation) else { return .ignore }
        if reason == .connectionLost, retryCount < retryDelays.count {
            let delay = retryDelays[retryCount]
            retryCount += 1
            self.generation &+= 1
            return .retry(after: delay, attempt: retryCount, generation: self.generation)
        }
        isActive = false
        switch reason {
        case .connectionLost: return .stop(reason: .retryLimitReached)
        case .unauthorized: return .stop(reason: .unauthorized)
        case .deviceUnavailable: return .stop(reason: .deviceUnavailable)
        case .launchFailed: return .stop(reason: .launchFailed)
        }
    }
}
