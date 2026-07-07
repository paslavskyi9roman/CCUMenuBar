@testable import CCUMenuBar
import Foundation
import Testing

@Test func paceOnTrackAtWindowMidpoint() throws {
    let now = Date()
    let window = Pace.Kind.session.windowSeconds
    let resetsAt = now.addingTimeInterval(window / 2)
    let bucket = Bucket(usedPct: 50, resetsAtUnix: Int(resetsAt.timeIntervalSince1970))

    let result = Pace.compute(bucket: bucket, kind: .session, now: now)

    let r = try #require(result)
    #expect(abs(r.deltaPct) < 0.01)
    #expect(r.etaSeconds != nil)
    #expect(!r.projectedToHitLimit)
}

@Test func paceReturnsNilForOverdueReset() {
    let now = Date()
    let bucket = Bucket(usedPct: 80, resetsAtUnix: Int(now.addingTimeInterval(-100).timeIntervalSince1970))

    #expect(Pace.compute(bucket: bucket, kind: .session, now: now) == nil)
}

@Test func paceReturnsNilImmediatelyAfterReset() {
    let now = Date()
    let window = Pace.Kind.session.windowSeconds
    // Only 30s elapsed since the window started — below the 60s noise floor.
    let bucket = Bucket(usedPct: 1, resetsAtUnix: Int(now.addingTimeInterval(window - 30).timeIntervalSince1970))

    #expect(Pace.compute(bucket: bucket, kind: .session, now: now) == nil)
}

@Test func paceProjectsBustWhenBurningFasterThanWindow() throws {
    let now = Date()
    let window = Pace.Kind.session.windowSeconds
    // Half the window elapsed but already at 90% used — way ahead of the
    // even-spending curve, so the projection should say "will hit 100% before reset."
    let resetsAt = now.addingTimeInterval(window / 2)
    let bucket = Bucket(usedPct: 90, resetsAtUnix: Int(resetsAt.timeIntervalSince1970))

    let result = Pace.compute(bucket: bucket, kind: .session, now: now)

    let r = try #require(result)
    #expect(r.deltaPct > 0)
    #expect(r.projectedToHitLimit)
}
