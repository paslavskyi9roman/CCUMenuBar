# Robustness Fix Plan

Prioritized, actionable follow-ups from the robustness audit. Ordered by
severity × user impact. Each item lists the symptom, the root cause with file
references, the fix direction, and a rough size.

Legend: **P0** ship-blocking / user-visible wrong data · **P1** foundational /
high-impact · **P2** hardening / polish.

**Status: all 13 items implemented** on `fix/robust-task`. Notes below mark
where the shipped fix diverged from the originally proposed direction.

---

## P0 — Correctness

### 1. Self-test leaves fake numbers in the menu bar — ✅ Done

- **Symptom:** After running the Setup self-test, the menu bar shows the canary
  values (`S17% │ W32%`) and stays there until Claude Code next writes fresh
  data — indefinitely if CC isn't running.
- **Cause:** `runSelfTest()` writes canary state, then restores the prior
  `state.json` (`BridgeInstaller.swift:196`, `restore` at `:254`). The watcher
  ingests the canary write (fresh `updated_at`, wins), then ingests the restore
  — but the restored state has an *older* `updated_at`, so the last-write-wins
  guard in `StateStore.ingest` drops it (`StateStore.swift:23`). On-disk file is
  correct; in-memory `state` is wrong.
- **Fix:** Give the store a restore-aware path that bypasses LWW. Options:
  - Add `StateStore.forceIngest(_:)` and have the self-test call
    `watcher.refreshNow()` through a "force" flag after restore, **or**
  - Pause the watcher for the duration of the self-test (stop → run → restore →
    start), so the canary write is never ingested in the first place. Preferred:
    it also stops the canary from briefly flashing in the menu bar.
- **Size:** S.
- **Shipped:** neither of the above — the bridge script now honors a
  `CCU_STATE_DIR` env override, so the self-test runs against a throwaway
  scratch directory instead of the live `state.json`. No save/restore, no
  watcher interaction, no race with `StateStore.ingest` at all — the canary
  never touches the file the app is watching. Simpler and removes the whole
  bug class rather than patching around it.

---

## P1 — Foundational

### 2. Usage summary does a synchronous full scan on the main thread — ✅ Done

- **Symptom:** Menu open beachballs / lags for heavy users; first open after
  launch is worst. Memory grows unbounded with transcript history.
- **Cause:** `menuNeedsUpdate` → `usageSummaryItem()` →
  `UsageSummaryStore.refresh()` (`MenuBarController.swift:214`) recursively
  enumerates `~/.claude/projects` and parses every `.jsonl` line with
  `JSONSerialization`, on the main thread during menu tracking
  (`UsageSummary.swift:53`). The (size, mtime) cache misses on the active
  session's file every open, and retains every parsed `UsageEvent` from every
  file forever (`UsageSummary.swift:80`).
- **Fix:**
  - Compute the summary off the main thread; render the last-computed snapshot
    instantly and refresh in the background (kick a refresh on menu open and on
    a timer, publish results back to `@MainActor`).
  - Parse incrementally: track a byte offset per file, parse only appended
    bytes on the hot (active-session) file instead of re-reading the whole file.
  - Aggregate to per-file day-bucket totals in the cache instead of retaining
    every `UsageEvent`; only the active file needs per-event granularity for the
    "latest tokens" figure.
- **Size:** M.
- **Shipped:** the off-main-thread half — `UsageSummaryStore.refreshAsync`
  runs `refresh()` on a private background queue; `MenuBarController` renders
  a `cachedUsageSummary` instantly on menu open and refreshes it every 60s in
  the background. Removes the beachball risk entirely. Incremental
  (byte-offset) parsing and bounded per-event retention are **not** done —
  still full-file re-parse per changed file, just off the main thread now.
  Worth a follow-up if transcript sizes become a memory concern.

### 3. `state.json` public contract: add version, loosen timestamp parsing — ✅ Done

- **Symptom:** A third-party producer (documented in README as supported) that
  writes fractional-second timestamps (`...:00.123Z`) makes the app show a
  permanently stale `⚠ --%`, with LWW silently disabled because the date parse
  returns nil.
- **Cause:** `State.iso8601` uses `[.withInternetDateTime]` only, no fractional
  seconds (`StateModel.swift:59`). `updatedAtDate` → nil → `ageSeconds` nil →
  `isStale` always true (`StateModel.swift:38-49`); `ingest`'s LWW comparison is
  skipped when either date is nil (`StateStore.swift:24`). Also, `state.json`
  has no `schema_version` even though `bridge-status.json` does.
- **Fix:**
  - Parse `updated_at` leniently: try fractional then non-fractional, mirroring
    `UsageSummaryStore.parseTimestamp` (`UsageSummary.swift:215`). Consider a
    shared date-parsing helper so all three sites agree.
  - Add an optional `schema_version` field to `State` / `Bucket` and to the
    bridge's `jq` output now, while adding a field is still non-breaking. Bump
    the README "state.json interface" section.
