import Combine
import Foundation

enum ProducerStatus: Equatable {
    case neverSeen
    case ok
}

@MainActor
final class StateStore {
    /// Fires *after* `state` is mutated (debounced 100ms). Deliberately not
    /// named `objectWillChange` / conforming to `ObservableObject` — that
    /// protocol's contract is to fire *before* the mutation, which this
    /// doesn't honor. Nothing binds `StateStore` via `@ObservedObject`; if that
    /// changes, the notification timing needs to move first.
    let stateDidChange = PassthroughSubject<Void, Never>()

    private(set) var state: State?
    private(set) var producerStatus: ProducerStatus = .neverSeen

    private var debounceItem: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.stateDirectory, withIntermediateDirectories: true)
        sweepOrphanedTempFiles()
    }

    /// The bridge writes via temp-file + `rename(2)`; if it's killed between
    /// those two steps (or a self-test scratch dir leaks), the temp file is
    /// left behind. Sweep on launch — age-gated so we never race a write that's
    /// genuinely in flight right now.
    private func sweepOrphanedTempFiles() {
        let dir = AppPaths.stateDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let minAge: TimeInterval = 300
        for url in entries {
            let name = url.lastPathComponent
            guard name.contains(".tmp.") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let age = values?.contentModificationDate.map { Date().timeIntervalSince($0) } ?? .infinity
            guard age > minAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func ingest(_ next: State) {
        if let current = state,
           let curDate = State.parseTimestamp(current.updatedAt),
           let nextDate = State.parseTimestamp(next.updatedAt),
           curDate > nextDate {
            return
        }
        var clamped = next
        clamped.session = next.session?.clamped()
        clamped.weekly = next.weekly?.clamped()
        state = clamped
        producerStatus = .ok
        scheduleNotify()
    }

    private func scheduleNotify() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stateDidChange.send()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }
}
