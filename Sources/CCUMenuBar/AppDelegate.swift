import AppKit
import Dispatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StateStore!
    private var settings: Settings!
    private var watcher: StateFileWatcher!
    private var menuBar: MenuBarController!
    private var setupWindow: SetupWindowController!
    private var preferencesWindow: PreferencesWindowController!
    private var notifications: NotificationManager!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Log.boot()

        store = StateStore()
        settings = Settings()
        menuBar = MenuBarController(store: store, settings: settings)
        watcher = StateFileWatcher(store: store)
        setupWindow = SetupWindowController(store: store)
        preferencesWindow = PreferencesWindowController(settings: settings)
        notifications = NotificationManager(store: store, settings: settings)

        menuBar.onOpenSetup = { [weak self] in self?.setupWindow.show() }
        menuBar.onOpenPreferences = { [weak self] in self?.preferencesWindow.show() }
        menuBar.onRefresh = { [weak self] in
            self?.watcher.refreshNow()
        }

        watcher.start()
        notifications.start()

        installSignalHandlers()
        showSetupOnFirstRun()
    }

    /// Auto-open Setup whenever the bridge isn't installed. The bridge is the
    /// app's only data source, so without it there's nothing to display — and
    /// previously this used a "show only once" latch that left fresh users
    /// stranded if they closed the window before finishing.
    private func showSetupOnFirstRun() {
        if !BridgeInstaller.isScriptInstalled {
            setupWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        Log.flush()
    }

    /// Called when the user double-clicks the .app or runs `open` on it while
    /// we're already running. We have no Dock icon, so without this the user
    /// has no obvious way to get back to Setup other than the menu bar item —
    /// which may be hidden behind the notch on small / crowded screens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        setupWindow.show()
        return true
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
