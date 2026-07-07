# CCUMenuBar Robustness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the High and Medium severity issues from the 2026-06-10 audit: install-flow flapping, self-test state pollution, keychain hangs, silent setup holes, watchdog false positives, log spam, and poller data-loss edges.

**Architecture:** No structural changes — the two-producer/one-consumer design around `state.json` stays. Each fix hardens an existing component: the bash bridge gains a `CCU_STATE_DIR` override + log hygiene, `BridgeInstaller` gets deterministic jq resolution and an isolated self-test, `KeychainCredentials` gets bounded subprocess waits, `OAuthPoller` gets a resilient token walk and per-bucket merge, `BridgeWatchdog` gates alerts on real Claude Code activity.

**Tech Stack:** Swift 5.9 (SwiftPM, AppKit, no Xcode project), bash, XCTest. Test with `swift test`; build with `swift build`.

---

## Read this before starting

- **Git conventions (from CLAUDE.md — non-negotiable):** commit messages must NOT mention Claude, AI assistance, or contain `Co-Authored-By` trailers / "Generated with" footers. Author and committer must be `Roman Paslavskyi <46484914+paslavskyi9roman@users.noreply.github.com>`. Plain technical commit messages only.
- **CLAUDE.md says "no test target" — that's stale.** `Package.swift` declares `CCUMenuBarTests` and `Tests/CCUMenuBarTests/UsageSummaryTests.swift` exists. `swift test` is the test command.
- **jq is required on the dev machine** for the bridge-script tests. Each bridge test starts with `try XCTSkipUnless(BridgeInstaller.isJQAvailable)` so suites still pass without it.
- **The working tree is dirty** (the OAuth poller is being reintroduced; `OAuthPoller.swift` and `KeychainCredentials.swift` are untracked). Task 0 commits this baseline first so every later task produces a clean, single-purpose commit.
- Tests load the bridge script straight from the repo via `#filePath` (not `Bundle.module`) — testing resources of an executable target through `Bundle.module` is unreliable under `swift test`.

## File structure

| File | Change |
|---|---|
| `Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh` | Modify: `CCU_STATE_DIR` override (Task 1), log rotation + dedupe (Task 2) |
| `Sources/CCUMenuBar/BridgeInstaller.swift` | Modify: isolated self-test (Task 3), deterministic jq + normalized out-of-date check (Task 4), preserve statusLine siblings (Task 11) |
| `Sources/CCUMenuBar/KeychainCredentials.swift` | Modify: bounded subprocess waits, service-discovery cache, `scanTokens()` (Tasks 5, 6) |
| `Sources/CCUMenuBar/OAuthPoller.swift` | Modify: accurate idle log (Task 6), resilient token walk (Task 7), per-bucket fill (Task 8) |
| `Sources/CCUMenuBar/AppDelegate.swift` | Modify: always-refresh poller (Task 5), setup auto-open on unconfigured settings (Task 10) |
| `Sources/CCUMenuBar/BridgeWatchdog.swift` | Modify: gate conditions on transcript activity (Task 9) |
| `Sources/CCUMenuBar/ClaudeActivity.swift` | Create: transcript-activity probe (Task 9) |
| `Sources/CCUMenuBar/AppPaths.swift` | Modify: add `claudeProjectsDirectory` (Task 9) |
| `Sources/CCUMenuBar/UsageSummary.swift` | Modify: use `AppPaths.claudeProjectsDirectory` (Task 9) |
| `Tests/CCUMenuBarTests/BridgeScriptTests.swift` | Create (Tasks 1, 2) |
| `Tests/CCUMenuBarTests/BridgeInstallerTests.swift` | Create (Tasks 3, 4, 11) |
| `Tests/CCUMenuBarTests/KeychainCredentialsTests.swift` | Create (Task 5) |
| `Tests/CCUMenuBarTests/OAuthPollerTests.swift` | Create (Tasks 6, 7, 8) |
| `Tests/CCUMenuBarTests/ClaudeActivityTests.swift` | Create (Task 9) |

---

### Task 0: Commit the baseline

The working tree already contains the in-progress poller reintroduction. Commit it as-is so later tasks have clean diffs.

- [ ] **Step 1: Verify the tree builds and tests pass**

Run: `swift build && swift test`
Expected: `Build complete!` and all existing tests pass.

- [ ] **Step 2: Commit everything currently modified/untracked**

```bash
git add CLAUDE.md README.md Sources/CCUMenuBar Tests
git commit -m "Reintroduce OAuth poller with keychain credential support"
```

(Do not add `CCUMenuBar.app/`, `user-ccu.log`, or `docs/` — the first two are gitignored/log artifacts; the plan file gets committed at the end if the user wants it.)

---

### Task 1: Bridge `CCU_STATE_DIR` override

The bridge hardcodes the state directory. Give it an env override so the self-test (Task 3) and tests can run against a throwaway directory without touching live state.

**Files:**
- Modify: `Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh:29`
- Create: `Tests/CCUMenuBarTests/BridgeScriptTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CCUMenuBarTests/BridgeScriptTests.swift`:

```swift
import XCTest
@testable import CCUMenuBar

final class BridgeScriptTests: XCTestCase {
    /// The bridge script as checked into the repo, located relative to this
    /// test file. Bundle.module is unreliable for executable-target resources
    /// under `swift test`, so we go straight to the source tree.
    static var repoScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CCUMenuBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh")
    }

    /// Renders the script the way BridgeInstaller does: placeholder cleared so
    /// the script's runtime jq fallback resolves jq.
    func makeTempScript() throws -> URL {
        let raw = try String(contentsOf: Self.repoScriptURL, encoding: .utf8)
        let rendered = raw.replacingOccurrences(of: "@@JQ_PATH@@", with: "")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-bridge-test-\(UUID().uuidString).sh")
        try Data(rendered.utf8).write(to: url)
        return url
    }

    func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let canaryPayload = """
    {"rate_limits":{"five_hour":{"used_percentage":17.3,"resets_at":1700000000},\
    "seven_day":{"used_percentage":31.7,"resets_at":1700000000}}}
    """

    /// Runs the bridge with HOME pointed at a sandbox dir (so even a buggy
    /// script can't touch the real state directory) and CCU_STATE_DIR pointed
    /// at the dir we assert against.
    @discardableResult
    func runBridge(script: URL, stateDir: URL, home: URL, stdin: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["CCU_STATE_DIR"] = stateDir.path
        env["HOME"] = home.path
        p.environment = env
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func testStateDirOverrideIsHonored() throws {
        try XCTSkipUnless(BridgeInstaller.isJQAvailable, "bridge tests need jq")
        let script = try makeTempScript()
        let stateDir = try makeTempDir()
        let home = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: home)
        }

        let status = try runBridge(script: script, stateDir: stateDir,
                                   home: home, stdin: Self.canaryPayload)
        XCTAssertEqual(status, 0)

        let stateFile = stateDir.appendingPathComponent("state.json")
        let data = try Data(contentsOf: stateFile)
        let state = try JSONDecoder().decode(State.self, from: data)
        XCTAssertEqual(state.session?.usedPct ?? -1, 17.3, accuracy: 0.01)
        XCTAssertEqual(state.weekly?.usedPct ?? -1, 31.7, accuracy: 0.01)
        XCTAssertEqual(state.source, "statusline")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BridgeScriptTests/testStateDirOverrideIsHonored`
