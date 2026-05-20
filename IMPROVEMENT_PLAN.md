# CCUMenuBar — Improvement Plan

Product-development plan for making the menu bar app more proactive and easier
to live with. Five items were scoped; this document covers the **remaining**
work.

## Status

| # | Item | State |
|---|------|-------|
| 1 | Threshold notifications | **Shipped** |
| 2 | In-app onboarding / setup flow | **Shipped** |
| 3 | Notarized release + Homebrew cask | Planned |
| 4 | Visual urgency in the menu bar title | **Shipped** |
| 5 | Actionable menu + Preferences window | **Shipped** |

---

## Prerequisite — `Settings.swift` (shared foundation) — Shipped

`Settings.swift` exists: a `UserDefaults`-backed type holding `warnThreshold`
(80), `criticalThreshold` (95), `notificationsEnabled`, and `notifySound`. Both
the menu bar title coloring (#4) and the notification alerts (#1) read their
thresholds from it. #5 will extend it (display style, poll interval) and add
the Preferences UI to mutate it.

---

## #1 — Threshold notifications — Shipped

`NotificationManager.swift` posts an alert when a bucket crosses the warning or
critical threshold; edge-triggered, with a per-reset-window latch persisted in
`UserDefaults`. The notes below are kept for reference.

**Goal:** a native macOS notification when session/weekly usage crosses a
threshold, so you don't have to actively watch the menu bar.

**Approach**
- New `NotificationManager.swift` (`@MainActor`). Uses the `UserNotifications`
  framework — request authorization (`.alert`, `.sound`) at launch.
- Subscribe to `store.objectWillChange` (same pattern as
  `MenuBarController.bind()`), read `store.state`, evaluate each bucket.
- **Edge-triggered latch** to avoid spam: keep per-bucket
  `(windowResetUnix, highestThresholdFired)`. Fire only when `usedPct` rises
  past a threshold not yet fired for the current reset window. When
  `resets_at_unix` changes (new window) or usage drops below all thresholds,
  clear the latch. Persist the latch in `UserDefaults` so an app restart
  doesn't re-fire.
- Notification body includes reset time via existing `Formatters.resetInOrAt`.

**Files:** new `NotificationManager.swift`; `AppDelegate.swift` (instantiate +
request auth).

**Caveats**
- `UserNotifications` requires a real app bundle — works only from
  `CCUMenuBar.app`, not `swift run` (same constraint as `LaunchAtLogin`).
  Guard on `Bundle.main.bundleIdentifier != nil` and skip cleanly otherwise.
- First launch shows a permission prompt.

**Effort:** small–medium, ~1 new file.

---

## #3 — Notarized release + Homebrew cask

**Goal:** one-command install, no Gatekeeper friction.

**Approach**
- Parametrize `make-app.sh`: signing identity from env var (default `-` ad-hoc
  for local dev), add `--options runtime` (hardened runtime, required for
  notarization), read `VERSION` from the git tag.
- New `.github/workflows/release.yml` on `macos-14`, triggered by `v*` tags:
  `swift build -c release` -> `make-app.sh` with the real Developer ID
  identity -> zip -> `xcrun notarytool submit --wait` -> `xcrun stapler staple`
  -> create GitHub Release with the asset.
- Homebrew cask `Casks/ccumenubar.rb` in a tap repo; CI updates its version +
  SHA256 per release.

**Caveats**
- Requires a paid Apple Developer account ($99/yr) and these GitHub secrets:
  Developer ID cert (`.p12` base64 + password) and an App Store Connect API
  key (issuer ID, key ID, `.p8`).
- Cannot be tested without signing certs — write/commit the workflow + scripts,
  then run a real release to validate.

**Effort:** medium, mostly CI YAML; blocked on the developer account.

---

## #5 — Actionable menu + Preferences window — Shipped

Shipped with **Refresh now** and **Reveal logs in Finder** menu actions and a
SwiftUI **Preferences** window (notification toggles + warn/critical
thresholds, bound to `Settings`). The "Open usage page" item was dropped — no
reliable usage URL. The notes below are kept for reference.

**Goal:** the dropdown should *do* things, not just display.

**Approach**
- New menu items in `MenuBarController.menuNeedsUpdate`:
  - **Refresh now** — add `OAuthPoller.refreshNow()` (simplest: `stop()` +
    `start()`, which re-ticks immediately).
  - **Reveal logs in Finder** — `NSWorkspace.activateFileViewerSelecting` on
    `ccu.log`.
  - **Open usage page** — `NSWorkspace.open` on the Claude usage URL
    (confirm the exact URL before wiring it).
  - **Preferences…** — opens the settings window.
- New `PreferencesWindow` (SwiftUI hosted in an `NSWindow` via
  `NSHostingController`, consistent with the Setup window): display style,
  warn/critical thresholds, notification toggles + sound, poll interval,
  launch-at-login. All bound to `Settings.swift`.

**Files:** new `PreferencesWindow`; edits to `MenuBarController.swift`,
`OAuthPoller.swift`, `AppDelegate.swift`.

**Effort:** medium.

---

## Suggested build order

1. ~~`Settings.swift`~~ — done
2. ~~**#1** — Threshold notifications~~ — done
3. ~~**#5** — Actionable menu + Preferences~~ — done
4. **#3** — Notarized release + Homebrew cask (blocked on the Apple Developer
   account)
