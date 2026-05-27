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
    private var watchdog: BridgeWatchdog!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Log.boot()
        logBootDiagnostics()

        store = StateStore()
        settings = Settings()
        menuBar = MenuBarController(store: store, settings: settings)
        watcher = StateFileWatcher(store: store)
        setupWindow = SetupWindowController(store: store)
        preferencesWindow = PreferencesWindowController(settings: settings)
        notifications = NotificationManager(store: store, settings: settings)
        watchdog = BridgeWatchdog(settings: settings)

        menuBar.onOpenSetup = { [weak self] in self?.setupWindow.show() }
        menuBar.onOpenPreferences = { [weak self] in self?.preferencesWindow.show() }
        menuBar.onRefresh = { [weak self] in
            self?.watcher.refreshNow()
        }

        watcher.start()
        notifications.start()
        watchdog.start()

        installSignalHandlers()
        showSetupOnFirstRun()
    }

    /// Snapshot of bridge install state, heartbeat, and on-disk state.json,
    /// written to `ccu.log` so remote testers can hand us just the app log and
    /// we can triage without needing them to open Setup → Copy Diagnostics.
    private func logBootDiagnostics() {
        let script = BridgeInstaller.isScriptInstalled
        let scriptOutOfDate = script && BridgeInstaller.installedScriptIsOutOfDate
        let settings = BridgeInstaller.isSettingsConfigured
        let jq = BridgeInstaller.jqPath ?? "missing"
        Log.info("bridge setup: script=\(script) script_out_of_date=\(scriptOutOfDate) settings=\(settings) jq=\(jq)")

        if let bridge = BridgeStatus.read() {
            let age = bridge.ageSeconds.map { "\(Int($0))s" } ?? "unknown"
            Log.info("bridge heartbeat: present=true last_seen=\(bridge.bridgeLastSeenAt) age=\(age) active=\(bridge.isActive) rate_limits_present=\(bridge.rateLimitsPresent) jq=\(bridge.jqPath ?? "null")")
        } else {
            Log.info("bridge heartbeat: present=false")
        }

        let stateFile = AppPaths.stateFile
        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            Log.info("state: file=false")
            return
        }
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            Log.info("state: file=true unreadable")
            return
        }
        let age = state.ageSeconds.map { "\(Int($0))s" } ?? "unknown"
        let session = state.session?.usedPct.map { String(format: "%.1f%%", $0) } ?? "nil"
        let weekly = state.weekly?.usedPct.map { String(format: "%.1f%%", $0) } ?? "nil"
        Log.info("state: file=true source=\(state.source) updated=\(state.updatedAt) age=\(age) stale=\(state.isStale) session=\(session) weekly=\(weekly)")
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
        watchdog?.stop()
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
