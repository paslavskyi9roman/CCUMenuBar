@testable import CCUMenuBar
import Foundation
import Testing

@Test @MainActor func ingestClampsOutOfRangePercentages() {
    let store = StateStore()
    let state = State(
        session: Bucket(usedPct: 150, resetsAtUnix: 1_700_000_000),
        weekly: Bucket(usedPct: -20, resetsAtUnix: 1_700_000_000),
        source: "statusline",
        updatedAt: State.nowISO())

    store.ingest(state, fromWatcher: false)

    #expect(store.state?.session?.usedPct == 100)
    #expect(store.state?.weekly?.usedPct == 0)
}

@Test @MainActor func ingestIsLastWriteWinsByUpdatedAt() {
    let store = StateStore()
    let now = Date()
    let newer = State(
        session: Bucket(usedPct: 10, resetsAtUnix: nil), weekly: nil,
        source: "statusline", updatedAt: State.iso8601.string(from: now))
    let older = State(
        session: Bucket(usedPct: 99, resetsAtUnix: nil), weekly: nil,
        source: "statusline", updatedAt: State.iso8601.string(from: now.addingTimeInterval(-60)))

    store.ingest(newer, fromWatcher: false)
    store.ingest(older, fromWatcher: false)

    #expect(store.state?.session?.usedPct == 10)
}

@Test @MainActor func ingestAcceptsFractionalSecondTimestamps() {
    let store = StateStore()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let state = State(
        session: nil, weekly: nil, source: "statusline",
        updatedAt: formatter.string(from: Date()))

    store.ingest(state, fromWatcher: false)

    #expect(store.state?.isStale == false)
}

@Test @MainActor func ingestSkipsWatcherEchoOfOwnWrite() {
    let store = StateStore()
    let base = State(
        session: Bucket(usedPct: 10, resetsAtUnix: nil), weekly: nil,
        source: "oauth", updatedAt: State.iso8601.string(from: Date()))
    store.ingest(base, fromWatcher: false)

    // Simulate having just written `echo` ourselves: the kqueue re-read of the
    // identical file must be dropped even though it is newer, or the poller's
    // own writes would re-enter through the watcher on every tick.
    let echo = State(
        session: Bucket(usedPct: 42, resetsAtUnix: nil), weekly: nil,
        source: "oauth",
        updatedAt: State.iso8601.string(from: Date().addingTimeInterval(60)))
    store.lastWrittenFingerprint = echo.fingerprint()
    store.ingest(echo, fromWatcher: true)
    #expect(store.state?.session?.usedPct == 10)

    // A genuinely different watcher event (not our write) still applies.
    let external = State(
        session: Bucket(usedPct: 55, resetsAtUnix: nil), weekly: nil,
        source: "statusline",
        updatedAt: State.iso8601.string(from: Date().addingTimeInterval(120)))
    store.ingest(external, fromWatcher: true)
    #expect(store.state?.session?.usedPct == 55)
}