Expected: FAIL — `state.json` lands under the fake `$HOME/Library/Application Support/ClaudeCodeUsage/`, not in `stateDir`, so `Data(contentsOf:)` throws.

- [ ] **Step 3: Implement the override**

In `Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh`, replace line 29:

```bash
STATE_DIR="${HOME}/Library/Application Support/ClaudeCodeUsage"
```

with:

```bash
# CCU_STATE_DIR overrides the state directory. Used by the app's self-test to
# run the bridge against a throwaway directory without touching live state.
STATE_DIR="${CCU_STATE_DIR:-${HOME}/Library/Application Support/ClaudeCodeUsage}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BridgeScriptTests/testStateDirOverrideIsHonored`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh Tests/CCUMenuBarTests/BridgeScriptTests.swift
git commit -m "Add CCU_STATE_DIR override to statusline bridge"
```

---

### Task 2: Bridge log rotation and per-tick dedupe

`bridge.log` has no rotation, and two conditions log one line per statusline tick (sub-second cadence): "jq not found", and "deferred state write to oauth" — the latter is the *happy path* whenever the poller is running. Rotate at 512 KB and skip a line when it's identical to the previous one (ignoring the timestamp).

**Files:**
- Modify: `Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh`
- Test: `Tests/CCUMenuBarTests/BridgeScriptTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `BridgeScriptTests.swift`:

```swift
    func testDeferredWriteLogsOnlyOncePerStreak() throws {
        try XCTSkipUnless(BridgeInstaller.isJQAvailable, "bridge tests need jq")
        let script = try makeTempScript()
        let stateDir = try makeTempDir()
        let home = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: home)
        }

        // Pre-seed a fresh oauth state so the bridge defers its write.
        let oauthState = """
        {"session":{"used_pct":50,"resets_at_unix":1700000000},\
        "weekly":{"used_pct":60,"resets_at_unix":1700000000},\
        "source":"oauth","updated_at":"\(State.nowISO())"}
        """
        try Data(oauthState.utf8).write(to: stateDir.appendingPathComponent("state.json"))

        // Two ticks in the same deferred streak.
        try runBridge(script: script, stateDir: stateDir, home: home, stdin: Self.canaryPayload)
        try runBridge(script: script, stateDir: stateDir, home: home, stdin: Self.canaryPayload)

        let log = try String(contentsOf: stateDir.appendingPathComponent("bridge.log"),
                             encoding: .utf8)
        let deferredLines = log.split(separator: "\n").filter { $0.contains("deferred state write") }
        XCTAssertEqual(deferredLines.count, 1,
                       "identical consecutive log lines should be deduped, got:\n\(log)")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BridgeScriptTests/testDeferredWriteLogsOnlyOncePerStreak`
Expected: FAIL — two `deferred state write to oauth(age=…)` lines.

- [ ] **Step 3: Implement rotation + dedupe in the bridge**

In `ccu-statusline-bridge.sh`, directly after the `mkdir -p "${STATE_DIR}"` line, add:

```bash
# Rotate the bridge log past ~512 KB; keep one backup. Without this the log
# grows unbounded (the app's ccu.log rotates, this one never did).
if [[ -f "${LOG_FILE}" ]] && (( $(stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0) > 524288 )); then
  mv -f "${LOG_FILE}" "${LOG_FILE}.1"
fi

# Append a log line only when it differs from the previous line (timestamp
# ignored). Per-tick conditions — jq missing, deferring to fresh oauth state —
# would otherwise add one line per statusline tick, sub-second, forever.
log_changed() {
  local msg="$1"
  local last
  last="$(tail -n 1 "${LOG_FILE}" 2>/dev/null | sed 's/^\[[^]]*\] //')"
  [[ "${last}" == "${msg}" ]] && return 0
  echo "[${NOW_ISO}] ${msg}" >> "${LOG_FILE}"
}
```

Replace the jq-not-found line (currently line 107):

```bash
  echo "[${NOW_ISO}] jq not found; tried installed=${INSTALLED_JQ}, CCU_JQ=${CCU_JQ:-}, common locations. State.json not updated." >> "${LOG_FILE}"
```

with:

```bash
  log_changed "jq not found; tried installed=${INSTALLED_JQ}, CCU_JQ=${CCU_JQ:-}, common locations. State.json not updated."
```

Replace the deferred-write line (currently line 146):

```bash
        echo "[${NOW_ISO}] deferred state write to ${DEFER_REASON}" >> "${LOG_FILE}"
```

with (message must be constant or the dedupe never matches — the age varies every tick):

```bash
        log_changed "deferred state write to fresh oauth state"
```

`DEFER_REASON` is still used as the emptiness check; only the logged text changes.

- [ ] **Step 4: Run the bridge tests**

