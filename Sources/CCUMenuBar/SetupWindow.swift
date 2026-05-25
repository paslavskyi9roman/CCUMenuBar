import AppKit
import SwiftUI

/// Backs the Setup window. Recomputes step state from disk and from the live
/// `StateStore` so the window reflects reality as the user works through it.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var scriptInstalled = false
    @Published private(set) var settingsConfigured = false
    @Published private(set) var jqAvailable = false
    @Published private(set) var jqDetail = ""
    @Published private(set) var receivingData = false
    @Published private(set) var dataDetail = ""
    @Published private(set) var diagnosticsCopied = false
    @Published var errorMessage: String?

    private let store: StateStore

    init(store: StateStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        scriptInstalled = BridgeInstaller.isScriptInstalled
        settingsConfigured = BridgeInstaller.isSettingsConfigured
        jqAvailable = BridgeInstaller.isJQAvailable
        jqDetail = BridgeInstaller.jqPath.map {
            "Found jq at \($0)."
        } ?? "jq is missing. Install it with `brew install jq` so the statusline bridge can parse usage JSON."
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

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsText(), forType: .string)
        diagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.diagnosticsCopied = false
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        refresh()
    }

    private func diagnosticsText() -> String {
        let state = store.state
        let session = state?.session?.usedPct.map { "\(Int($0.rounded()))%" } ?? "--"
        let weekly = state?.weekly?.usedPct.map { "\(Int($0.rounded()))%" } ?? "--"
        let age = state?.updatedAtDate.map { Formatters.ago(since: $0) } ?? "never"
        let stateExists = FileManager.default.fileExists(atPath: AppPaths.stateFile.path)
        let credentialsExist = FileManager.default.fileExists(atPath: AppPaths.claudeCredentialsFile.path)

        return """
        Claude Code Usage diagnostics
        generated_at: \(State.nowISO())
        bundle_id: \(Bundle.main.bundleIdentifier ?? "none")

        setup:
          script_installed: \(scriptInstalled) (\(BridgeInstaller.installedScript.path))
          settings_configured: \(settingsConfigured) (\(BridgeInstaller.settingsFile.path))
          jq: \(BridgeInstaller.jqPath ?? "missing")
          credentials_file_exists: \(credentialsExist) (\(AppPaths.claudeCredentialsFile.path))

        state:
          file_exists: \(stateExists) (\(AppPaths.stateFile.path))
          producer_status: \(producerStatusText())
          source: \(state?.source ?? "none")
          updated: \(state?.updatedAt ?? "never") (\(age))
          stale: \(state?.isStale.description ?? "n/a")
          session: \(session)
          weekly: \(weekly)

        oauth:
          refresh: \(oauthRefreshText())

        recent_app_log:
        \(tail(AppPaths.appLogFile))

        recent_bridge_log:
        \(tail(AppPaths.bridgeLogFile))
        """
    }

    private func producerStatusText() -> String {
        switch store.producerStatus {
        case .neverSeen: return "neverSeen"
        case .ok: return "ok"
        case .authStale: return "authStale"
        case .offline(let reason): return "offline(\(reason))"
        }
    }

    private func oauthRefreshText() -> String {
        switch store.oauthRefreshStatus {
        case .idle(let lastAttemptAt, let lastSuccessAt, let lastError):
            return "idle(lastAttempt=\(dateText(lastAttemptAt)), lastSuccess=\(dateText(lastSuccessAt)), lastError=\(lastError ?? "none"))"
        case .refreshing(let startedAt, let lastSuccessAt, let lastError):
            return "refreshing(started=\(dateText(startedAt)), lastSuccess=\(dateText(lastSuccessAt)), lastError=\(lastError ?? "none"))"
        }
    }

    private func dateText(_ date: Date?) -> String {
        date.map { State.iso8601.string(from: $0) } ?? "never"
    }

    private func tail(_ url: URL, maxLines: Int = 20) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return "  <not found>"
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Claude Code Usage")
                .font(.title2).bold()
            Text("Connect the menu bar to Claude Code's live usage data. "
                 + "The optional background poller uses existing Claude Code credentials "
                 + "when they are available.")
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
                done: model.jqAvailable,
                title: "Verify jq dependency",
                detail: model.jqDetail,
                button: nil,
                action: {})

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
                Button("Copy Diagnostics", action: model.copyDiagnostics)
                if model.diagnosticsCopied {
                    Text("Copied")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
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
