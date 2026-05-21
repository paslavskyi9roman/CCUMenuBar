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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.warnThreshold: 80.0,
            Keys.criticalThreshold: 95.0,
            Keys.notificationsEnabled: true,
            Keys.notifySound: true,
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
}

