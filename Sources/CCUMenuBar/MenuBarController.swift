import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: StateStore
    private let settings: Settings
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    /// Invoked when the user picks "Setup…". Wired up by `AppDelegate`.
    var onOpenSetup: (() -> Void)?

    /// Invoked when the user picks "Refresh now".
    var onRefresh: (() -> Void)?

    /// Invoked when the user picks "Preferences…".
    var onOpenPreferences: (() -> Void)?

    // Monospaced digits so the title doesn't jitter as percentages change width.
    private static let titleFont: NSFont = {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    init(store: StateStore, settings: Settings) {
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Persist the item's menu-bar position across launches, so a manual
        // placement (e.g. dragged out from behind the notch) sticks.
        statusItem.autosaveName = "ccu-menubar-status-item"
        statusItem.menu = menu
        menu.delegate = self
        bind()
        updateTitle()
    }

    private func bind() {
        // Re-render the title when usage changes, and when the thresholds
        // change in Preferences — so the color updates without a poll.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
    }

    private func updateTitle() {
        statusItem.button?.attributedTitle = renderTitle()
    }

    // MARK: - Title

    // Compact form (`S42% │ W67%`) — a narrow status item is far less likely to
    // be swallowed by the notch on a crowded menu bar. Each percentage is tinted
    // by how close it is to the limit so it reads at a glance without a click.
    private func renderTitle() -> NSAttributedString {
        let session = store.state?.session?.usedPct
        let weekly = store.state?.weekly?.usedPct
        switch store.producerStatus {
        case .neverSeen:
            return composeTitle(warn: false, session: nil, weekly: nil, dimmed: true)
        case .ok:
            return composeTitle(warn: store.state?.isStale ?? true,
                                session: session, weekly: weekly, dimmed: false)
        case .authStale, .offline:
            return composeTitle(warn: true, session: session, weekly: weekly, dimmed: false)
        }
    }

    private func composeTitle(warn: Bool, session: Double?, weekly: Double?, dimmed: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let structural: NSColor = dimmed ? .secondaryLabelColor : .labelColor
        if warn {
            result.append(segment("⚠ ", color: .systemOrange))
        }
        result.append(segment("S", color: structural))
        result.append(segment(percentText(session),
                               color: dimmed ? .secondaryLabelColor : color(forPct: session)))
        result.append(segment(" │ ", color: structural))
        result.append(segment("W", color: structural))
        result.append(segment(percentText(weekly),
                               color: dimmed ? .secondaryLabelColor : color(forPct: weekly)))
        return result
    }

    private func segment(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: Self.titleFont,
        ])
    }

    private func percentText(_ pct: Double?) -> String {
        guard let pct else { return "--%" }
        return "\(Int(pct.rounded()))%"
    }

    private func color(forPct pct: Double?) -> NSColor {
        guard let pct else { return .labelColor }
        if pct >= settings.criticalThreshold { return .systemRed }
        if pct >= settings.warnThreshold { return .systemOrange }
        return .labelColor
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = store.state
        menu.addItem(rowFor(label: "Session", bucket: state?.session))
        menu.addItem(rowFor(label: "Weekly", bucket: state?.weekly))
        menu.addItem(.separator())
        menu.addItem(statusRow())
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Refresh now", selector: #selector(refreshNow)))
        menu.addItem(actionItem(title: "Reveal logs in Finder", selector: #selector(revealLogs)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Setup…", selector: #selector(openSetup)))
        menu.addItem(actionItem(title: "Preferences…", selector: #selector(openPreferences),
                                keyEquivalent: ","))
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit", selector: #selector(quit), keyEquivalent: "q"))
    }

    private func actionItem(title: String, selector: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func rowFor(label: String, bucket: Bucket?) -> NSMenuItem {
        let pct = bucket?.usedPct.map { "\(Int($0.rounded()))%" } ?? "--%"
        let resets: String
        if let unix = bucket?.resetsAtUnix {
            resets = Formatters.resetInOrAt(unix: unix)
        } else {
            resets = "unknown reset"
        }
        let title = "\(label)   \(pct)   \(resets)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func statusRow() -> NSMenuItem {
        let title: String
        switch store.producerStatus {
        case .neverSeen:
            title = "No data yet — run a Claude Code command."
        case .ok:
            let src = store.state?.source ?? "unknown"
            let ago = store.state?.updatedAtDate.map { Formatters.ago(since: $0) } ?? "—"
            let stale = (store.state?.isStale ?? false) ? "  (stale)" : ""
            title = "Source: \(src) · updated \(ago)\(stale)"
        case .authStale:
            title = "Auth expired — re-run `claude` to refresh."
        case .offline(let reason):
            title = "Offline: \(reason)"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openSetup() {
        onOpenSetup?()
    }

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func refreshNow() {
        onRefresh?()
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        let enabled = LaunchAtLogin.isEnabled
        item.state = enabled ? .on : .off
        if LaunchAtLogin.requiresApproval {
            item.toolTip = "Approve in System Settings → General → Login Items."
        }
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