- **Size:** S.
- **Shipped:** `State.parseTimestamp` tries fractional then whole-second
  ISO-8601 and is now used everywhere a timestamp is parsed (`updatedAtDate`,
  `BridgeStatus.lastSeenDate`, `StateStore.ingest`'s LWW check, and
  `UsageSummaryStore`, which had its own duplicate formatter — consolidated).
  `schema_version` added to `State` (optional, defaults to absent-safe) and to
  the bridge's `jq` output (`"schema_version": 1`). README schema doc updated.

### 4. `StateStore.objectWillChange` fires *after* the mutation — ✅ Done

- **Symptom:** None today (no SwiftUI view binds the store), but any future
  `@ObservedObject var store: StateStore` renders one update behind. Silent,
  hard to debug.
- **Cause:** `ingest` mutates `state` first, then debounces a `send()` 100ms
  later (`StateStore.swift:29-40`). Violates the Combine "will change" contract.
- **Fix:** Rename the subject to `stateDidChange` (honest name) *or* restructure
  so the notification precedes the mutation. Given no current SwiftUI binding,
  renaming is the low-risk choice and documents intent.
- **Size:** S.
- **Shipped:** renamed to `stateDidChange`, dropped `ObservableObject`
  conformance (nothing required it), updated the two call sites
  (`MenuBarController`, `NotificationManager`).

### 5. Watchdog false-alarms on normal idleness — ✅ Done

- **Symptom:** "Bridge stopped reporting — Claude Code may need a restart" fires
  after any work break > 30 min (lunch, meetings, EOD). One per break, but every
  break.
- **Cause:** `heartbeatTimeout = 30 * 60` (`BridgeWatchdog.swift:22`); heartbeat
  age alone can't distinguish "CC not running" (normal) from "CC running but
  bridge broken" (the actual regression). Comment at `:20` claims lunch won't
  fire it — 30 min is shorter than most lunches.
- **Fix:** Before notifying `stoppedReporting`, check whether a `claude` process
  is actually running (e.g. `pgrep -x claude` via `Process`, or scan
  `NSWorkspace`/`sysctl` process list). Only alert when CC is alive *and* the
  heartbeat is stale — that's the true "bridge broke" signal. Idle → no alert.
- **Size:** M.
- **Shipped:** `BridgeWatchdog.isClaudeCodeRunning()` shells out to
  `pgrep -x claude`, fails open (treats CC as running) if `pgrep` itself can't
  launch. Both `neverInvoked` and `stoppedReporting` are now gated on this.
  The check runs on a background queue (`tick()` dispatches, then hops back to
  `@MainActor` via a new `evaluate(claudeCodeRunning:)`) to keep the `Process`
  spawn off the main thread, matching the self-test's existing discipline.

### 6. CLAUDE.md describes an architecture that no longer exists — ✅ Done

- **Symptom:** Every session (human or AI) reads the wrong system model first.
- **Cause:** CLAUDE.md documents `OAuthPoller` / Producer B, `writeAndStore` +
  fingerprint dedup, and "no test target." The poller was removed (`452d1d8`),
  `writeAndStore` isn't in the tree, and `Tests/CCUMenuBarTests` + a test target
  in `Package.swift` both exist. `State.fingerprint()` (`StateModel.swift:51`)
  is now dead code from the removed design.
- **Fix:** Rewrite CLAUDE.md to the current one-producer reality (bridge only;
  OAuth path gone). Delete `State.fingerprint()` and its `CryptoKit` import if
  unused elsewhere. Correct the "no test target" line.
- **Size:** S.
- **Shipped:** CLAUDE.md rewritten (one-producer architecture, `CCU_STATE_DIR`
  noted, `StateStore` description corrected, test command added, `Gotchas`
  updated). `State.fingerprint()` and its now-unused `CryptoKit` import
  deleted (`BridgeInstaller.swift` still imports `CryptoKit` for its own
  `sha256` helper, unaffected).

### 7. The critical invariant has no test and there's no CI — ✅ Done

- **Symptom:** The one coupling CLAUDE.md calls out — bridge `jq` output must
  stay byte-compatible with the Swift `Codable` types — is the thing nothing
  guards. No `.github/`, no CI.
- **Cause:** Only `UsageSummaryTests` exists; the schema seam and the pure-logic
  units are untested.
- **Fix:**
  - Add a test that runs `ccu-statusline-bridge.sh` against a fixture payload
    and decodes the resulting file as `State.self` — fails the build if the
    shapes drift.
  - Add pure-logic tests: `Pace.compute` (including out-of-range pct),
    `StateStore.ingest` LWW, `Settings.isInQuietHours` (incl. midnight-spanning),
    notification `Latch` re-arm.
  - Add a GitHub Actions workflow: `swift build && swift test` on macOS.
- **Size:** M.
- **Shipped:** `BridgeScriptTests.swift` runs the actual bundled script
  (via `CCU_STATE_DIR`) against fixture payloads and decodes the result as
  `State` — one test for the happy path, one confirming no `state.json` is
  written when `rate_limits` is absent. Added `PaceTests.swift` (on-track,
  overdue-reset, just-after-reset, burn-faster-than-window) and
  `SettingsTests.swift` (midnight-spanning quiet hours, disabled, start==end).
  `NotificationManager`'s `Latch` stayed private and untested — testing it
  would mean either exposing it or testing through `UserNotifications`
  side effects, both bigger changes than this pass covered. Added
  `.github/workflows/ci.yml` running `swift build && swift test` on
  `macos-14`.

