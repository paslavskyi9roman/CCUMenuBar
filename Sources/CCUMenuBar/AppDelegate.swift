import AppKit
import Dispatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StateStore!
    private var watcher: StateFileWatcher!
    private var poller: OAuthPoller!
    private var menuBar: MenuBarController!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Log.boot()

        store = StateStore()
        menuBar = MenuBarController(store: store)
        watcher = StateFileWatcher(store: store)
        poller = OAuthPoller(store: store)

        watcher.start()
        poller.start()

        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        watcher?.stop()
        Log.flush()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
