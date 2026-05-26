import Combine
import Foundation

enum ProducerStatus: Equatable {
    case neverSeen
    case ok
}

@MainActor
final class StateStore: @preconcurrency ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    private(set) var state: State?
    private(set) var producerStatus: ProducerStatus = .neverSeen

    private var debounceItem: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.stateDirectory, withIntermediateDirectories: true)
    }

    func ingest(_ next: State) {
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

    private func scheduleNotify() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.objectWillChange.send()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }
}