Run: `swift test --filter BridgeScriptTests`
Expected: both tests PASS (note: `NOW_ISO` is defined before any `log_changed` call site executes; bash resolves variables at call time, not definition time).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/Resources/ccu-statusline-bridge.sh Tests/CCUMenuBarTests/BridgeScriptTests.swift
git commit -m "Rotate bridge.log and dedupe repeated per-tick log lines"
```

---

### Task 3: Isolate the self-test from live state

`runSelfTest` currently pipes canary values (17.3/31.7) through the bridge into the **real** `state.json`. The kqueue watcher ingests the canary before the `defer` restores the file, and the restore then loses StateStore's last-write-wins (older `updated_at`) — so the menu bar shows fake numbers after every self-test. Run the self-test against a temp dir via `CCU_STATE_DIR` instead; refuse to run against an installed script too old to support it.

**Files:**
- Modify: `Sources/CCUMenuBar/BridgeInstaller.swift:22-49` (SelfTestResult), `:196-270` (runSelfTest + restore)
- Create: `Tests/CCUMenuBarTests/BridgeInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CCUMenuBarTests/BridgeInstallerTests.swift`:

```swift
import XCTest
@testable import CCUMenuBar

final class BridgeInstallerTests: XCTestCase {
    func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Renders the repo script like the installer does (placeholder cleared).
    func renderScript(to dir: URL) throws -> URL {
        let raw = try String(contentsOf: BridgeScriptTests.repoScriptURL, encoding: .utf8)
        let rendered = raw.replacingOccurrences(of: "@@JQ_PATH@@", with: "")
        let url = dir.appendingPathComponent("ccu-statusline-bridge.sh")
        try Data(rendered.utf8).write(to: url)
        return url
    }

    func testSelfTestPassesWithoutTouchingLiveState() throws {
        try XCTSkipUnless(BridgeInstaller.isJQAvailable, "self-test needs jq")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try renderScript(to: dir)

        let liveState = AppPaths.stateFile
        let before = try? Data(contentsOf: liveState)

        let result = BridgeInstaller.runSelfTest(scriptURL: script)

        XCTAssertEqual(result, .passed, result.summary)
        let after = try? Data(contentsOf: liveState)
        XCTAssertEqual(before, after, "self-test must not modify the live state.json")
    }

    func testSelfTestRejectsScriptWithoutStateDirSupport() throws {
        try XCTSkipUnless(BridgeInstaller.isJQAvailable, "self-test needs jq")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A pre-CCU_STATE_DIR script: would write straight to the live dir.
        let oldScript = dir.appendingPathComponent("old-bridge.sh")
        try Data("#!/usr/bin/env bash\nexit 0\n".utf8).write(to: oldScript)

        XCTAssertEqual(BridgeInstaller.runSelfTest(scriptURL: oldScript), .scriptOutdated)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BridgeInstallerTests`
Expected: FAIL — `runSelfTest(scriptURL:)` doesn't exist yet (compile error), and `.scriptOutdated` is not a case.

- [ ] **Step 3: Rewrite SelfTestResult and runSelfTest**

In `BridgeInstaller.swift`, add the new case to `SelfTestResult` (after `case jqMissing`):

```swift
    case scriptOutdated
```

and to its `summary` switch (after the `.jqMissing` case):

```swift
        case .scriptOutdated:
            return "The installed bridge predates this app version. Reinstall it (step 1), then re-run."
```

Replace the whole `runSelfTest` (lines 196–252) and **delete** the now-unused `restore(_:to:)` helper (lines 254–270):

```swift
    /// Runs the bridge with a canary stdin payload against a throwaway state
    /// directory (the bridge's `CCU_STATE_DIR` override) and verifies the
    /// resulting state.json. Never touches the live state files — the kqueue
    /// watcher would otherwise ingest the canary, and the restore would lose
    /// StateStore's last-write-wins to the canary's newer timestamp.
    static func runSelfTest(scriptURL: URL = installedScript) -> SelfTestResult {
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else { return .notInstalled }
        guard isJQAvailable else { return .jqMissing }
        guard let body = try? String(contentsOf: scriptURL, encoding: .utf8),
              body.contains("CCU_STATE_DIR")
        else { return .scriptOutdated }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return .scriptFailed(exitCode: -1, stderr: "could not create temp dir: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = """
        {"rate_limits":{\
        "five_hour":{"used_percentage":\(canarySession),"resets_at":\(canaryResetsAt)},\
        "seven_day":{"used_percentage":\(canaryWeekly),"resets_at":\(canaryResetsAt)}\
        }}
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["CCU_STATE_DIR"] = tempDir.path
        process.environment = env
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return .scriptFailed(exitCode: -1, stderr: String(describing: error))
        }
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            return .scriptFailed(exitCode: process.terminationStatus, stderr: err)
        }

        let stateFile = tempDir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return .stateNotWritten
        }
        let gotSession = state.session?.usedPct ?? -1
        let gotWeekly = state.weekly?.usedPct ?? -1
        if abs(gotSession - canarySession) > 0.5 || abs(gotWeekly - canaryWeekly) > 0.5 {
            return .stateMismatch(
                "expected session≈\(canarySession) weekly≈\(canaryWeekly), got session=\(gotSession) weekly=\(gotWeekly)")
        }
        return .passed
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BridgeInstallerTests && swift build`
Expected: PASS, clean build (confirms no leftover references to the deleted `restore` helper).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/BridgeInstaller.swift Tests/CCUMenuBarTests/BridgeInstallerTests.swift
git commit -m "Run bridge self-test against an isolated state directory"
```

---

### Task 4: Deterministic jq resolution and PATH-independent out-of-date check

Seen in the field log: `jq=/opt/homebrew/bin/jq script_out_of_date=false` at 08:49, `jq=/usr/bin/jq script_out_of_date=true` at 08:53 — same machine, same script. `jqPath` searches `$PATH` first (varies between terminal and Finder launches), and `installedScriptIsOutOfDate` hashes a render with the current jq path baked in. Fix both: search fixed locations first, and normalize the `INSTALLED_JQ` line out of the comparison.

**Files:**
- Modify: `Sources/CCUMenuBar/BridgeInstaller.swift:76-101`
- Test: `Tests/CCUMenuBarTests/BridgeInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `BridgeInstallerTests.swift`:

```swift
    func testNormalizationErasesJQPathDifferences() {
        let a = "#!/bin/bash\nINSTALLED_JQ=\"/opt/homebrew/bin/jq\"\necho hi\n"
        let b = "#!/bin/bash\nINSTALLED_JQ=\"/usr/bin/jq\"\necho hi\n"
        XCTAssertEqual(BridgeInstaller.normalizedScriptBody(a),
                       BridgeInstaller.normalizedScriptBody(b),
                       "scripts differing only in the baked jq path are the same script")
    }

