![Claude Code Usage banner](assets/readme-banner.svg)

# Claude Code Usage — macOS Menu Bar

A minimal menu bar app that shows your Claude Code session and weekly usage
percentages at a glance. Sits next to the notch. No accounts, no telemetry,
no API charges.

> **Status:** v1, personal use. Relies on an **undocumented** Anthropic
> OAuth endpoint and on Claude Code's statusline JSON shape — both can
> break without notice. See [Caveats](#caveats).

## What it shows

Menu bar — compact, and color-coded as usage climbs (orange past 80%, red past
95%):

```
S42% │ W67%
```

Click for detail and actions:

```
Session   42%   resets in 2h 14m
Weekly    67%   resets Mon 12:00
─────────────────────────────────
Source: statusline · updated 12s ago
─────────────────────────────────
Refresh now
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

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Claude Code installed and signed in (Pro or Max plan — Free won't expose `rate_limits`)
- `jq` (`brew install jq`)
- Swift 5.9+ (ships with Xcode 15 or `xcode-select --install`)

## Install

### 1. Build the app

```bash
git clone <this repo>
cd CCUMenuBar
swift build -c release
./scripts/make-app.sh
```

The build produces `CCUMenuBar.app` in the repo root. The `make-app.sh` step
wraps the SwiftPM binary into a proper `.app` bundle with `Info.plist` and
ad-hoc code signing — required for `SMAppService` (Launch at login) to
register the app.

Launch it:

```bash
open CCUMenuBar.app
```

You should see `S --% │ W --%` in your menu bar until first data arrives.
Quit from the dropdown before continuing.

> First-launch Gatekeeper note: the binary is ad-hoc signed, not Developer
> ID signed. If macOS quarantines it, right-click → Open the first time.

### 2. Connect to Claude Code (Producer A)

The statusline bridge feeds usage data to the app while Claude Code is running.
The app installs it for you — no manual file copying.

On first launch the **Setup** window opens automatically. You can also reopen it
any time from the menu bar dropdown → **Setup…**. It has two buttons:

1. **Install** — copies the bridge script to `~/.claude/scripts`.
2. **Configure** — adds the `statusLine` command to `~/.claude/settings.json`.

Then restart Claude Code and run a command that hits the API. The Setup window's
third step turns green once data is flowing.

**Already have a statusline?** Setup preserves it. Your previous `statusLine`
command is saved to `~/.claude/scripts/ccu-inner-statusline`, and the bridge
chains to it — your existing HUD keeps working.

<details>
<summary>Manual install (if you'd rather not use the Setup window)</summary>

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

### 3. Verify

Restart Claude Code, run any command that hits the API (e.g., `claude "say hi"`),
then check:

```bash
cat "$HOME/Library/Application Support/ClaudeCodeUsage/state.json"
```

You should see populated `session` and `weekly` objects with a recent
`updated_at`. The menu bar should reflect the same numbers within a few seconds.

### 4. (Optional) Launch at login

In the dropdown menu, toggle **Launch at login**. macOS may prompt you to
approve it under System Settings → General → Login Items.

## How it works

Two independent data producers write to one shared state file:

```
~/Library/Application Support/ClaudeCodeUsage/state.json
```

- **Producer A — statusline bridge** (this repo's shell script). Fires when
  Claude Code is actively running. Data is fresh and free, but stops updating
  the moment you close Claude Code.
- **Producer B — OAuth poller** (inside the Mac app). Every 60 seconds, reads
  your OAuth token from `~/.claude/.credentials.json` and calls
  `https://api.anthropic.com/api/oauth/usage`. Works even when Claude Code
  is closed. **This endpoint is undocumented.**

Last write wins. The dropdown shows which producer fed the latest number and
how stale it is. If both fail, the menu bar shows `--%` and a "stale" warning
appears after 5 minutes.

Diagnostic logs land at `~/Library/Logs/ClaudeCodeUsage/ccu.log` (rotated at
~1 MB). Tail it to debug parse misses against the undocumented endpoint.

## Caveats

**Undocumented OAuth endpoint.** `/api/oauth/usage` was discovered by the
community. Anthropic has not committed to keeping its shape stable. There's
an open feature request to expose this data officially via the statusline
JSON and a `claude usage --json` command — when that ships, swap Producer B
for the official path.

**Statusline data only updates when Claude Code is running.** If you only
rely on Producer A, your menu bar freezes when you close Claude Code.
Producer B exists specifically to cover that gap.

**No absolute numbers.** Anthropic exposes percentages, not token/request
counts. You can't see "you have 12,432 tokens left." If you need that, this
app cannot give it to you — nobody can, until Anthropic ships the feature.

**Pro/Max only.** Free plan sessions don't include `rate_limits` in the
statusline JSON, and the OAuth `/usage` endpoint may also be plan-gated.

**Ad-hoc signed only.** No Developer ID signature, no notarization. Run from
your own build. If you move `CCUMenuBar.app` around, macOS Gatekeeper may
re-quarantine — right-click → Open the first time.

**No token refresh.** If the access token expires, the dropdown will show
"Auth expired — re-run `claude` to refresh." The poller backs off for 5
minutes and retries.

## Troubleshooting

**Menu bar shows `--%` forever.**
- Run a Claude Code command that actually hits the API (a bare `claude` prompt
  may not). Check `state.json` is being written.
- Look at `~/Library/Application Support/ClaudeCodeUsage/bridge.log` for
  Producer A errors and `~/Library/Logs/ClaudeCodeUsage/ccu.log` for
  Producer B errors.
- Confirm your plan exposes `rate_limits` by running `claude` and checking the
  raw statusline input — pipe a known-good fixture through the bridge to
  isolate whether the issue is the data or the script.

**Numbers don't match `/usage`.**
- `/usage` and Producer A both read the same upstream data; they should agree
  within seconds.
- Producer B polls every 60s. After a burst of activity, expect up to 60s of
  lag if Claude Code isn't running.

**App won't launch at login.**
- `SMAppService` requires the bundled `CCUMenuBar.app` (not the bare binary
  from `.build/`). Confirm you ran `./scripts/make-app.sh` and you're opening
  the `.app`, not the binary directly.
- macOS 13+ requires user approval per app. Check System Settings → General →
  Login Items → Allow in the Background. Toggle the app off and on in our
  dropdown to retrigger the prompt.

**Credentials file missing.**
- `~/.claude/.credentials.json` is created on `claude login`. If you've never
  signed in, Producer B will be silent. Producer A still works once you do.

**OAuth parse miss.**
- The endpoint shape is undocumented. If `ccu.log` shows `oauth usage parse
  miss` lines, the response keys we look for don't match what your account
  returns. Capture the raw body from the log and adjust the candidate-key
  lists in `Sources/CCUMenuBar/OAuthPoller.swift` (`extractPercent` /
  `extractResetsUnix` / `parseUsage`).

## Uninstall

```bash
# 1. Quit the app from the menu bar dropdown.
# 2. Remove the statusline bridge:
rm -f ~/.claude/scripts/ccu-statusline-bridge.sh
rm -f ~/.claude/scripts/ccu-inner-statusline
# Edit ~/.claude/settings.json to remove the "statusLine" key (or restore
# ~/.claude/settings.json.ccu-backup, the copy saved before Setup ran).

# 3. Remove app state and logs:
rm -rf "$HOME/Library/Application Support/ClaudeCodeUsage"
rm -rf "$HOME/Library/Logs/ClaudeCodeUsage"

# 4. If you registered launch at login:
#    System Settings → General → Login Items → remove Claude Code Usage.

# 5. Remove the bundled app:
rm -rf CCUMenuBar.app
```

## License

MIT. Personal-use tool. No warranty, especially around the undocumented
endpoint.
