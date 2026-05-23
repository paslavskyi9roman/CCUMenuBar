import Foundation

/// "Pace" projection: how the current usage compares to what you'd expect at
/// this point in the reset window, assuming an even spending curve. Lets the
/// menu surface "you're burning faster than the window can absorb" without any
/// historical samples — everything is derivable from `usedPct`, `resetsAtUnix`,
/// and the (fixed, known) window length.
enum Pace {
    /// Which bucket — the window length differs and isn't part of `Bucket`'s
    /// on-disk schema, so it lives here.
    enum Kind {
        case session
        case weekly

        var windowSeconds: TimeInterval {
            switch self {
            case .session: return 5 * 3600        // 5h session window
            case .weekly: return 168 * 3600       // 7d weekly window
            }
        }
    }

    struct Result {
        /// `current − expected`. Negative means ahead of pace (safe); positive
        /// means burning faster than the window can absorb.
        let deltaPct: Double
        /// Projected seconds until `usedPct` hits 100, extrapolating the
        /// average rate so far in this window. `nil` when current is too low
        /// to extrapolate from (divide-by-near-zero).
        let etaSeconds: TimeInterval?
        /// True when the ETA lands before the reset — i.e. on current pace
        /// the user *will* run out before the window rolls over.
        let projectedToHitLimit: Bool
    }

    /// Returns `nil` when there's nothing meaningful to render:
    /// missing fields, too close to a reset, or an overdue reset (handled
    /// separately by the stale UI).
    static func compute(bucket: Bucket, kind: Kind, now: Date = Date()) -> Result? {
        guard let pct = bucket.usedPct, let resetsAt = bucket.resetsAtUnix else {
            return nil
        }
        let window = kind.windowSeconds
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let elapsed = window - resetDate.timeIntervalSince(now)
        if elapsed <= 60 { return nil }          // just after reset — too noisy
        if elapsed >= window { return nil }      // overdue — stale UI covers this

        let expected = (elapsed / window) * 100
        let delta = pct - expected

        let eta: TimeInterval?
        let willBust: Bool
        if pct < 1.0 {
            eta = nil
            willBust = false
        } else {
            let projected = (100 - pct) / pct * elapsed
            eta = projected
            willBust = (now.addingTimeInterval(projected)) < resetDate
        }
        return Result(deltaPct: delta, etaSeconds: eta, projectedToHitLimit: willBust)
    }
}
