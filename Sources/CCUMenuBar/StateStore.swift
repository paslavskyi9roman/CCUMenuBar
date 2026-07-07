import Combine
import Darwin
import Dispatch
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

    /// Set by `writeAndStore`, checked by `ingest(fromWatcher:)` to drop the
    /// kqueue echo of our own write.
    var lastWrittenFingerprint: String?

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

    func ingest(_ next: State, fromWatcher: Bool) {
        if fromWatcher, let fp = lastWrittenFingerprint, fp == next.fingerprint() {
            return
        }
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

    /// Write `state.json` and mirror it in `state`. Routing through disk
    /// keeps the bridge, the `ccu` CLI, and the in-app view consistent.
    func writeAndStore(_ next: State) {
        lastWrittenFingerprint = next.fingerprint()
        atomicWrite(next)
        ingest(next, fromWatcher: false)
    }

    private func atomicWrite(_ value: State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            Log.warn("encode failed for state write")
            return
        }
        let dest = AppPaths.stateFile
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".state.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp, options: .atomic)
            // `rename(2)` atomically replaces the destination on the same
            // volume — same pattern the bash bridge uses.
            if rename(tmp.path, dest.path) != 0 {
                let err = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: tmp)
                Log.warn("atomic write rename failed: \(err)")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.warn("atomic write failed: \(error)")
        }
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
