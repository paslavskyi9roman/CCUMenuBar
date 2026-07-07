@testable import CCUMenuBar
import Foundation
import Testing

private func state(session: Double?, weekly: Double?, ageSeconds: TimeInterval,
                   resetsAtUnix: Int? = nil) -> State {
    let ts = State.iso8601.string(from: Date().addingTimeInterval(-ageSeconds))
    return State(
        session: Bucket(usedPct: session, resetsAtUnix: resetsAtUnix),
        weekly: Bucket(usedPct: weekly, resetsAtUnix: resetsAtUnix),
        source: "oauth", updatedAt: ts)
}

@Test func titleShowsLiveNumbersWhenFresh() {
    let m = TitleModel.make(producer: .ok, state: state(session: 42, weekly: 10, ageSeconds: 5))
    #expect(m.warn == false)
    #expect(m.sessionPct == 42)
    #expect(m.weeklyPct == 10)
    #expect(m.sessionDim == false)
    #expect(m.weeklyDim == false)
}

// The regression this whole change is about: stale data must keep showing the
// last-known percentage (dimmed, with ⚠), not collapse to "--%".
@Test func titleKeepsLastKnownNumbersWhenStale() {
    let m = TitleModel.make(producer: .ok, state: state(session: 0, weekly: 37, ageSeconds: 600))
    #expect(m.warn == true)
    #expect(m.sessionPct == 0)
    #expect(m.weeklyPct == 37)
    #expect(m.sessionDim == true)
    #expect(m.weeklyDim == true)
}

@Test func titleIsBlankWhenNeverSeen() {
    let m = TitleModel.make(producer: .neverSeen, state: nil)
    #expect(m.warn == false)
    #expect(m.sessionPct == nil)
    #expect(m.weeklyPct == nil)
}

@Test func titleHasNoValueWhenBucketPctMissing() {
    let m = TitleModel.make(producer: .ok, state: state(session: nil, weekly: nil, ageSeconds: 5))
    #expect(m.sessionPct == nil)
    #expect(m.weeklyPct == nil)
}
