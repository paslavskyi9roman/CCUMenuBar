import Combine
import Darwin
import Dispatch
import Foundation

enum ProducerStatus: Equatable {
    case neverSeen
    case ok
    case authStale
    case offline(reason: String)
}

@MainActor
final class StateStore: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    private(set) var state: State?
    private(set) var producerStatus: ProducerStatus = .neverSeen
    var lastWrittenFingerprint: String?

    private var debounceItem: DispatchWorkItem?

    static let stateDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ClaudeCodeUsage", isDirectory: true)
    }()

    static let stateFile: URL = stateDirectory.appendingPathComponent("state.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
    }

    func ingest(_ next: State, fromWatcher: Bool) {
        if fromWatcher, let fp = lastWrittenFingerprint, fp == next.fingerprint() {
            return
        }
        if let current = state,
           let curDate = State.iso8601.date(from: current.updatedAt),
           let nextDate = State.iso8601.date(from: next.updatedAt),
           curDate > nextDate {
            return
        }
        state = next
        producerStatus = .ok
        scheduleNotify()
    }

    func markAuthStale() {
        guard producerStatus != .authStale else { return }
        producerStatus = .authStale
        scheduleNotify()
    }

    func markOffline(_ reason: String) {
        producerStatus = .offline(reason: reason)
        scheduleNotify()
    }

    func writeAndStore(_ next: State) {
        let fp = next.fingerprint()
        lastWrittenFingerprint = fp
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
        let dest = Self.stateFile
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".state.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp, options: .atomic)
            // `rename(2)` is atomic on the same volume and replaces an existing
            // destination — exactly the bash script's behavior. FileManager's
            // higher-level APIs are inconsistent across macOS versions.
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
            self?.objectWillChange.send()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }
}
