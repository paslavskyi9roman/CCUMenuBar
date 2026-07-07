@testable import CCUMenuBar
import Foundation
import Testing

@Test func parseRetryAfterReadsDeltaSeconds() {
    #expect(OAuthPoller.parseRetryAfter("120") == .seconds(120))
    #expect(OAuthPoller.parseRetryAfter("  90 ") == .seconds(90))
}

@Test func parseRetryAfterIgnoresJunkAndNonPositive() {
    #expect(OAuthPoller.parseRetryAfter(nil) == nil)
    #expect(OAuthPoller.parseRetryAfter("") == nil)
    #expect(OAuthPoller.parseRetryAfter("soon") == nil)
    #expect(OAuthPoller.parseRetryAfter("0") == nil)
    #expect(OAuthPoller.parseRetryAfter("-5") == nil)
}

@Test func parseRetryAfterClampsToSaneBounds() {
    // Below the poll cadence gets floored so we never retry faster than normal.
    #expect(OAuthPoller.parseRetryAfter("5") == .seconds(60))
    // A wild value can't wedge the poller for hours.
    #expect(OAuthPoller.parseRetryAfter("100000") == .seconds(3600))
}
