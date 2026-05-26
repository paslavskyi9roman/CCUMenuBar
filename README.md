![Claude Code Usage banner](assets/readme-banner.svg)

# Claude Code Usage — macOS Menu Bar

A minimal menu bar app that shows your Claude Code session and weekly usage
percentages at a glance. Sits next to the notch. No accounts, no telemetry,
no API charges.

> **Status:** v1, personal use. Relies on Claude Code's statusline JSON
> shape, which is uncontracted — it can change without notice. See
> [Caveats](#caveats).

## What it shows

Menu bar — compact, and color-coded as usage climbs (orange past 80%, red past
95%):

```
S42% │ W67%
```

Click for detail and actions:

```
Today tokens 37M          30d tokens     875M
Latest tokens 81.2K
▇▇▅▂▁▂▂▃▃▃▅█▅▄▁▃▇▄▂▂▁▃
Top model: claude-opus-4-7
─────────────────────────────────
Session   42%   resets in 2h 14m
Weekly    67%   resets Mon 12:00
─────────────────────────────────
Updated 12s ago
─────────────────────────────────
Reload now
Reveal logs in Finder
─────────────────────────────────
Setup…
Preferences…
Launch at login   ☐
─────────────────────────────────
Quit
```

**Preferences** lets you tune the warning/critical thresholds and toggle the
usage notifications and their sound.

## Usage alerts

The app posts a macOS notification when session or weekly usage first crosses
80%, and again at 95% — a heads-up before you hit a limit. Each alert fires
once per reset window. macOS asks for notification permission on first launch;
alerts only work from the built `.app` bundle, not `swift run`.

**Quiet hours.** Preferences has a "Quiet hours" toggle and a time window
(default 22:00–08:00). Alerts that would fire during those hours are
suppressed and instead deliver on the next state update once the window
ends — delayed heads-up rather than a 3 AM ping.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Claude Code installed and signed in (Pro or Max plan — Free won't expose `rate_limits`)
- `jq` (`brew install jq`)
- Swift 5.9+ (ships with Xcode 15 or `xcode-select --install`)

## Install

```bash
git clone <this repo>
cd CCUMenuBar
./scripts/install.sh
```

`install.sh` checks for `swift` and `jq`, runs `swift build -c release`,
wraps the binary into an ad-hoc-signed `CCUMenuBar.app` via `make-app.sh`,
and launches it. The Setup window then opens automatically.

> Locally-built apps don't get a `com.apple.quarantine` xattr, so Gatekeeper
> doesn't prompt. If you ever move the `.app` to another machine via
> AirDrop / Slack / etc., right-click → Open the first time on that machine.

### Connect to Claude Code

The Setup window walks you through four steps:

1. **Install** — copies the statusline bridge to `~/.claude/scripts/`. The
   absolute path to your `jq` is baked into the script at this point so the
   bridge survives Claude Code's stripped PATH at runtime.
2. **Configure** — adds the `statusLine` command to `~/.claude/settings.json`.
   Any existing `statusLine` is preserved (see "Already have a statusline?"
   below).
3. **Verify jq dependency** — auto-checked; turns green when `jq` is on PATH.
4. **Run bridge self-test** — pipes a canary payload through the installed
   script and verifies `state.json` reflects it. Catches stripped-PATH
   issues, broken permissions, or jq problems before you ever start `claude`.

Then restart Claude Code and run a command. The fifth step ("Restart Claude
Code, then run a command") turns green once real data arrives.

**Already have a statusline?** Setup preserves it. Your previous `statusLine`
command is saved to `~/.claude/scripts/ccu-inner-statusline`, and the bridge
chains to it — your existing HUD keeps working. You can also set
`CCU_INNER_STATUSLINE` in your shell profile, which takes precedence over
the sidecar file.

**App updated?** The Setup window shows "Reinstall recommended" when the
bundled bridge differs from the one installed on disk (script body changed,
or your `jq` moved). One click and you're current.

<details>
<summary>Manual install (if you'd rather not use the Setup window)</summary>

You'll lose the install-time `jq` path bake — the script falls through to
its runtime fallback list (`$CCU_JQ`, common Homebrew locations, `command -v
jq`). Usually fine, but the Setup window catches edge cases the manual path
can't.

```bash
mkdir -p ~/.claude/scripts
cp Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh \
   ~/.claude/scripts/ccu-statusline-bridge.sh
chmod +x ~/.claude/scripts/ccu-statusline-bridge.sh
```

Add to `~/.claude/settings.json` (merge with existing settings):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/scripts/ccu-statusline-bridge.sh"
  }
}
```

To chain an existing statusline, either set `CCU_INNER_STATUSLINE` to its
command in your shell profile, or write that command to
`~/.claude/scripts/ccu-inner-statusline`.
</details>

### Verify

Restart Claude Code, run any command that hits the API (e.g., `claude "say hi"`),
then check:

```bash
cat "$HOME/Library/Application Support/ClaudeCodeUsage/state.json"
```

You should see populated `session` and `weekly` objects with a recent
`updated_at`. The menu bar should reflect the same numbers within a few seconds.

### (Optional) Launch at login

In the dropdown menu, toggle **Launch at login**. macOS may prompt you to
approve it under System Settings → General → Login Items.

### (Optional) `ccu` CLI

A tiny shell helper at `scripts/ccu` reads `state.json` and prints the same
compact summary the menu bar shows — useful for shell prompts, tmux,
Raycast, etc. Symlink it into your `PATH`:

```bash
ln -s "$(pwd)/scripts/ccu" /usr/local/bin/ccu
ccu        # → "S42% │ W67%"
ccu json   # → raw state.json
```

See [The `state.json` interface](#the-statejson-interface) for the schema
and integration examples.

## How it works

A single shell script — the **statusline bridge** — is the data source.
Claude Code calls it on each statusline tick, the bridge extracts
`rate_limits` from the session JSON, transforms it with `jq`, and writes:

```
~/Library/Application Support/ClaudeCodeUsage/state.json          # rate_limits
~/Library/Application Support/ClaudeCodeUsage/bridge-status.json  # heartbeat
```

The app watches `state.json` with kqueue and renders. `bridge-status.json`
is a sibling file the bridge updates on **every** invocation — even when
`rate_limits` is null — so the app can tell apart "Claude Code never
called the bridge" from "called it, but no `rate_limits` in the payload
yet." Both files are written via `rename(2)` for atomicity; no partial
reads.

The bridge only fires while Claude Code is running, so the menu bar
freezes at the last known values when you close it. A "stale" indicator
appears after 5 minutes.

Diagnostic logs:

- `~/Library/Logs/ClaudeCodeUsage/ccu.log` — app side (rotated at ~1 MB)
- `~/Library/Application Support/ClaudeCodeUsage/bridge.log` — bridge errors
  (written only on failure; an empty file means no errors)

## The `state.json` interface

`state.json` is a **documented, stable interface** — other tools can read it
without touching the app. The file is at:

```
~/Library/Application Support/ClaudeCodeUsage/state.json
```

The bridge writes it via temp-file + `rename(2)`, so the file is always
either the previous contents or the new contents — never partial.

### Schema

```jsonc
{
  "session": {                          // or null when unknown
    "used_pct": 42.0,                   // 0-100; may be null
    "resets_at_unix": 1716494400        // unix seconds; may be null
  },
  "weekly": {                           // same shape; may be null
    "used_pct": 67.0,
    "resets_at_unix": 1716998400
  },
  "source": "statusline",               // always "statusline" (single producer)
  "updated_at": "2026-05-23T08:30:00Z"  // ISO-8601 UTC
}
```

### `bridge-status.json`

Heartbeat file written on every bridge invocation, alongside `state.json`:

```jsonc
{
  "schema_version": 1,
  "bridge_last_seen_at": "2026-05-23T08:30:00Z",  // ISO-8601 UTC
  "bridge_path": "/Users/you/Library/.../state.json",
  "rate_limits_present": true,                    // false = bridge ran, no payload
  "jq_path": "/opt/homebrew/bin/jq"               // resolved jq, useful for debugging
}
```

Use this to distinguish "bridge never ran" from "bridge ran but Claude Code
didn't include `rate_limits` this tick." The menu bar already surfaces both
states; this file is for external tooling that wants the same signal.

### `ccu` CLI

The `scripts/ccu` helper is a one-screen shell script. Subcommands:

```bash
ccu             # compact "S42% │ W67%" (the menu bar title)
ccu session     # session bucket JSON
ccu weekly      # weekly bucket JSON
ccu json        # full state.json
```

Example zsh prompt:

```sh
PROMPT='%~ %F{cyan}$(ccu 2>/dev/null)%f %# '
```

Example tmux status:

```
set -g status-right '#(ccu) | %H:%M'
```

### Stability

The schema is versioned by the field set, not a `version` key. Adding new
*optional* fields is non-breaking. Renaming, removing, or changing the
type of any existing field is a breaking change and would bump the
project's major version.

## Caveats

**Updates only while Claude Code is running.** The bridge fires on each
statusline tick. When you close Claude Code, the menu bar freezes at the
last known values and goes "stale" after 5 minutes.

**Uncontracted statusline JSON shape.** The `rate_limits` block in Claude
Code's statusline JSON isn't documented as stable. If Claude Code changes
the shape, the bridge's `jq` transform may produce nulls until updated.

**Local token numbers.** The summary card reads local Claude Code transcript
logs and displays only fields present in those logs. It does not estimate
billing or use an embedded pricing table. Anthropic does not expose
"you have 12,432 tokens left" style remaining limits.

**Pro/Max only.** Free plan sessions don't include `rate_limits` in the
statusline JSON. The bridge runs but `state.json` stays empty — the menu
bar's status row will say "Bridge active · waiting for rate_limits."

**Ad-hoc signed only.** No Developer ID signature, no notarization. Run from
your own build. Locally built apps don't have the quarantine attribute, so
Gatekeeper doesn't prompt — but if you move `CCUMenuBar.app` to another
machine, that machine will quarantine it on receipt.

## Troubleshooting

**Menu bar shows `--%` forever.** Start with the Setup window's
**Run bridge self-test** button — it pipes a known-good payload through the
installed script and verifies `state.json` round-trips. Three outcomes:

- **Self-test passes, menu still empty.** The bridge works. Claude Code isn't
  invoking it. Check that you're running `claude` interactively (not
  `claude --print`), that your `~/.claude/settings.json` actually contains
  the bridge in `statusLine.command`, and that no `~/.claude/settings.local.json`
  is overriding it.
- **Self-test fails with "jq isn't on PATH" or "Bridge exited N".** The
  script has an environment problem on this machine. Click **Reinstall** in
  Setup — this re-bakes the absolute `jq` path into the script.
- **Self-test passes, Setup's data step still red.** Open the menu bar
  dropdown. If the status row says "Bridge active · waiting for rate_limits",
  Claude Code is calling the bridge but not sending `rate_limits` (common on
  Free plan; Pro/Max only sends it after the first real API call in a
  session). Run `claude "say hi"` and wait a few seconds.

**Useful files to inspect:**
- `~/Library/Application Support/ClaudeCodeUsage/bridge-status.json` —
  heartbeat (last invocation timestamp, whether `rate_limits` was present)
- `~/Library/Application Support/ClaudeCodeUsage/bridge.log` — bridge errors;
  an empty file means no errors (not "didn't run")
- `~/Library/Logs/ClaudeCodeUsage/ccu.log` — app-side log

**App won't launch at login.**
- `SMAppService` requires the bundled `CCUMenuBar.app` (not the bare binary
  from `.build/`). Confirm you ran `./scripts/install.sh` (or
  `./scripts/make-app.sh` directly) and you're opening the `.app`, not the
  binary directly.
- macOS 13+ requires user approval per app. Check System Settings → General →
  Login Items → Allow in the Background. Toggle the app off and on in our
  dropdown to retrigger the prompt.

## Uninstall

```bash
# 1. Quit the app from the menu bar dropdown.
# 2. Remove the statusline bridge:
rm -f ~/.claude/scripts/ccu-statusline-bridge.sh
rm -f ~/.claude/scripts/ccu-inner-statusline
# Edit ~/.claude/settings.json to remove the "statusLine" key (or restore
# ~/.claude/settings.json.ccu-backup, the copy saved before Setup ran).

# 3. Remove app state and logs (state.json, bridge-status.json, bridge.log):
rm -rf "$HOME/Library/Application Support/ClaudeCodeUsage"
rm -rf "$HOME/Library/Logs/ClaudeCodeUsage"

# 4. Reset NSUserDefaults (status item position, etc.):
defaults delete com.ccu.menubar 2>/dev/null || true

# 5. If you registered launch at login:
#    System Settings → General → Login Items → remove Claude Code Usage.

# 6. Remove the bundled app:
rm -rf CCUMenuBar.app
```

## License

MIT. Personal-use tool. No warranty, especially around Claude Code's
uncontracted statusline JSON shape.
