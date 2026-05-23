import AppKit
import SwiftUI

/// Preferences pane — notification toggles and the usage thresholds. Bound
/// directly to `Settings`; edits persist immediately and the menu bar re-colors
/// live via `Settings`' `objectWillChange`.
struct PreferencesView: View {
    @ObservedObject var settings: Settings
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.title2).bold()

            GroupBox("Notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Alert me when usage is high", isOn: bool(\.notificationsEnabled))
                    Toggle("Play a sound with alerts", isOn: bool(\.notifySound))
                        .disabled(!settings.notificationsEnabled)
                        .padding(.leading, 18)
                    Toggle("Quiet hours", isOn: bool(\.quietHoursEnabled))
                        .disabled(!settings.notificationsEnabled)
                    HStack(spacing: 12) {
                        Stepper("From \(hourLabel(settings.quietHoursStart))",
                                value: int(\.quietHoursStart), in: 0...23)
                        Stepper("Until \(hourLabel(settings.quietHoursEnd))",
                                value: int(\.quietHoursEnd), in: 0...23)
                    }
                    .disabled(!settings.notificationsEnabled || !settings.quietHoursEnabled)
                    .padding(.leading, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }

            GroupBox("Thresholds") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Warn at \(Int(settings.warnThreshold))%",
                            value: warnBinding, in: 50...95, step: 5)
                    Stepper("Critical at \(Int(settings.criticalThreshold))%",
                            value: criticalBinding, in: 55...100, step: 5)
                    Text("Used for the menu bar color and the notification alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func bool(_ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { settings[keyPath: keyPath] = $0 })
    }

    private func int(_ keyPath: ReferenceWritableKeyPath<Settings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { settings[keyPath: keyPath] = $0 })
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    // Keep warn at least 5 points below critical, whichever the user drags.
    private var warnBinding: Binding<Double> {
        Binding(get: { settings.warnThreshold },
                set: { settings.warnThreshold = min($0, settings.criticalThreshold - 5) })
    }

    private var criticalBinding: Binding<Double> {
        Binding(get: { settings.criticalThreshold },
                set: { settings.criticalThreshold = max($0, settings.warnThreshold + 5) })
    }
}

/// Owns the Preferences `NSWindow`. The app runs as an `.accessory` agent, so
/// the window has no Dock entry; we activate explicitly to bring it forward.
@MainActor
final class PreferencesWindowController {
    private let settings: Settings
    private var window: NSWindow?

    init(settings: Settings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let view = PreferencesView(settings: settings) { [weak self] in
                self?.window?.close()
            }
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.styleMask = [.titled, .closable]
            win.title = "Preferences"
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
