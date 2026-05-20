import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: StateStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(store: StateStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Persist the item's menu-bar position across launches, so a manual
        // placement (e.g. dragged out from behind the notch) sticks.
        statusItem.autosaveName = "ccu-menubar-status-item"
        statusItem.button?.title = renderTitle()
        statusItem.menu = menu
        menu.delegate = self
        bind()
    }

    private func bind() {
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.statusItem.button?.title = self.renderTitle()
            }
            .store(in: &cancellables)
    }

    // MARK: - Title

    private func renderTitle() -> String {
        let s = store.state?.session?.usedPct
        let w = store.state?.weekly?.usedPct
        // Compact form (`S42% │ W67%`) — a narrow status item is far less likely
        // to be swallowed by the notch on a crowded menu bar.
        let body = "S\(format(s)) │ W\(format(w))"
        switch store.producerStatus {
        case .ok where !(store.state?.isStale ?? true):
            return body
        case .ok:
            return "⚠ " + body
        case .authStale:
            return "⚠ " + body
        case .offline:
            return "⚠ " + body
        case .neverSeen:
            return "S--% │ W--%"
        }
    }

    private func format(_ pct: Double?) -> String {
        guard let pct else { return "--%" }
        return "\(Int(pct.rounded()))%"
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
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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
