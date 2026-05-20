import Combine
import Foundation
import UserNotifications

/// Posts a local notification when session or weekly usage crosses the warning
/// or critical threshold.
///
/// Edge-triggered: each level fires at most once per reset window. A latch is
/// persisted in `UserDefaults` keyed by the bucket's `resets_at_unix`, so an
/// app restart never re-notifies for a crossing already announced, and a fresh
/// reset window re-arms the alerts.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let store: StateStore
    private let settings: Settings
    private var cancellables: Set<AnyCancellable> = []

    init(store: StateStore, settings: Settings) {
        self.store = store
        self.settings = settings
        super.init()
    }

    func start() {
        // UNUserNotificationCenter requires a real app bundle; the bare SwiftPM
        // binary (`swift run`) has no bundle identifier and would trap.
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("notifications disabled: not running from an app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.warn("notification authorization error: \(error)")
            } else {
                Log.info("notification authorization granted=\(granted)")
            }
        }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.evaluate() }
            .store(in: &cancellables)
        evaluate()
    }

    // MARK: - Threshold evaluation

    private func evaluate() {
        guard settings.notificationsEnabled,
              Bundle.main.bundleIdentifier != nil else { return }
        check(bucket: store.state?.session, kind: .session)
        check(bucket: store.state?.weekly, kind: .weekly)
    }

    private func check(bucket: Bucket?, kind: BucketKind) {
        guard let pct = bucket?.usedPct else { return }
        let window = bucket?.resetsAtUnix ?? 0
        let level = usageLevel(forPct: pct)

        var latch = Latch.load(kind: kind)
        if latch.window != window {
            // New reset window — re-arm all alerts for this bucket.
            latch = Latch(level: 0, window: window)
        }
        if level > latch.level {
            notify(kind: kind, level: level, pct: pct, resetsAtUnix: bucket?.resetsAtUnix)
            latch.level = level
        } else if level < latch.level {
            // Usage fell back below a threshold — re-arm so a later climb fires.
            latch.level = level
        }
        latch.save(kind: kind)
    }

    private func usageLevel(forPct pct: Double) -> Int {
        if pct >= settings.criticalThreshold { return 2 }
        if pct >= settings.warnThreshold { return 1 }
        return 0
    }

    private func notify(kind: BucketKind, level: Int, pct: Double, resetsAtUnix: Int?) {
        let content = UNMutableNotificationContent()
        content.title = "\(kind.label) usage at \(Int(pct.rounded()))%"
        var body = level >= 2
            ? "You're close to your \(kind.lowerLabel) limit"
            : "Approaching your \(kind.lowerLabel) limit"
        if let unix = resetsAtUnix {
            body += " — " + Formatters.resetInOrAt(unix: unix)
        }
        content.body = body + "."
        if settings.notifySound {
            content.sound = .default
        }
        let id = "ccu-\(kind.rawValue)-\(level)-\(resetsAtUnix ?? 0)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.warn("notification add failed: \(error)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Show the banner even though a menu-bar agent is always "running".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private enum BucketKind: String {
    case session
    case weekly

    var label: String { self == .session ? "Session" : "Weekly" }
    var lowerLabel: String { self == .session ? "session" : "weekly" }
}

/// Highest threshold level (`0` none, `1` warn, `2` critical) already announced
/// for a bucket, plus the reset window it applies to.
private struct Latch {
    var level: Int
    var window: Int

    static func load(kind: BucketKind) -> Latch {
        let d = UserDefaults.standard
        return Latch(
            level: d.integer(forKey: "ccu.notify.\(kind.rawValue).level"),
            window: d.integer(forKey: "ccu.notify.\(kind.rawValue).window"))
    }

    func save(kind: BucketKind) {
        let d = UserDefaults.standard
        d.set(level, forKey: "ccu.notify.\(kind.rawValue).level")
        d.set(window, forKey: "ccu.notify.\(kind.rawValue).window")
    }
}
