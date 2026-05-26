import Darwin
import Dispatch
import Foundation

/// Watches the shared state file. The bash bridge writes via `mv -f`, which
/// atomically replaces the inode; that invalidates the file descriptor we'd
/// opened for kqueue. So we re-arm on every `.delete | .rename` event, and we
/// watch the parent directory as a fallback for the cold-start case where the
/// file doesn't exist yet.
final class StateFileWatcher {
    private let store: StateStore
    private let queue = DispatchQueue(label: "ccu.statefile.watcher")

    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var dirFD: Int32 = -1
    private var stopped = false

    init(store: StateStore) {
        self.store = store
    }

    func start() {
        queue.async { [weak self] in
            self?.armDirWatch()
            self?.armFileWatch()
            self?.readNow()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.cancelFile()
            self.cancelDir()
        }
    }

    func refreshNow() {
        queue.async { [weak self] in
            self?.readNow()
        }
    }

    private func armDirWatch() {
        cancelDir()
        let dir = AppPaths.stateDirectory.path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            Log.warn("could not open state dir for watch: \(dir)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.armFileWatch()
            self?.readNow()
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        dirFD = fd
        dirSource = src
    }

    private func armFileWatch() {
        guard !stopped else { return }
        cancelFile()
        let path = AppPaths.stateFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let evt = src.data
            if evt.contains(.delete) || evt.contains(.rename) {
                self.armFileWatch()
            }
            self.readNow()
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        fileFD = fd
        fileSource = src
    }

    private func cancelFile() {
        fileSource?.cancel()
        fileSource = nil
        fileFD = -1
    }

    private func cancelDir() {
        dirSource?.cancel()
        dirSource = nil
        dirFD = -1
    }

    private func readNow() {
        let url = AppPaths.stateFile
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        guard let state = try? decoder.decode(State.self, from: data) else {
            Log.warn("could not decode state.json")
            return
        }
        Task { @MainActor [weak store] in
            store?.ingest(state)
        }
    }
}