---

## P2 — Hardening & polish

### 8. No input validation on `used_pct` — ✅ Done

- Values > 100 make `Pace` project a negative ETA (`(100-pct)/pct * elapsed`),
  flip `willBust` true, and render negative durations (`Pace.swift:63`,
  `Formatters.humanDuration`). Clamp `usedPct` to `0...100` at ingest.
- **Size:** S.
- **Shipped:** `Bucket.clamped()` clamps `usedPct` to `0...100`;
  `StateStore.ingest` applies it to both buckets before storing.

### 9. `configureSettings` read-modify-write race on `~/.claude/settings.json` — ✅ Done (mitigation)

- Concurrent CC write can lose one side's changes (`BridgeInstaller.swift:143`).
  It's not our file, so the failure is ugly. Re-read and verify after write;
  document the residual race. (Full fix needs file locking — likely not worth
  it.)
- **Size:** S (mitigation) / M (full).
- **Shipped:** the mitigation only — `configureSettings()` re-checks
  `isSettingsConfigured` after writing and logs a warning if the `statusLine`
  key isn't present, so a lost race is at least visible in `ccu.log` instead
  of silently reporting success. No locking (still racy, now detectable).

### 10. Inner-statusline sidecar only runs its first non-comment line — ✅ Done

- A user's prior multi-line statusline command is silently truncated
  (`ccu-statusline-bridge.sh:143`). Either exec the whole sidecar as a script,
  or document the single-line limitation in Setup and the script header.
- **Size:** S.
- **Shipped:** the bridge now runs `sh "${INNER_SIDECAR}"` directly instead of
  `grep`-extracting the first non-comment line and re-execing just that.
  Verified locally: a two-line sidecar now runs both lines (previously only
  the first).

### 11. Bridge temp files leak into the watched directory — ✅ Done

- `state.json.tmp.$$` lands in the state dir and each creation fires the
  directory watcher for nothing (`ccu-statusline-bridge.sh:31`,
  `StateFileWatcher.swift:47`). If the script dies mid-write, the temp orphans.
  Write temps with a leading dot (as the Swift side does) or in a subdir; add a
  startup sweep of stale `*.tmp.*`.
- **Size:** S.
- **Shipped:** bridge temp files renamed to `.state.json.tmp.$$` /
  `.bridge-status.json.tmp.$$` (hidden, matching the Swift side's
  `.name.ccu.tmp.pid` convention). `StateStore.init()` sweeps any
  `*.tmp.*` entry in the state directory older than 5 minutes on launch.

### 12. Notification authorization result is never consulted — ✅ Done

- Auth is requested but the grant/deny result isn't stored
  (`NotificationManager.swift:33`). If denied, both notifiers post into the void
  and the user sees nothing with no explanation. Surface denied state in
  Preferences with a "enable in System Settings" hint.
- **Size:** S.
- **Shipped:** `PreferencesView` queries
  `UNUserNotificationCenter.current().notificationSettings()` when the pane
  first appears (`.task`) and shows an orange warning label above the
  notification toggles when `authorizationStatus == .denied`. Checked once per
  window lifetime, not live-updated while the pane is open — acceptable for a
  "you're probably wondering why alerts don't work" hint.

### 13. Hard-coded pace windows are an undocumented coupling — ✅ Done

- `Pace.Kind.windowSeconds` hard-codes 5h / 168h (`Pace.swift:15`). If Anthropic
  changes window sizes, pace silently lies. At minimum add it to the README
  "Caveats" alongside the two existing undocumented couplings.
- **Size:** XS.
- **Shipped:** added as a third bullet under README "Caveats."

---

## Suggested sequencing

1. **#1** (self-test wrong data) — small, user-visible, ship first.
2. **#6 + #7** (CLAUDE.md rewrite + invariant test + CI) — cheap, protects
   everything downstream, and every future change rides on it.
3. **#2** (off-main-thread usage summary) — biggest perceived-performance win.
4. **#3 + #4 + #5** (contract hardening, Combine contract, watchdog liveness).
5. **P2 batch** as capacity allows; #8 and #13 are near-free.

None of this requires re-architecting. The one-producer, file-as-IPC design with
atomic renames is sound — these are reinforcements, not a rebuild.

## Known gaps after this pass

- **#2** only moved the work off the main thread; it's still a full re-parse
  per changed file rather than incremental/byte-offset parsing, and per-event
  retention is still unbounded. Fine for now, worth revisiting if transcript
  histories get large enough to matter for memory.
- **#9** is detect-and-log, not prevent — the settings.json race is still
  possible, just no longer silent.
- This environment couldn't run `swift build` / `swift test` (Linux, no Swift
  toolchain) — all Swift changes were reviewed by hand and the bridge script
  changes were exercised directly with `bash` + `jq` (both available here).
  The `CI` workflow (macOS runner) is the first real compile of this diff —
  worth watching once it runs.
