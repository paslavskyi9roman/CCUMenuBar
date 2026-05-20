import AppKit
import SwiftUI

/// Backs the Setup window. Recomputes step state from disk and from the live
/// `StateStore` so the window reflects reality as the user works through it.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var scriptInstalled = false
    @Published private(set) var settingsConfigured = false
    @Published private(set) var receivingData = false
    @Published private(set) var dataDetail = ""
    @Published var errorMessage: String?

    private let store: StateStore

    init(store: StateStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        scriptInstalled = BridgeInstaller.isScriptInstalled
        settingsConfigured = BridgeInstaller.isSettingsConfigured
        if let state = store.state, !state.isStale {
            receivingData = true
            let ago = state.updatedAtDate.map { Formatters.ago(since: $0) } ?? "just now"
            dataDetail = "Connected — source: \(state.source), updated \(ago)."
        } else {
            receivingData = false
            dataDetail = store.state == nil
                ? "No usage data yet. Restart Claude Code and run a command."
                : "Last data is stale. Restart Claude Code and run a command."
        }
    }

    func installScript() { run(BridgeInstaller.installScript) }
    func configureSettings() { run(BridgeInstaller.configureSettings) }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        refresh()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Claude Code Usage")
                .font(.title2).bold()
            Text("Two steps connect the menu bar to Claude Code's live usage data. "
                 + "The app also polls usage on its own every 60s, so it keeps "
                 + "working when Claude Code is closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stepRow(
                done: model.scriptInstalled,
                title: "Install the statusline bridge",
                detail: "Adds ccu-statusline-bridge.sh to ~/.claude/scripts.",
                button: model.scriptInstalled ? "Reinstall" : "Install",
                action: model.installScript)

            stepRow(
                done: model.settingsConfigured,
                title: "Connect it in settings.json",
                detail: "Sets the statusLine command. Any statusline you already "
                    + "had is preserved and kept running.",
                button: model.settingsConfigured ? "Reconfigure" : "Configure",
                action: model.configureSettings,
                enabled: model.scriptInstalled)

            stepRow(
                done: model.receivingData,
                title: "Restart Claude Code, then run a command",
                detail: model.dataDetail,
                button: nil,
                action: {})

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func stepRow(done: Bool, title: String, detail: String,
                         button: String?, action: @escaping () -> Void,
                         enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let button {
                Button(button, action: action)
                    .disabled(!enabled)
            }
        }
    }
}

/// Owns the Setup `NSWindow`. The app runs as an `.accessory` agent, so the
/// window has no Dock entry; we activate explicitly to bring it to the front.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let model: SetupModel
    private var window: NSWindow?
    private var refreshTimer: Timer?

    init(store: StateStore) {
        self.model = SetupModel(store: store)
        super.init()
    }

    func show() {
        model.refresh()
        if window == nil {
            let view = SetupView(model: model) { [weak self] in
                self?.window?.close()
            }
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.styleMask = [.titled, .closable]
            win.title = "Setup"
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            window = win
        }
        startTimer()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        // While the window is open, re-check disk/state so the steps stay live.
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 2.5, target: self, selector: #selector(tick),
            userInfo: nil, repeats: true)
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func tick() {
        model.refresh()
    }
}
