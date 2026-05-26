import AppKit
import Dispatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StateStore!
    private var settings: Settings!
    private var watcher: StateFileWatcher!
    private var poller: OAuthPoller!
    private var menuBar: MenuBarController!
    private var setupWindow: SetupWindowController!
    private var preferencesWindow: PreferencesWindowController!
    private var notifications: NotificationManager!
    private var signalSources: [DispatchSourceSignal] = []

    private static let didShowSetupKey = "ccu.didShowSetup"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Log.boot()

        store = StateStore()
        settings = Settings()
        menuBar = MenuBarController(store: store, settings: settings)
        watcher = StateFileWatcher(store: store)
        poller = OAuthPoller(store: store)
        setupWindow = SetupWindowController(store: store)
        preferencesWindow = PreferencesWindowController(settings: settings)
        notifications = NotificationManager(store: store, settings: settings)

        menuBar.onOpenSetup = { [weak self] in self?.setupWindow.show() }
        menuBar.onOpenPreferences = { [weak self] in self?.preferencesWindow.show() }
        menuBar.onRefresh = { [weak self] in
            guard let self else { return }
            self.watcher.refreshNow()
            if self.poller.canRefresh {
                self.poller.refreshNow()
            } else {
                Log.info("manual local reload requested; OAuth credentials unavailable")
            }
        }
        menuBar.canRefreshFromNetwork = { [weak self] in
            self?.poller.canRefresh ?? false
        }

        watcher.start()
        poller.start()
        notifications.start()

        installSignalHandlers()
        showSetupOnFirstRun()
    }

    /// On the first launch where the statusline bridge isn't installed yet,
    /// open Setup once. Producer B still works without it, so we don't nag.
    private func showSetupOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didShowSetupKey) else { return }
        defaults.set(true, forKey: Self.didShowSetupKey)
        if !BridgeInstaller.isScriptInstalled {
            setupWindow.show()
        }
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
