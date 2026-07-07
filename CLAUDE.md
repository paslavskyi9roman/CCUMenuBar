# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu bar app (`CCUMenuBar`, display name "Claude Code Usage") that shows Claude Code
session and weekly rate-limit percentages next to the notch. SwiftPM executable, AppKit, no
Xcode project. Targets macOS 14+, Swift 5.9+.

## Commands

```bash
swift build                    # debug build
swift build -c release         # release build (required before make-app.sh)
swift run CCUMenuBar           # build + run the bare binary (fast dev loop)
swift test                     # run the CCUMenuBarTests target
./scripts/make-app.sh          # wrap release binary into CCUMenuBar.app bundle
```

There is no linter configured.

`make-app.sh` is not optional packaging — it ad-hoc code-signs the bundle, which is what makes
`SMAppService` (Launch at login) persist its registration on Apple Silicon. The bare
`.build/release/CCUMenuBar` binary cannot register for launch-at-login; only the `.app` can.
After any change touching `LaunchAtLogin`, test against a freshly built `.app`, not `swift run`.

VS Code: `.vscode/launch.json` has "Debug CCUMenuBar" / "Release CCUMenuBar" configs (Swift extension).

## Git conventions

- Commit messages and PR titles/descriptions must **not** mention Claude, AI
  assistance, or include `claude.ai` links, "Generated with" notes, or
  `Co-Authored-By` trailers. Write them as a human author would.
- Author *and* commit as the repository user
  (`Roman Paslavskyi <46484914+paslavskyi9roman@users.noreply.github.com>`),
  never as `Claude`. This environment's default git config sets
  `user.name`/`user.email` to `Claude <noreply@anthropic.com>` — passing
  `git commit --author=...` alone only overrides the Author field, and
  GitHub can still render the commit using the Committer field. Set the
  **repo-local** git config before committing:
  `git config user.name "Roman Paslavskyi" && git config user.email "46484914+paslavskyi9roman@users.noreply.github.com"`.

## Architecture

This is a **one-producer / one-consumer system** built around a single shared JSON file:

```
~/Library/Application Support/ClaudeCodeUsage/state.json
```

**Producer — `Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh`** runs *outside this
app*, as a Claude Code statusline command. It extracts `.rate_limits` from the session JSON
Claude Code pipes to it, transforms it with `jq`, and atomic-writes `state.json`. It ships as a
SwiftPM bundle resource; the in-app Setup flow (`BridgeInstaller` / `SetupWindow`) installs it to
`~/.claude/scripts/` and wires up `settings.json`. Only updates while Claude Code is running.
`STATE_DIR` can be overridden with `CCU_STATE_DIR` — the app's Setup self-test uses this to run
the bridge against a throwaway directory instead of the live `state.json`.

An earlier version also had an in-app OAuth poller (Producer B) that hit an undocumented
`/api/oauth/usage` endpoint. It was removed — the statusline bridge is the sole producer now.

**Consumer — the app:** `StateFileWatcher` → `StateStore` → `MenuBarController`.

### Critical invariant: the shared JSON shape

`StateModel.swift` (`State` / `Bucket`, snake_case `CodingKeys`) defines the on-disk schema.
**The `jq` output in `ccu-statusline-bridge.sh` and the Swift `Codable` types must stay byte-compatible.**
Changing one without the other silently breaks the bridge. `CCUMenuBarTests` includes a test that
runs the bridge against a fixture payload and decodes the result with `State.self` to guard this
seam. The bridge writes via temp file + `rename(2)` for atomicity.

The schema is also a **public interface** — `scripts/ccu` and any external tool relying on the
file (documented in README → "The `state.json` interface") consume the same shape. Adding new
optional fields is fine; renaming, removing, or retyping existing fields is a breaking change
that warrants a major-version bump.

### Key components

- **`StateStore`** (`@MainActor ObservableObject`) — single source of truth. `ingest` applies
  *last-write-wins by `updated_at`*: a stale state never overwrites a newer one. `objectWillChange`
  is debounced 100ms and fires *after* the mutation (not before, despite the name) — fine today
  since nothing binds `StateStore` as a SwiftUI `@ObservedObject`, but worth knowing if one ever does.
- **`StateFileWatcher`** — kqueue watch on `state.json`. Because every writer replaces the file
  via `rename(2)`, the file descriptor is invalidated on each write; the watcher **re-arms the
  file watch on every `.delete`/`.rename` event**, and watches the parent directory as a
  cold-start fallback for when the file doesn't exist yet. Runs on its own dispatch queue, hops
  to `@MainActor` to call `ingest`.
- **`MenuBarController`** — renders the `NSStatusItem` title (compact `S42% │ W67%`, kept narrow so
  it survives a crowded notched menu bar) and rebuilds the dropdown lazily in `menuNeedsUpdate`.
  A `⚠` prefix means stale/offline/auth-stale. Sets an `autosaveName` so the item's position
  persists across launches.
- **`Log`** — file logger at `~/Library/Logs/ClaudeCodeUsage/ccu.log` (rotates at ~1MB) plus
  `os.Logger`. Producer A logs separately to `bridge.log` in the state directory.

### Concurrency model

`StateStore` and `MenuBarController` are `@MainActor`. `StateFileWatcher` owns a serial dispatch
queue for kqueue handling and crosses to `@MainActor` only to ingest. `AppDelegate` wires
everything up and installs SIGTERM/SIGINT handlers that route to `NSApp.terminate`.

## Gotchas

- `LSUIElement` / `.accessory` activation policy — no Dock icon, menu-bar-only.
- Claude Code's `rate_limits` statusline JSON shape is undocumented and can change without
  notice. See README "Caveats".
- `rate_limits` only appears on Pro/Max plans, and only *after* the first API call in a session.
- `UsageSummaryStore.refresh()` (the token-usage card) does a synchronous scan of
  `~/.claude/projects/**/*.jsonl` on the main thread when the menu opens. It's cached by
  (size, mtime) per file, but the active session's file misses that cache on nearly every open.
  Known cost center for large transcript histories — see `ROBUSTNESS_FIXES.md` #2.
