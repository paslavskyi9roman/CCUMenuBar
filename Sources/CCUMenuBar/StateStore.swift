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

enum OAuthRefreshStatus: Equatable {
    case idle(lastAttemptAt: Date?, lastSuccessAt: Date?, lastError: String?)
    case refreshing(startedAt: Date, lastSuccessAt: Date?, lastError: String?)

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }

    var lastSuccessAt: Date? {
        switch self {
        case .idle(_, let lastSuccessAt, _),
             .refreshing(_, let lastSuccessAt, _):
            return lastSuccessAt
        }
    }

    var lastError: String? {
        switch self {
        case .idle(_, _, let lastError),
             .refreshing(_, _, let lastError):
            return lastError
        }
    }
}

@MainActor
final class StateStore: @preconcurrency ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    private(set) var state: State?
    private(set) var producerStatus: ProducerStatus = .neverSeen
    private(set) var oauthRefreshStatus: OAuthRefreshStatus = .idle(
        lastAttemptAt: nil, lastSuccessAt: nil, lastError: nil)
    var lastWrittenFingerprint: String?

    private var debounceItem: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.stateDirectory, withIntermediateDirectories: true)
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

    func markOAuthRefreshStarted() {
        oauthRefreshStatus = .refreshing(
            startedAt: Date(),
            lastSuccessAt: oauthRefreshStatus.lastSuccessAt,
            lastError: oauthRefreshStatus.lastError)
        scheduleNotify()
    }

    func markOAuthRefreshSucceeded() {
        let now = Date()
        oauthRefreshStatus = .idle(lastAttemptAt: now, lastSuccessAt: now, lastError: nil)
        scheduleNotify()
    }

    func markOAuthRefreshFailed(_ reason: String) {
        oauthRefreshStatus = .idle(
            lastAttemptAt: Date(),
            lastSuccessAt: oauthRefreshStatus.lastSuccessAt,
            lastError: reason)
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
        let dest = AppPaths.stateFile
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
