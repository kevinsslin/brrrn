import Foundation

/// Mutable bookkeeping for how the menu bar app talks to the hub. Kept as a
/// plain value type so the decisions in `PitSync` can be unit tested without
/// the app, the engine, or the network.
public struct PitSyncState: Sendable, Equatable {
    /// Fingerprint of the last successfully pushed submit window.
    public var lastSubmitSignature: String?
    /// When that push happened, used to rate limit submits.
    public var lastSubmitAt: Date?
    /// Consecutive hub failures, driving the backoff window.
    public var failureCount: Int
    /// While `now` is before this, background sync stays off the hub.
    public var retryAfter: Date?

    public init(
        lastSubmitSignature: String? = nil,
        lastSubmitAt: Date? = nil,
        failureCount: Int = 0,
        retryAfter: Date? = nil
    ) {
        self.lastSubmitSignature = lastSubmitSignature
        self.lastSubmitAt = lastSubmitAt
        self.failureCount = failureCount
        self.retryAfter = retryAfter
    }
}

/// Decides when a background refresh should push a submit or stay quiet, and
/// spaces out retries after failures so a broken (or rate-limited) hub is not
/// hammered once a minute.
public enum PitSync {
    /// Push at most this often, even while usage keeps changing. A leaderboard
    /// tolerates a few minutes of lag, and this keeps writes well under the
    /// free-tier daily cap.
    public static let submitMinInterval: TimeInterval = 600
    /// First backoff step after a failure. Deliberately longer than the 60s
    /// refresh tick so one failure cannot become a per-minute retry loop.
    public static let backoffBase: TimeInterval = 120
    /// Backoff never grows past this.
    public static let backoffCap: TimeInterval = 1_800

    /// True while a failure backoff window is open. Forced (user-initiated)
    /// syncs ignore this; only the automatic loop honors it.
    public static func inBackoff(_ state: PitSyncState, now: Date) -> Bool {
        guard let retryAfter = state.retryAfter else { return false }
        return now < retryAfter
    }

    /// Whether a background submit should run: only when the push window
    /// actually changed and the minimum interval has elapsed.
    public static func submitDue(_ state: PitSyncState, signature: String?, now: Date) -> Bool {
        guard let signature else { return false }
        guard signature != state.lastSubmitSignature else { return false }
        if let last = state.lastSubmitAt, now.timeIntervalSince(last) < submitMinInterval {
            return false
        }
        return true
    }

    /// Record a clean hub round-trip: clears backoff and, if a submit went out,
    /// remembers its fingerprint and time.
    public static func recordSuccess(
        _ state: inout PitSyncState,
        submittedSignature: String?,
        now: Date
    ) {
        if let submittedSignature {
            state.lastSubmitSignature = submittedSignature
            state.lastSubmitAt = now
        }
        state.failureCount = 0
        state.retryAfter = nil
    }

    /// Record a hub failure and widen the backoff window (exponential, capped).
    public static func recordFailure(_ state: inout PitSyncState, now: Date) {
        state.failureCount += 1
        let step = backoffBase * pow(2, Double(state.failureCount - 1))
        state.retryAfter = now.addingTimeInterval(min(step, backoffCap))
    }
}
