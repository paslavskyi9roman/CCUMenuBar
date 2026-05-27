import Foundation
import UserNotifications

/// Detects silent regressions where the bridge has stopped writing heartbeats
/// even though Setup looks complete on disk — config drift (someone edited
/// `~/.claude/settings.json`), a Claude Code update changing the rate_limits
/// shape, jq getting uninstalled, etc.
///
/// Without this watchdog the menu bar quietly goes ⚠ stale and the user has
/// no cue to look. With it, they get one local notification per crossing,
/// re-armed each time a fresh heartbeat lands. Edge-triggered in memory: app
/// restart re-arms because the user is engaged at that point anyway.
@MainActor
final class BridgeWatchdog {
    /// First-launch quiet window. Claude Code ticks the statusline frequently
    /// while running, so a real connection lands well within this. Long enough
    /// to absorb slow CC starts and "I just launched the app to look at it."
    private let firstHeartbeatGrace: TimeInterval = 5 * 60
    /// "Bridge stopped reporting" threshold. Tight enough to catch a
    /// same-session regression, loose enough that "I closed CC for lunch"
    /// doesn't fire.
    private let heartbeatTimeout: TimeInterval = 30 * 60
    /// How often we re-evaluate. Doesn't need to be precise — a 60s grain is
    /// fine against 5m and 30m thresholds.
    private let tickInterval: TimeInterval = 60

    private let settings: Settings
    private let bootDate = Date()
    private var timer: Timer?
    /// Most recent condition we've written to ccu.log. Advances even when the
    /// banner is suppressed (quiet hours, notifications off) so the log doesn't
    /// gain a line every 60s for the duration of an outage.
    private var loggedCondition: Condition?
    /// Most recent condition we've actually posted a banner for. Advances only
    /// after a successful `post()`, so a transition first observed during quiet
    /// hours re-attempts the banner once the gate opens.
    private var notifiedCondition: Condition?

    private enum Condition: Equatable {
        case neverInvoked
        /// Fires once per healthy → unhealthy transition. No escalation on
        /// worsening staleness within the same outage — recovery (a fresh
        /// heartbeat) re-arms the latch so the next regression notifies again.
        case stoppedReporting
    }

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        stop()
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard BridgeInstaller.isScriptInstalled,
              BridgeInstaller.isSettingsConfigured else {
            // Setup-incomplete is already handled by AppDelegate.showSetupOnFirstRun
            // re-opening the window on next launch. Don't double-prompt; just
            // clear any prior latches so a future re-install re-arms cleanly.
            loggedCondition = nil
            notifiedCondition = nil
            return
        }

        let condition = currentCondition()

        if condition == nil {
            if loggedCondition != nil {
                Log.info("bridge watchdog: heartbeat recovered, re-arming")
            }
            loggedCondition = nil
            notifiedCondition = nil
            return
        }

        guard let cond = condition else { return }

        // Gate notifications on the same toggles the threshold alerter uses,
        // so the user has one switch for both. Log either way so the regression
        // shows up in ccu.log even when banners are muted — but only once per
        // condition transition, gated by `loggedCondition`, otherwise ccu.log
        // would grow by a line every 60s for the entire outage.
        let bundled = Bundle.main.bundleIdentifier != nil
        let allowed = settings.notificationsEnabled && bundled && !settings.isInQuietHours()

        if condition != loggedCondition {
            switch cond {
            case .neverInvoked:
                Log.info("bridge watchdog: never invoked since boot (>\(Int(firstHeartbeatGrace))s)\(allowed ? "" : "; notification suppressed")")
            case .stoppedReporting:
                let age = BridgeStatus.read()?.ageSeconds.map { Int($0) } ?? -1
                Log.info("bridge watchdog: heartbeat stale (age=\(age)s)\(allowed ? "" : "; notification suppressed")")
            }
            loggedCondition = condition
        }

        // Only advance `notifiedCondition` after a successful post intent, so a
        // transition first observed during quiet hours retries on the next tick
        // that finds the gate open — "delayed alert beats silent miss".
        guard allowed else { return }
        guard condition != notifiedCondition else { return }
        notifiedCondition = condition
        post(cond)
    }

    private func currentCondition() -> Condition? {
        let bridge = BridgeStatus.read()
        if bridge == nil {
            return Date().timeIntervalSince(bootDate) > firstHeartbeatGrace
                ? .neverInvoked
                : nil
        }
        if let age = bridge?.ageSeconds, age > heartbeatTimeout {
            return .stoppedReporting
        }
        return nil
    }

    private func post(_ condition: Condition) {
        let content = UNMutableNotificationContent()
        switch condition {
        case .neverInvoked:
            content.title = "Claude Code Usage isn't receiving data"
            content.body = "Claude Code hasn't called the usage bridge since this app started. "
                + "Restart Claude Code to reconnect."
        case .stoppedReporting:
            let agoText = BridgeStatus.read()?.lastSeenDate.map { Formatters.ago(since: $0) } ?? "a while ago"
            content.title = "Claude Code Usage bridge stopped reporting"
            content.body = "Last update was \(agoText). Claude Code may need a restart."
        }
        if settings.notifySound {
            content.sound = .default
        }
        // One identifier per condition so re-arming a recovered regression
        // replaces the previous banner instead of stacking.
        let id = "ccu-watchdog-\(condition == .neverInvoked ? "neverInvoked" : "stoppedReporting")"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.warn("bridge watchdog notification failed: \(error)") }
        }
    }
}
