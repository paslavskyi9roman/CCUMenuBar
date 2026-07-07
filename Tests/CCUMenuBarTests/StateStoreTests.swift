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

    store.ingest(state)

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

    store.ingest(newer)
    store.ingest(older)

    #expect(store.state?.session?.usedPct == 10)
}

@Test @MainActor func ingestAcceptsFractionalSecondTimestamps() {
    let store = StateStore()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let state = State(
        session: nil, weekly: nil, source: "statusline",
        updatedAt: formatter.string(from: Date()))

    store.ingest(state)

    #expect(store.state?.isStale == false)
}
