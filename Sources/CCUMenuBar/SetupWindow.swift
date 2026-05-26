import AppKit
import SwiftUI

/// Backs the Setup window. Recomputes step state from disk and from the live
/// `StateStore` so the window reflects reality as the user works through it.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var scriptInstalled = false
    @Published private(set) var scriptOutOfDate = false
    @Published private(set) var settingsConfigured = false
    @Published private(set) var jqAvailable = false
    @Published private(set) var jqDetail = ""
    @Published private(set) var receivingData = false
    @Published private(set) var dataDetail = ""
    @Published private(set) var diagnosticsCopied = false
    @Published private(set) var selfTestResult: SelfTestResult?
    @Published private(set) var selfTestRunning = false
    @Published var errorMessage: String?

    private let store: StateStore

    init(store: StateStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        scriptInstalled = BridgeInstaller.isScriptInstalled
        scriptOutOfDate = BridgeInstaller.installedScriptIsOutOfDate
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
            dataDetail = dataDetailMessage()
        }
    }

    private func dataDetailMessage() -> String {
        if let bridge = BridgeStatus.read(), bridge.isActive {
            let ago = bridge.lastSeenDate.map { Formatters.ago(since: $0) } ?? "just now"
            if bridge.rateLimitsPresent {
                return "Bridge active (last call \(ago)) but state.json hasn't been ingested yet."
            }
            return "Bridge active (last call \(ago)). Claude Code is calling it, but no rate_limits in the payload yet — run a command that uses the API."
        }
        if store.state == nil {
            return "No usage data yet. Restart Claude Code and run a command."
        }
        return "Last data is stale. Restart Claude Code and run a command."
    }

    func installScript() { run(BridgeInstaller.installScript) }
    func configureSettings() { run(BridgeInstaller.configureSettings) }

    func runSelfTest() {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        selfTestResult = nil
        // Run on a background queue so the spawned bash doesn't block the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BridgeInstaller.runSelfTest()
            DispatchQueue.main.async { [weak self] in
                self?.selfTestRunning = false
                self?.selfTestResult = result
                self?.refresh()
            }
        }
    }

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
        let bridgeLogExists = FileManager.default.fileExists(atPath: AppPaths.bridgeLogFile.path)

        return """
        Claude Code Usage diagnostics
        generated_at: \(State.nowISO())
        bundle_id: \(Bundle.main.bundleIdentifier ?? "none")

        setup:
          script_installed: \(scriptInstalled) (\(BridgeInstaller.installedScript.path))
          script_out_of_date: \(scriptOutOfDate)
          settings_configured: \(settingsConfigured) (\(BridgeInstaller.settingsFile.path))
          jq: \(BridgeInstaller.jqPath ?? "missing")
          self_test: \(selfTestResult.map { $0.summary } ?? "not run")

        bridge_heartbeat: \(bridgeHeartbeatText())

        state:
          file_exists: \(stateExists) (\(AppPaths.stateFile.path))
          producer_status: \(producerStatusText())
          source: \(state?.source ?? "none")
          updated: \(state?.updatedAt ?? "never") (\(age))
          stale: \(state?.isStale.description ?? "n/a")
          session: \(session)
          weekly: \(weekly)

        bridge_log_exists: \(bridgeLogExists) (\(AppPaths.bridgeLogFile.path))
        recent_bridge_log:
        \(tail(AppPaths.bridgeLogFile))

        recent_app_log:
        \(tail(AppPaths.appLogFile))
        """
    }

    private func producerStatusText() -> String {
        switch store.producerStatus {
        case .neverSeen: return "neverSeen"
        case .ok: return "ok"
        }
    }

    private func bridgeHeartbeatText() -> String {
        guard let bridge = BridgeStatus.read() else { return "<no bridge-status.json>" }
        let ago = bridge.lastSeenDate.map { Formatters.ago(since: $0) } ?? "unknown"
        return "last_seen=\(bridge.bridgeLastSeenAt) (\(ago)) "
            + "active=\(bridge.isActive) "
            + "rate_limits_present=\(bridge.rateLimitsPresent) "
            + "jq_path=\(bridge.jqPath ?? "<null>")"
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

    private var selfTestDetail: String {
        if let result = model.selfTestResult {
            return result.summary
        }
        return "Pipes a canary payload through the bridge and checks state.json. "
            + "Catches PATH problems, jq issues, and broken permissions before they look like ‘nothing happens’."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Claude Code Usage")
                .font(.title2).bold()
            Text("Connect the menu bar to Claude Code's live usage data. "
                 + "Usage numbers come from Claude Code's own statusline — "
                 + "the bridge writes them to disk and this app renders them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stepRow(
                done: model.scriptInstalled && !model.scriptOutOfDate,
                title: "Install the statusline bridge",
                detail: model.scriptOutOfDate
                    ? "An updated bridge ships with this app. Reinstall to pick it up."
                    : "Adds ccu-statusline-bridge.sh to ~/.claude/scripts.",
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
                done: model.selfTestResult?.passed ?? false,
                title: "Run bridge self-test",
                detail: selfTestDetail,
                button: model.selfTestRunning ? "Testing…" : "Run test",
                action: model.runSelfTest,
                enabled: !model.selfTestRunning
                    && model.scriptInstalled
                    && model.jqAvailable)

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
