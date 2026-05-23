import Combine
import Foundation

/// User-tunable settings, backed by `UserDefaults`. The shared source of truth
/// for the usage thresholds — both the menu bar title coloring and the
/// notification alerts read from here, so they can't drift apart.
///
/// `ObservableObject` so the Preferences window can two-way bind and the menu
/// bar re-colors immediately when a threshold changes.
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    private enum Keys {
        static let warnThreshold = "ccu.warnThreshold"
        static let criticalThreshold = "ccu.criticalThreshold"
        static let notificationsEnabled = "ccu.notificationsEnabled"
        static let notifySound = "ccu.notifySound"
        static let quietHoursEnabled = "ccu.quietHoursEnabled"
        static let quietHoursStart = "ccu.quietHoursStart"
        static let quietHoursEnd = "ccu.quietHoursEnd"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.warnThreshold: 80.0,
            Keys.criticalThreshold: 95.0,
            Keys.notificationsEnabled: true,
            Keys.notifySound: true,
            Keys.quietHoursEnabled: false,
            Keys.quietHoursStart: 22,   // 22:00
            Keys.quietHoursEnd: 8,      // 08:00
        ])
    }

    /// Usage percentage at which a bucket is treated as "warning" (orange).
    var warnThreshold: Double {
        get { defaults.double(forKey: Keys.warnThreshold) }
        set { defaults.set(newValue, forKey: Keys.warnThreshold); objectWillChange.send() }
    }

    /// Usage percentage at which a bucket is treated as "critical" (red).
    var criticalThreshold: Double {
        get { defaults.double(forKey: Keys.criticalThreshold) }
        set { defaults.set(newValue, forKey: Keys.criticalThreshold); objectWillChange.send() }
    }

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Keys.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Keys.notificationsEnabled); objectWillChange.send() }
    }

    var notifySound: Bool {
        get { defaults.bool(forKey: Keys.notifySound) }
        set { defaults.set(newValue, forKey: Keys.notifySound); objectWillChange.send() }
    }

    /// When enabled, notifications are suppressed between `quietHoursStart`
    /// (inclusive) and `quietHoursEnd` (exclusive). A crossing missed during
    /// quiet hours fires on the next state update after the window ends —
    /// the user gets a delayed heads-up rather than nothing at all.
    var quietHoursEnabled: Bool {
        get { defaults.bool(forKey: Keys.quietHoursEnabled) }
        set { defaults.set(newValue, forKey: Keys.quietHoursEnabled); objectWillChange.send() }
    }

    /// Hour-of-day (0–23) at which quiet hours begin.
    var quietHoursStart: Int {
        get { defaults.integer(forKey: Keys.quietHoursStart) }
        set { defaults.set(newValue, forKey: Keys.quietHoursStart); objectWillChange.send() }
    }

    /// Hour-of-day (0–23) at which quiet hours end. May be less than the
    /// start to span midnight (e.g. 22→8).
    var quietHoursEnd: Int {
        get { defaults.integer(forKey: Keys.quietHoursEnd) }
        set { defaults.set(newValue, forKey: Keys.quietHoursEnd); objectWillChange.send() }
    }
}

