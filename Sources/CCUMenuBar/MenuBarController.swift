import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: StateStore
    private let settings: Settings
    private let usageSummaryStore = UsageSummaryStore()
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    // Held while the menu is open so we can re-render in place — state can
    // change between `menuNeedsUpdate` and the next close, and the time-relative
    // status row needs to advance every second. Without these refs the open
    // menu would show "Updated 1s ago" over yesterday's percentages.
    private var statusRowItem: NSMenuItem?
    private var sessionRowItem: NSMenuItem?
    private var weeklyRowItem: NSMenuItem?
    private var sessionPaceRowItem: NSMenuItem?
    private var weeklyPaceRowItem: NSMenuItem?
    private var openMenuTimer: Timer?

    /// Invoked when the user picks "Setup…". Wired up by `AppDelegate`.
    var onOpenSetup: (() -> Void)?

    /// Invoked when the user picks "Reload now".
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
            .sink { [weak self] in
                self?.updateTitle()
                self?.updateStatusRowInPlace()
                self?.refreshBucketRowsInPlace()
            }
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
        let state = store.state
        let stale = state?.isStale ?? true
        let sessionOverdue = state?.session?.isResetOverdue ?? false
        let weeklyOverdue = state?.weekly?.isResetOverdue ?? false
        // Overdue keeps the percentage visible — the menu row's "reset due"
        // tail and the title's ⚠ prefix already convey that the number is
        // from the previous window. Hiding it just makes the menu look broken
        // for the several minutes between window reset and Claude Code's first
        // API call of the new window.
        let sessionDim = stale
        let weeklyDim = stale
        let sessionPct: Double? = sessionDim ? nil : state?.session?.usedPct
        let weeklyPct: Double? = weeklyDim ? nil : state?.weekly?.usedPct
        let warn = stale || sessionOverdue || weeklyOverdue

        switch store.producerStatus {
        case .neverSeen:
            return composeTitle(warn: false, sessionPct: nil, sessionDim: true,
                                weeklyPct: nil, weeklyDim: true)
        case .ok:
            return composeTitle(warn: warn, sessionPct: sessionPct, sessionDim: sessionDim,
                                weeklyPct: weeklyPct, weeklyDim: weeklyDim)
        }
    }

    // Each bucket carries its own dim flag — session can be overdue (previous
    // window's stale reading) while weekly is still fresh, and vice versa.
    private func composeTitle(warn: Bool,
                              sessionPct: Double?, sessionDim: Bool,
                              weeklyPct: Double?, weeklyDim: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Structural glyphs go grey only when *both* sides are untrusted, so a
        // partial-stale title still reads as live rather than entirely dim.
        let structural: NSColor = (sessionDim && weeklyDim) ? .secondaryLabelColor : .labelColor
        if warn {
            result.append(segment("⚠ ", color: .systemOrange))
        }
        result.append(segment("S", color: structural))
        result.append(segment(percentText(sessionPct),
                               color: sessionDim ? .secondaryLabelColor : color(forPct: sessionPct)))
        result.append(segment(" │ ", color: structural))
        result.append(segment("W", color: structural))
        result.append(segment(percentText(weeklyPct),
                               color: weeklyDim ? .secondaryLabelColor : color(forPct: weeklyPct)))
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

    func menuWillOpen(_ menu: NSMenu) {
        openMenuTimer?.invalidate()
        // `Formatters.ago` resolves down to seconds, so tick at 1s while the
        // menu is open to keep "Updated 41s ago" actually moving — and so the
        // post-reload re-read becomes visible without closing/reopening.
        //
        // Must be added in `.common` mode: NSMenu tracking runs the main run
        // loop in `.eventTracking`, and `Timer.scheduledTimer` would only add
        // to `.default`, so the timer would never fire while the menu is open.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusRowInPlace() }
        }
        RunLoop.main.add(t, forMode: .common)
        openMenuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenuTimer?.invalidate()
        openMenuTimer = nil
        statusRowItem = nil
        sessionRowItem = nil
        weeklyRowItem = nil
        sessionPaceRowItem = nil
        weeklyPaceRowItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = store.state
        let stale = state?.isStale ?? true
        menu.addItem(usageSummaryItem())
        menu.addItem(.separator())
        // Hold refs to every dynamic row so the Combine sink can update them in
        // place. Pace rows are always added — `applyPaceRow` toggles `isHidden`
        // so they hide when there's no pace data and reappear when there is,
        // without rebuilding the menu while it's open.
        let sessionRow = rowFor(label: "Session", bucket: state?.session, stale: stale)
        menu.addItem(sessionRow)
        sessionRowItem = sessionRow
        let sessionPace = paceRow(for: state?.session, kind: .session)
        menu.addItem(sessionPace)
        sessionPaceRowItem = sessionPace
        let weeklyRow = rowFor(label: "Weekly", bucket: state?.weekly, stale: stale)
        menu.addItem(weeklyRow)
        weeklyRowItem = weeklyRow
        let weeklyPace = paceRow(for: state?.weekly, kind: .weekly)
        menu.addItem(weeklyPace)
        weeklyPaceRowItem = weeklyPace
        let row = statusRow()
        menu.addItem(.separator())
        menu.addItem(row)
        statusRowItem = row
        menu.addItem(.separator())
        menu.addItem(refreshItem())
        menu.addItem(actionItem(title: "Reveal logs in Finder", selector: #selector(revealLogs)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Setup…", selector: #selector(openSetup)))
        menu.addItem(actionItem(title: "Preferences…", selector: #selector(openPreferences),
                                keyEquivalent: ","))
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit", selector: #selector(quit), keyEquivalent: "q"))
    }

    private func usageSummaryItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = UsageSummaryCardView(summary: usageSummaryStore.refresh())
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, selector: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func refreshItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Reload now", action: nil, keyEquivalent: "")
        let view = RefreshMenuItemView()
        view.onClick = { [weak self] in self?.refreshNow() }
        item.view = view
        item.toolTip = "Re-reads state.json. Fresh data arrives after Claude Code runs the statusline bridge."
        return item
    }

    // Stale state would mislead pace (elapsed grows, pct doesn't) — and the
    // ⚠ title prefix already flags the same condition. `applyPaceRow` hides
    // the item in that case instead of returning nil, so the same item can
    // reappear via an in-place update if a fresh state lands while the menu
    // is open.
    private func paceRow(for bucket: Bucket?, kind: Pace.Kind) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        applyPaceRow(item: item, bucket: bucket, kind: kind)
        return item
    }

    private func applyPaceRow(item: NSMenuItem, bucket: Bucket?, kind: Pace.Kind) {
        guard let bucket, !(store.state?.isStale ?? true),
              let r = Pace.compute(bucket: bucket, kind: kind) else {
            item.isHidden = true
            return
        }
        item.isHidden = false

        let state: String
        let color: NSColor
        if r.deltaPct < -3 {
            state = "Ahead"
            color = .systemGreen
        } else if r.deltaPct > 3 {
            state = "Behind"
            color = r.projectedToHitLimit ? .systemRed : .systemOrange
        } else {
            state = "On track"
            color = .secondaryLabelColor
        }

        let sign = r.deltaPct >= 0 ? "+" : "−"
        let mag = Int(abs(r.deltaPct).rounded())
        // Snap to "+0%" when the rounded magnitude is zero — avoids the
        // visually odd "−0%" for small negative deltas like -0.4.
        let deltaText = mag == 0 ? "+0%" : "\(sign)\(mag)%"
        let tail: String?
        if r.projectedToHitLimit, let eta = r.etaSeconds {
            tail = "hits limit in \(Formatters.humanDuration(eta))"
        } else if r.etaSeconds != nil {
            // ETA computed but no bust projected. "Behind … lasts to reset"
            // sounds contradictory — use clearer wording for that case.
            tail = state == "Behind" ? "safe through reset" : "lasts to reset"
        } else {
            // Too early in the window to extrapolate (or pct < 1) — omit tail.
            tail = nil
        }
        let title = "Pace: \(state) (\(deltaText))" + (tail.map { " · \($0)" } ?? "")
        item.title = title
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0),
        ])
    }

    private func rowFor(label: String, bucket: Bucket?, stale: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        applyBucketRow(item: item, label: label, bucket: bucket, stale: stale)
        return item
    }

    private func applyBucketRow(item: NSMenuItem, label: String, bucket: Bucket?, stale: Bool) {
        // Only `stale` hides the percentage. A reset that's already passed
        // gets surfaced via the "reset due" tail (from Formatters) without
        // wiping the number — the previous window's percentage is still useful
        // info ("you finished at 31%"), and hiding it just looks like a bug.
        let pct = stale ? "--%" : (bucket?.usedPct.map { "\(Int($0.rounded()))%" } ?? "--%")
        let resets: String
        if stale {
            resets = "stale data"
        } else if let unix = bucket?.resetsAtUnix {
            resets = Formatters.resetInOrAt(unix: unix)
        } else {
            resets = "unknown reset"
        }
        let title = "\(label)   \(pct)   \(resets)"
        item.title = title
        if stale {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        } else {
            // Clear any previous dim styling — NSMenuItem.attributedTitle wins
            // over .title when non-nil, so leaving stale attrs in place would
            // freeze the dim color across a stale → fresh cycle.
            item.attributedTitle = nil
        }
    }

    /// Updates the dynamic bucket and pace rows in place. No-op when the menu
    /// is closed (item refs are cleared in `menuDidClose`).
    private func refreshBucketRowsInPlace() {
        let state = store.state
        let stale = state?.isStale ?? true
        if let item = sessionRowItem {
            applyBucketRow(item: item, label: "Session", bucket: state?.session, stale: stale)
        }
        if let item = weeklyRowItem {
            applyBucketRow(item: item, label: "Weekly", bucket: state?.weekly, stale: stale)
        }
        if let item = sessionPaceRowItem {
            applyPaceRow(item: item, bucket: state?.session, kind: .session)
        }
        if let item = weeklyPaceRowItem {
            applyPaceRow(item: item, bucket: state?.weekly, kind: .weekly)
        }
    }

    private func statusRowTitle() -> String {
        switch store.producerStatus {
        case .neverSeen:
            if let bridge = BridgeStatus.read(), bridge.isActive {
                let ago = bridge.lastSeenDate.map { Formatters.ago(since: $0) } ?? "just now"
                return "Bridge active · waiting for rate_limits (last call \(ago))"
            } else {
                return "No data yet — run a Claude Code command."
            }
        case .ok:
            let ago = store.state?.updatedAtDate.map { Formatters.ago(since: $0) } ?? "—"
            let stale = (store.state?.isStale ?? false) ? "  (stale)" : ""
            return "Updated \(ago)\(stale)"
        }
    }

    private func statusRow() -> NSMenuItem {
        let item = NSMenuItem(title: statusRowTitle(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func updateStatusRowInPlace() {
        statusRowItem?.title = statusRowTitle()
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