    func testNormalizationPreservesBodyDifferences() {
        let a = "#!/bin/bash\nINSTALLED_JQ=\"/usr/bin/jq\"\necho hi\n"
        let b = "#!/bin/bash\nINSTALLED_JQ=\"/usr/bin/jq\"\necho bye\n"
        XCTAssertNotEqual(BridgeInstaller.normalizedScriptBody(a),
                          BridgeInstaller.normalizedScriptBody(b))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BridgeInstallerTests`
Expected: FAIL — `normalizedScriptBody` doesn't exist (compile error).

- [ ] **Step 3: Implement normalization and fixed-order jq search**

In `BridgeInstaller.swift`, replace `installedScriptIsOutOfDate` (lines 76–82) with:

```swift
    /// True when an installed script is on disk but its body differs from the
    /// bundled version. The `INSTALLED_JQ="…"` line is normalized away first:
    /// it varies with launch context (terminal vs Finder PATH), and comparing
    /// it raw made this flag flap between launches of the *same* install —
    /// Setup would nag "Reinstall" forever. "Out of date" must mean the script
    /// body changed, not that the app saw a different PATH today.
    static var installedScriptIsOutOfDate: Bool {
        guard isScriptInstalled,
              let installed = try? String(contentsOf: installedScript, encoding: .utf8),
              let bundledData = renderedBundledScript(),
              let bundled = String(data: bundledData, encoding: .utf8)
        else { return false }
        return normalizedScriptBody(installed) != normalizedScriptBody(bundled)
    }

    static func normalizedScriptBody(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"(?m)^INSTALLED_JQ=".*"$"#,
            with: #"INSTALLED_JQ="@@NORMALIZED@@""#,
            options: .regularExpression)
    }
```

Replace `jqPath` (lines 88–101) with a fixed-order search (PATH only as a last resort, so the answer is launch-context independent on any standard setup):

```swift
    static var jqPath: String? {
        // Fixed, well-known locations first so the result doesn't depend on
        // how the app was launched (terminal PATH vs Finder PATH). $PATH is
        // only a fallback for unusual installs.
        let fixedDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let envDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen: Set<String> = []
        for dir in fixedDirs + envDirs where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("jq").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
```

The `sha256` helper in `BridgeInstaller` becomes unused after this change — delete it (`private static func sha256(_ data: Data)`, lines 139–141) and the now-unneeded `import CryptoKit` **only if** nothing else in the file uses CryptoKit (check before deleting the import).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BridgeInstallerTests && swift build`
Expected: PASS, clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/BridgeInstaller.swift Tests/CCUMenuBarTests/BridgeInstallerTests.swift
git commit -m "Make jq resolution and bridge out-of-date check launch-context independent"
```

---

### Task 5: Bounded keychain subprocess waits; no keychain work on the main thread

`runSecurity` has no timeout: an unanswered Keychain permission dialog blocks `waitUntilExit()` forever, silently killing the poller (and stranding a cooperative thread). Separately, "Reload now" calls `poller.canRefresh` → `dump-keychain` synchronously on the main actor — a beachball. Fix: hard timeout on the subprocess, cache service discovery, and drop the main-thread gate entirely (the poller already logs when idle).

**Files:**
- Modify: `Sources/CCUMenuBar/KeychainCredentials.swift`, `Sources/CCUMenuBar/OAuthPoller.swift:33-36`, `Sources/CCUMenuBar/AppDelegate.swift:35-43`
- Create: `Tests/CCUMenuBarTests/KeychainCredentialsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CCUMenuBarTests/KeychainCredentialsTests.swift`:

```swift
import XCTest
@testable import CCUMenuBar

final class KeychainCredentialsTests: XCTestCase {
    func testRunTimesOutOnHangingProcess() {
        let start = Date()
        let out = KeychainCredentials.run(
            executable: "/bin/sleep", args: ["30"], timeout: 1)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "a hung subprocess must not block past its timeout")
    }

    func testRunReturnsOutputForFastProcess() {
        let out = KeychainCredentials.run(
            executable: "/bin/echo", args: ["hello"], timeout: 5)
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainCredentialsTests`
Expected: FAIL — `run(executable:args:timeout:)` doesn't exist (compile error).

- [ ] **Step 3: Implement the bounded runner and discovery cache**

In `KeychainCredentials.swift`, replace `runSecurity` (lines 63–79) with:

```swift
    private final class PipeCollector { var data = Data() }

    /// Runs a subprocess with a hard timeout. The first keychain read after
    /// each rebuild pops a permission dialog (ad-hoc signing changes the app
    /// identity); if the user never answers it, an unbounded `waitUntilExit()`
    /// would block its thread forever — and the poller with it.
    static func run(executable: String, args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe() // swallow denied prompts, "item not found", etc.

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            return nil
        }

        // Drain stdout off-thread so a full pipe can't deadlock the child.
        let collector = PipeCollector()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collector.data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        drained.wait()
        guard !collector.data.isEmpty else { return nil }
        return String(data: collector.data, encoding: .utf8)
    }

    private static func runSecurity(_ args: [String]) -> String? {
        run(executable: "/usr/bin/security", args: args, timeout: 10)
    }
```

Add a discovery cache. Replace `discoverServices` (lines 34–49) with:

```swift
    private static let cacheLock = NSLock()
    private static var cachedServices: (expires: Date, services: [String])?
    private static let discoveryCacheTTL: TimeInterval = 15 * 60

    private static func discoverServices() -> [String] {
        cacheLock.lock()
        if let cached = cachedServices, cached.expires > Date() {
            defer { cacheLock.unlock() }
            return cached.services
        }
        cacheLock.unlock()

        // dump-keychain scans every item's metadata — too heavy to run on
        // every 60s poll, hence the cache. Failures aren't cached so a
        // transient denial retries on the next tick.
        guard let out = runSecurity(["dump-keychain"]) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        // Lines of interest: `    "svce"<blob>="Claude Code-credentials-9d32f0d7"`
        for line in out.split(separator: "\n") {
            guard let prefixRange = line.range(of: "\"svce\"<blob>=\"") else { continue }
            let tail = line[prefixRange.upperBound...]
            guard let endQuote = tail.firstIndex(of: "\"") else { continue }
            let svc = String(tail[..<endQuote])
            if svc.hasPrefix(servicePrefix), seen.insert(svc).inserted {
                result.append(svc)
            }
        }
        cacheLock.lock()
        cachedServices = (Date().addingTimeInterval(discoveryCacheTTL), result)
        cacheLock.unlock()
        return result
    }
```

Delete `hasAnyEntry()` (lines 30–32).

- [ ] **Step 4: Remove the main-thread gate**

In `OAuthPoller.swift`, delete the `canRefresh` property (lines 33–36).

In `AppDelegate.swift`, replace the `onRefresh` closure (lines 35–43) with:

```swift
        menuBar.onRefresh = { [weak self] in
            guard let self else { return }
            self.watcher.refreshNow()
            // The poller logs its own "idle: no credentials" — no need to
            // gate here, and the old gate ran `security dump-keychain`
            // synchronously on the main thread.
            self.poller.refreshNow()
        }
```

- [ ] **Step 5: Run tests and build**

Run: `swift test --filter KeychainCredentialsTests && swift build`
Expected: PASS; clean build confirms no remaining `canRefresh`/`hasAnyEntry` references.

- [ ] **Step 6: Commit**

```bash
git add Sources/CCUMenuBar/KeychainCredentials.swift Sources/CCUMenuBar/OAuthPoller.swift Sources/CCUMenuBar/AppDelegate.swift Tests/CCUMenuBarTests/KeychainCredentialsTests.swift
git commit -m "Bound keychain subprocess waits and keep keychain work off the main thread"
```

---

### Task 6: Accurate "poller idle" diagnostics

The idle log says `…/.credentials.json not found` even though the keychain was also checked — it misdirected the remote diagnosis of the field log. Log what was actually scanned.

**Files:**
- Modify: `Sources/CCUMenuBar/OAuthPoller.swift` (tick/loop/readAccessTokens), `Sources/CCUMenuBar/KeychainCredentials.swift:18-28`
- Test: `Tests/CCUMenuBarTests/OAuthPollerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CCUMenuBarTests/OAuthPollerTests.swift`:

```swift
import XCTest
@testable import CCUMenuBar

final class OAuthPollerTests: XCTestCase {
    func testIdleLogMessageReportsBothSources() {
        let scan = OAuthPoller.CredentialScan(
            tokens: [], fileExists: false, keychainServiceCount: 2)
        let msg = OAuthPoller.idleLogMessage(scan)
        XCTAssertTrue(msg.contains("not found"), msg)
        XCTAssertTrue(msg.contains("keychain entries=2"), msg)
    }

    func testIdleLogMessageDistinguishesTokenlessFile() {
        let scan = OAuthPoller.CredentialScan(
            tokens: [], fileExists: true, keychainServiceCount: 0)
        let msg = OAuthPoller.idleLogMessage(scan)
        XCTAssertTrue(msg.contains("present but no token"), msg)
        XCTAssertTrue(msg.contains("keychain entries=0"), msg)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OAuthPollerTests`
Expected: FAIL — `CredentialScan` / `idleLogMessage` don't exist (compile error).

- [ ] **Step 3: Implement the scan struct and message**

In `KeychainCredentials.swift`, replace `readAccessTokens()` (lines 18–28) with a variant that also reports how many services were seen:

```swift
    static func scanTokens() -> (tokens: [String], serviceCount: Int) {
        let services = discoverServices()
        var seen = Set<String>()
        var tokens: [String] = []
        for service in services {
            guard let token = accessToken(forService: service), !token.isEmpty else { continue }
            if seen.insert(token).inserted {
                tokens.append(token)
            }
        }
        return (tokens, services.count)
    }
```

In `OAuthPoller.swift`:

Add inside the class (near the top, after the static constants):

```swift
    struct CredentialScan {
        var tokens: [String]
        var fileExists: Bool
        var keychainServiceCount: Int
    }

    /// Names everything that was scanned. The old message mentioned only the
    /// legacy credentials file, which misdirects diagnosis when the real
    /// situation is "keychain entries exist but tokens were denied/unreadable".
    static func idleLogMessage(_ scan: CredentialScan) -> String {
        let file = scan.fileExists ? "present but no token" : "not found"
        return "oauth poller idle: credentials file \(file) (\(credentialsURL.path)), "
            + "keychain entries=\(scan.keychainServiceCount), no usable tokens"
    }
```

(`credentialsURL` is `private static` — relax it to `static` so the message helper compiles, or keep the helper non-static; keeping it `static let credentialsURL` with internal access is simplest.)

Replace `readAccessTokens()` (lines 150–160) with:

```swift
    private func readCredentials() -> CredentialScan {
        var seen = Set<String>()
        var tokens: [String] = []
        if let token = readAccessTokenFromFile(), seen.insert(token).inserted {
            tokens.append(token)
        }
        let keychain = KeychainCredentials.scanTokens()
        for token in keychain.tokens where seen.insert(token).inserted {
            tokens.append(token)
        }
        return CredentialScan(
            tokens: tokens,
            fileExists: FileManager.default.fileExists(atPath: Self.credentialsURL.path),
            keychainServiceCount: keychain.serviceCount)
    }
```

Replace `tick()` (lines 82–105) so the idle log happens at the throw site with full context (the loop keeps only the backoff):

```swift
    private func tick() async throws {
        let scan = readCredentials()
        if scan.tokens.isEmpty {
            if !didLogNoCredentials {
                didLogNoCredentials = true
                Log.info(Self.idleLogMessage(scan))
            }
            throw PollError.noCredentials
        }
        // Keychain retains tokens for old profiles whose servers will 401;
        // walk every token before giving up.
        var lastError: Error = PollError.authStale
        for (index, token) in scan.tokens.enumerated() {
            do {
                try await tick(withToken: token)
                if index > 0 {
                    Log.info("oauth refresh succeeded with credential #\(index + 1) of \(scan.tokens.count)")
                }
                return
            } catch PollError.authStale {
                lastError = PollError.authStale
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }
```

And in `loop()`, the `noCredentials` catch shrinks to just the backoff:

```swift
            } catch PollError.noCredentials {
                nextDelay = Self.backoffNoCredentials
            }
```

- [ ] **Step 4: Run tests and build**

Run: `swift test --filter OAuthPollerTests && swift build`
Expected: PASS, clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/OAuthPoller.swift Sources/CCUMenuBar/KeychainCredentials.swift Tests/CCUMenuBarTests/OAuthPollerTests.swift
git commit -m "Report file and keychain scan results when the oauth poller idles"
```

---

### Task 7: Token walk survives transient errors

In the token walk, only `authStale` advances to the next credential — a network blip or parse error on token #1 hides a working token #2. Extract the walk into a testable helper where **any** failure tries the next token.

**Files:**
- Modify: `Sources/CCUMenuBar/OAuthPoller.swift` (tick)
- Test: `Tests/CCUMenuBarTests/OAuthPollerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `OAuthPollerTests.swift`:

```swift
    struct StubError: Error, Equatable { let id: Int }

    func testWalkTokensSucceedsAfterTransientFailure() async throws {
        var attempts: [String] = []
        try await OAuthPoller.walkTokens(["a", "b"]) { token in
            attempts.append(token)
            if token == "a" { throw StubError(id: 1) } // not an auth error
        }
        XCTAssertEqual(attempts, ["a", "b"])
    }

    func testWalkTokensThrowsLastErrorWhenAllFail() async {
        do {
            try await OAuthPoller.walkTokens(["a", "b"]) { _ in throw StubError(id: 7) }
            XCTFail("expected throw")
        } catch let error as StubError {
            XCTAssertEqual(error.id, 7)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OAuthPollerTests`
Expected: FAIL — `walkTokens` doesn't exist (compile error).

- [ ] **Step 3: Implement walkTokens and use it in tick()**

In `OAuthPoller.swift`, add:

```swift
    /// Tries each token in order; returns on the first success. Any failure —
    /// auth, transport, parse — moves on to the next token, so one dead
    /// profile or a transient network error can't mask a working credential
    /// later in the list.
    static func walkTokens(_ tokens: [String],
                           attempt: (String) async throws -> Void) async throws {
        var lastError: Error = PollError.authStale
        for (index, token) in tokens.enumerated() {
            do {
                try await attempt(token)
                if index > 0 {
                    Log.info("oauth refresh succeeded with credential #\(index + 1) of \(tokens.count)")
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
```

Replace the walk inside `tick()` (everything after the idle check from Task 6) so the whole method reads:

```swift
    private func tick() async throws {
        let scan = readCredentials()
        if scan.tokens.isEmpty {
            if !didLogNoCredentials {
                didLogNoCredentials = true
                Log.info(Self.idleLogMessage(scan))
            }
            throw PollError.noCredentials
        }
        try await Self.walkTokens(scan.tokens) { try await self.tick(withToken: $0) }
    }
```

Note on backoff semantics: `loop()` already distinguishes `authStale` (5-min backoff) from other errors (60s retry). With `walkTokens` throwing the *last* error, a mixed walk ending in `authStale` backs off 5 minutes — correct, since every token was tried.

- [ ] **Step 4: Run tests and build**

Run: `swift test --filter OAuthPollerTests && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/OAuthPoller.swift Tests/CCUMenuBarTests/OAuthPollerTests.swift
git commit -m "Try every oauth credential regardless of failure type"
```

---

### Task 8: OAuth partial responses don't clobber the other bucket

`parseUsage` accepts a response containing only one bucket, and the poller then **replaces** the whole `State` — wiping a weekly value the bridge just wrote (and the bridge defers for 120 s afterwards, so the gap sticks). Fill missing buckets from the existing state when it's still fresh.

**Files:**
- Modify: `Sources/CCUMenuBar/OAuthPoller.swift:136-143` (tick(withToken:))
- Test: `Tests/CCUMenuBarTests/OAuthPollerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `OAuthPollerTests.swift`:

```swift
    func testFillUsesFreshExistingForMissingBucket() {
        let existing = State(
            session: Bucket(usedPct: 10, resetsAtUnix: 1),
            weekly: Bucket(usedPct: 20, resetsAtUnix: 2),
            source: "statusline",
            updatedAt: State.nowISO())
        let r = OAuthPoller.fillMissingBuckets(
            session: Bucket(usedPct: 42, resetsAtUnix: 3), weekly: nil, from: existing)
        XCTAssertEqual(r.session?.usedPct, 42)
        XCTAssertEqual(r.weekly?.usedPct, 20, "missing weekly should come from fresh existing state")
    }

    func testFillIgnoresStaleExisting() {
        let stale = State(
            session: Bucket(usedPct: 10, resetsAtUnix: 1),
            weekly: Bucket(usedPct: 20, resetsAtUnix: 2),
            source: "statusline",
            updatedAt: "2020-01-01T00:00:00Z")
        let r = OAuthPoller.fillMissingBuckets(session: nil, weekly: nil, from: stale)
        XCTAssertNil(r.session)
        XCTAssertNil(r.weekly)
    }

    func testFillHandlesNilExisting() {
        let r = OAuthPoller.fillMissingBuckets(
            session: Bucket(usedPct: 5, resetsAtUnix: 9), weekly: nil, from: nil)
        XCTAssertEqual(r.session?.usedPct, 5)
        XCTAssertNil(r.weekly)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OAuthPollerTests`
Expected: FAIL — `fillMissingBuckets` doesn't exist (compile error).

- [ ] **Step 3: Implement the fill and wire it into the write**

In `OAuthPoller.swift`, add:

```swift
    /// The usage endpoint may return only one bucket. Replacing the whole
    /// state would clobber a bucket the statusline bridge had just written —
    /// and the bridge then defers to the oauth state for 120s, so the loss
    /// sticks. Fill gaps from the existing state while it's still fresh.
    static func fillMissingBuckets(session: Bucket?, weekly: Bucket?, from existing: State?)
        -> (session: Bucket?, weekly: Bucket?)
    {
        guard let existing, !existing.isStale else { return (session, weekly) }
        return (session ?? existing.session, weekly ?? existing.weekly)
    }
```

In `tick(withToken:)`, replace the state construction and write (currently lines 136–143):

```swift
        let newState = State(
            session: parsed.session,
            weekly: parsed.weekly,
            source: "oauth",
            updatedAt: State.nowISO()
        )
        await MainActor.run { store.writeAndStore(newState) }
        Log.info("oauth refresh succeeded session=\(formatPct(parsed.session?.usedPct)) weekly=\(formatPct(parsed.weekly?.usedPct))")
```

with:

```swift
        let written: State = await MainActor.run {
            let filled = Self.fillMissingBuckets(
                session: parsed.session, weekly: parsed.weekly, from: store.state)
            let newState = State(
                session: filled.session,
                weekly: filled.weekly,
                source: "oauth",
                updatedAt: State.nowISO()
            )
            store.writeAndStore(newState)
            return newState
        }
        Log.info("oauth refresh succeeded session=\(formatPct(written.session?.usedPct)) weekly=\(formatPct(written.weekly?.usedPct))")
```

- [ ] **Step 4: Run tests and build**

Run: `swift test --filter OAuthPollerTests && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/OAuthPoller.swift Tests/CCUMenuBarTests/OAuthPollerTests.swift
git commit -m "Preserve fresh buckets when the oauth response is partial"
```

---

### Task 9: Watchdog alerts only when Claude Code is actually in use

`stoppedReporting` fires whenever the heartbeat is >30 min old — i.e. every time the user simply closes Claude Code for half an hour, and again one minute after every app launch (the field log shows exactly this). Gate both conditions on evidence of recent Claude Code activity: transcript files under `~/.claude/projects` modified within the relevant window.

**Files:**
- Create: `Sources/CCUMenuBar/ClaudeActivity.swift`
- Modify: `Sources/CCUMenuBar/AppPaths.swift`, `Sources/CCUMenuBar/BridgeWatchdog.swift:118-129`, `Sources/CCUMenuBar/UsageSummary.swift:49`
- Create: `Tests/CCUMenuBarTests/ClaudeActivityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CCUMenuBarTests/ClaudeActivityTests.swift`:

```swift
import XCTest
@testable import CCUMenuBar

final class ClaudeActivityTests: XCTestCase {
    func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDetectsRecentTranscript() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("session.jsonl"))

        XCTAssertTrue(ClaudeActivity.hasTranscriptActivity(
            since: Date().addingTimeInterval(-60), in: dir))
    }

    func testIgnoresOldTranscripts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("old.jsonl")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)

        XCTAssertFalse(ClaudeActivity.hasTranscriptActivity(
            since: Date().addingTimeInterval(-60), in: dir))
    }

    func testIgnoresNonTranscriptFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        XCTAssertFalse(ClaudeActivity.hasTranscriptActivity(
            since: Date().addingTimeInterval(-60), in: dir))
    }

    func testMissingDirectoryIsQuiet() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccu-does-not-exist-\(UUID().uuidString)")
        XCTAssertFalse(ClaudeActivity.hasTranscriptActivity(since: .distantPast, in: missing))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeActivityTests`
Expected: FAIL — `ClaudeActivity` doesn't exist (compile error).

- [ ] **Step 3: Implement ClaudeActivity and the shared path**

Add to `AppPaths.swift` (after `claudeCredentialsFile`):

```swift
    /// Claude Code's session transcripts. Mtimes here are the cheapest signal
    /// for "is Claude Code actually being used right now".
    static let claudeProjectsDirectory = claudeDirectory
        .appendingPathComponent("projects", isDirectory: true)
```

Create `Sources/CCUMenuBar/ClaudeActivity.swift`:

```swift
import Foundation

/// Probe for "has Claude Code actually been used recently?" — lets the bridge
/// watchdog separate "user closed Claude Code" (normal, stay quiet) from
/// "Claude Code is active but the bridge stopped reporting" (regression,
/// worth an alert).
enum ClaudeActivity {
    /// True when any session transcript under `directory` was modified after
    /// `since`. Early-exits on the first hit, so the common "actively using
    /// Claude Code" case stays cheap even with a large projects tree.
    static func hasTranscriptActivity(
        since: Date,
        in directory: URL = AppPaths.claudeProjectsDirectory
    ) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            if let modified = values?.contentModificationDate, modified > since {
                return true
            }
        }
        return false
    }
}
```

In `UsageSummary.swift`, change the `UsageSummaryStore` init default (line 49) to reuse the constant:

```swift
    init(projectsDirectory: URL = AppPaths.claudeProjectsDirectory) {
```

- [ ] **Step 4: Run the activity tests**

Run: `swift test --filter ClaudeActivityTests`
Expected: PASS.

- [ ] **Step 5: Gate the watchdog conditions**

In `BridgeWatchdog.swift`, replace `currentCondition()` (lines 118–129) with:

```swift
    private func currentCondition() -> Condition? {
        let bridge = BridgeStatus.read()
        if bridge == nil {
            guard Date().timeIntervalSince(bootDate) > firstHeartbeatGrace else { return nil }
            // No heartbeat ever — only a regression if Claude Code has
            // actually been used since this app booted. Otherwise the user
            // simply hasn't opened Claude Code; "restart Claude Code" would
            // be noise. The activity scan only runs once the grace period is
            // already blown, so the steady state stays cheap.
            guard ClaudeActivity.hasTranscriptActivity(since: bootDate) else { return nil }
            return .neverInvoked
        }
        if let age = bridge?.ageSeconds, age > heartbeatTimeout {
            // Heartbeat stale — distinguish "user closed Claude Code" (normal,
            // fires on every lunch break) from "Claude Code in use yet the
            // bridge stopped" (real regression).
            let activityWindow = Date().addingTimeInterval(-heartbeatTimeout)
            guard ClaudeActivity.hasTranscriptActivity(since: activityWindow) else { return nil }
            return .stoppedReporting
        }
        return nil
    }
```

- [ ] **Step 6: Run full test suite and build**

Run: `swift test && swift build`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CCUMenuBar/ClaudeActivity.swift Sources/CCUMenuBar/AppPaths.swift Sources/CCUMenuBar/BridgeWatchdog.swift Sources/CCUMenuBar/UsageSummary.swift Tests/CCUMenuBarTests/ClaudeActivityTests.swift
git commit -m "Gate bridge watchdog alerts on recent Claude Code activity"
```

---

### Task 10: Auto-open Setup when settings.json isn't wired up

`showSetupOnFirstRun` only checks the script; the watchdog deliberately stays silent when settings are unconfigured *assuming AppDelegate covers it* — so "script installed, statusLine missing" is a silent dead state with no Setup window, no watchdog, no data, forever.

**Files:**
- Modify: `Sources/CCUMenuBar/AppDelegate.swift:87-95`

- [ ] **Step 1: Implement the broader check**

Replace `showSetupOnFirstRun` (lines 87–95):

```swift
    /// Auto-open Setup whenever setup is incomplete — script missing OR
    /// settings.json not pointing at it. The watchdog deliberately stays
    /// silent while setup is incomplete on the assumption that this method
    /// covers it; checking only the script left "installed but never
    /// configured" (user closed Setup early, or Claude Code rewrote its
    /// settings) as a silent dead state.
    private func showSetupOnFirstRun() {
        if !BridgeInstaller.isScriptInstalled || !BridgeInstaller.isSettingsConfigured {
            setupWindow.show()
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Manual verification**

```bash
# Back up, then strip the statusLine key to simulate the dead state:
cp ~/.claude/settings.json /tmp/settings.json.bak
jq 'del(.statusLine)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
swift run CCUMenuBar   # expect: Setup window opens automatically
# Ctrl-C, then restore:
mv /tmp/settings.json.bak ~/.claude/settings.json
```

Expected: Setup window appears on launch even though the script is installed.

- [ ] **Step 4: Commit**

```bash
git add Sources/CCUMenuBar/AppDelegate.swift
git commit -m "Open Setup automatically when settings.json lacks the bridge statusline"
```

---

### Task 11: Preserve sibling keys in the statusLine settings entry

`configureSettings` replaces the whole `statusLine` dict — a user's `padding` (or any future key) silently vanishes. Merge instead of replace.

**Files:**
- Modify: `Sources/CCUMenuBar/BridgeInstaller.swift:143-182`
- Test: `Tests/CCUMenuBarTests/BridgeInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `BridgeInstallerTests.swift`:

```swift
    func testConfiguredSettingsPreservesStatusLineSiblings() {
        let root: [String: Any] = [
            "statusLine": ["type": "command", "command": "my-old-statusline", "padding": 0],
            "model": "opus",
        ]
        let out = BridgeInstaller.settingsWithBridgeConfigured(root)
        let statusLine = out["statusLine"] as? [String: Any]
        XCTAssertEqual(statusLine?["padding"] as? Int, 0, "sibling keys must survive")
        XCTAssertEqual(statusLine?["type"] as? String, "command")
        XCTAssertEqual(out["model"] as? String, "opus")
        let command = statusLine?["command"] as? String ?? ""
        XCTAssertTrue(command.contains("ccu-statusline-bridge.sh"), command)
    }

    func testConfiguredSettingsCreatesStatusLineWhenAbsent() {
        let out = BridgeInstaller.settingsWithBridgeConfigured([:])
        let statusLine = out["statusLine"] as? [String: Any]
        XCTAssertEqual(statusLine?["type"] as? String, "command")
        XCTAssertTrue((statusLine?["command"] as? String ?? "").contains("ccu-statusline-bridge.sh"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BridgeInstallerTests`
Expected: FAIL — `settingsWithBridgeConfigured` doesn't exist (compile error).

- [ ] **Step 3: Implement the pure transform and use it**

In `BridgeInstaller.swift`, add:

```swift
    /// Pure transform applied to the parsed settings.json root. Merges the
    /// bridge into an existing `statusLine` dict instead of replacing it, so
    /// sibling keys (`padding`, anything Claude Code adds later) survive.
    static func settingsWithBridgeConfigured(_ root: [String: Any]) -> [String: Any] {
        var root = root
        var statusLine = (root["statusLine"] as? [String: Any]) ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = "bash \"\(installedScript.path)\""
        root["statusLine"] = statusLine
        return root
    }
```

In `configureSettings()`, replace (lines 168–171):

```swift
        root["statusLine"] = [
            "type": "command",
            "command": "bash \"\(installedScript.path)\"",
        ]
```

with:

```swift
        root = settingsWithBridgeConfigured(root)
```

- [ ] **Step 4: Run tests and build**

Run: `swift test --filter BridgeInstallerTests && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUMenuBar/BridgeInstaller.swift Tests/CCUMenuBarTests/BridgeInstallerTests.swift
git commit -m "Preserve existing statusLine keys when configuring settings.json"
```

---

### Task 12: Full verification pass

- [ ] **Step 1: Run everything**

Run: `swift test && swift build -c release && ./scripts/make-app.sh`
Expected: all tests pass, release bundle builds.

- [ ] **Step 2: Manual smoke test against the real app**

1. `open ./CCUMenuBar.app` (quit any running instance first — `pkill -x CCUMenuBar`).
2. Open Setup → script shows "Reinstall" (the bridge body changed in Tasks 1–2) → click **Reinstall**, then **Run test**.
3. Expected: self-test passes **and the menu bar does NOT flash 17%/32%** (Task 3's whole point).
4. Quit and relaunch the app from Finder, then from a terminal (`open ./CCUMenuBar.app`): `script_out_of_date` must stay `false` in `~/Library/Logs/ClaudeCodeUsage/ccu.log` boot lines in both cases (Task 4's whole point).
5. Click "Reload now" with no Claude Code running — no beachball, and `ccu.log` gains a single accurate idle line naming both the file and keychain counts.

- [ ] **Step 3: Verify commit hygiene**

Run: `git log --format='%an %ae%n%b' -12 | grep -iE 'claude|generated|co-authored' || echo CLEAN`
Expected: `CLEAN`

---

## Self-review notes

- **Coverage:** H-flapping→Task 4, H-self-test→Tasks 1+3, H-keychain-hang→Task 5, H-setup-hole→Task 10, H-watchdog-noise→Task 9, M-idle-log→Task 6, M-log-spam→Task 2, M-bucket-clobber→Task 8, M-token-walk→Task 7, M-statusLine-siblings→Task 11.
- **Known interaction:** Task 6 rewrites `tick()` with the old walk inline; Task 7 then replaces that walk with `walkTokens`. Both show the complete method, so executing them in order (or reading either in isolation) is safe.
- **Out of scope (documented, deliberate):** the settings.json read-modify-write race with Claude Code (low likelihood, needs file locking), `install.sh` killing a stale running instance, and the CLAUDE.md "no test target" doc fix — all Low severity in the audit.
