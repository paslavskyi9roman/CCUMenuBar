import CryptoKit
import Darwin
import Foundation

enum BridgeInstallerError: LocalizedError {
    case bundledScriptMissing
    case settingsUnreadable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledScriptMissing:
            return "The bundled statusline script is missing from the app."
        case .settingsUnreadable:
            return "~/.claude/settings.json exists but isn't valid JSON. Fix or remove it, then retry."
        case .writeFailed(let detail):
            return "Couldn't write the change: \(detail)"
        }
    }
}

enum SelfTestResult: Equatable {
    case notInstalled
    case jqMissing
    case scriptFailed(exitCode: Int32, stderr: String)
    case stateNotWritten
    case stateMismatch(String)
    case passed

    var passed: Bool { self == .passed }

    var summary: String {
        switch self {
        case .notInstalled:
            return "Install the bridge first."
        case .jqMissing:
            return "jq isn't on PATH. Install with `brew install jq`."
        case .scriptFailed(let code, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Bridge exited \(code).\(trimmed.isEmpty ? "" : " stderr: \(trimmed)")"
        case .stateNotWritten:
            return "Bridge ran but state.json wasn't written. Check bridge.log for errors."
        case .stateMismatch(let detail):
            return "Bridge wrote state.json but the contents don't match the test payload: \(detail)"
        case .passed:
            return "Bridge self-test passed."
        }
    }
}

/// Producer A setup. Installs `ccu-statusline-bridge.sh` into `~/.claude/scripts`
/// and wires it into `~/.claude/settings.json` as the `statusLine` command. A
/// statusline the user already had is preserved: its command is written to a
/// sidecar file the bridge chains to.
enum BridgeInstaller {
    static let claudeDir = AppPaths.claudeDirectory
    static let scriptsDir = AppPaths.claudeScriptsDirectory
    static let installedScript = scriptsDir.appendingPathComponent("ccu-statusline-bridge.sh")
    static let innerSidecar = scriptsDir.appendingPathComponent("ccu-inner-statusline")
    static let settingsFile = AppPaths.claudeSettingsFile
    static let settingsBackup = claudeDir.appendingPathComponent("settings.json.ccu-backup")

    /// Substring that identifies our bridge inside a `statusLine` command.
    private static let scriptMarker = "ccu-statusline-bridge.sh"

    // MARK: - Status

    static var isScriptInstalled: Bool {
        FileManager.default.isReadableFile(atPath: installedScript.path)
    }

    /// True when an installed script is on disk but its body differs from the
    /// rendered bundled version we'd write now (script body changed in this
    /// release, or the resolved jq path moved on the user's machine). Used by
    /// Setup to nudge "Reinstall recommended."
    static var installedScriptIsOutOfDate: Bool {
        guard isScriptInstalled,
              let installed = try? Data(contentsOf: installedScript),
              let bundled = renderedBundledScript()
        else { return false }
        return sha256(installed) != sha256(bundled)
    }

    static var isSettingsConfigured: Bool {
        (currentStatusLineCommand() ?? "").contains(scriptMarker)
    }

    static var jqPath: String? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let searchDirs = envPaths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen: Set<String> = []
        for dir in searchDirs where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("jq").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var isJQAvailable: Bool {
        jqPath != nil
    }

    // MARK: - Actions

    static func installScript() throws {
        guard let data = renderedBundledScript() else {
            throw BridgeInstallerError.bundledScriptMissing
        }
        do {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try data.write(to: installedScript, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: installedScript.path)
        } catch {
            throw BridgeInstallerError.writeFailed(String(describing: error))
        }
    }

    /// Loads the bundled script and substitutes the `@@JQ_PATH@@` placeholder
    /// with the absolute jq path we discovered. The substitution is what makes
    /// the bridge survive Claude Code's stripped PATH — a bare `jq` call
    /// inside the spawned statusline process often can't find Homebrew's jq.
    private static func renderedBundledScript() -> Data? {
        guard let src = bundledScriptURL(),
              let raw = try? String(contentsOf: src, encoding: .utf8)
        else { return nil }
        // If jq wasn't found at install time, leave the placeholder cleared
        // out — the script's runtime fallback (common locations + command -v)
        // still has a chance to resolve it on the user's machine.
        let resolved = jqPath ?? ""
        let rendered = raw.replacingOccurrences(of: "@@JQ_PATH@@", with: resolved)
        return Data(rendered.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func configureSettings() throws {
        var root: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: settingsFile.path) {
            guard let data = try? Data(contentsOf: settingsFile) else {
                throw BridgeInstallerError.settingsUnreadable
            }
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw BridgeInstallerError.settingsUnreadable
                }
                root = parsed
            }
            // Preserve a pre-existing statusline by chaining the bridge to it.
            if let existing = root["statusLine"] as? [String: Any],
               let command = existing["command"] as? String,
               !command.contains(scriptMarker) {
                try writeInnerSidecar(command)
            }
            // Back up the user's pristine file once, before we ever touch it.
            if !FileManager.default.fileExists(atPath: settingsBackup.path) {
                try? FileManager.default.copyItem(at: settingsFile, to: settingsBackup)
            }
        }

        root["statusLine"] = [
            "type": "command",
            "command": "bash \"\(installedScript.path)\"",
        ]

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try atomicWrite(out, to: settingsFile)
        } catch let error as BridgeInstallerError {
            throw error
        } catch {
            throw BridgeInstallerError.writeFailed(String(describing: error))
        }
    }

    // MARK: - Self-test

    /// Distinctive percentages used as the self-test canary. Picked to be
    /// unusual enough that we can be reasonably confident the round-tripped
    /// state.json came from our payload and not a coincidental real one.
    private static let canarySession = 17.3
    private static let canaryWeekly = 31.7
    private static let canaryResetsAt = 1_700_000_000

    /// Runs the installed bridge with a canary stdin payload and verifies
    /// state.json reflects it. Restores any pre-existing state.json afterwards
    /// so the user doesn't see fake numbers in the menu bar.
    static func runSelfTest() -> SelfTestResult {
        guard isScriptInstalled else { return .notInstalled }
        guard isJQAvailable else { return .jqMissing }

        let stateFile = AppPaths.stateFile
        let statusFile = AppPaths.bridgeStatusFile
        let priorState = try? Data(contentsOf: stateFile)
        let priorStatus = try? Data(contentsOf: statusFile)
        defer {
            restore(priorState, to: stateFile)
            restore(priorStatus, to: statusFile)
        }

        let payload = """
        {"rate_limits":{\
        "five_hour":{"used_percentage":\(canarySession),"resets_at":\(canaryResetsAt)},\
        "seven_day":{"used_percentage":\(canaryWeekly),"resets_at":\(canaryResetsAt)}\
        }}
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installedScript.path]
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

    private static func restore(_ priorContents: Data?, to dest: URL) {
        if let priorContents {
            // Best-effort: same atomic-rename pattern as everywhere else.
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".\(dest.lastPathComponent).ccu.restore.\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try priorContents.write(to: tmp, options: .atomic)
                if rename(tmp.path, dest.path) != 0 {
                    try? FileManager.default.removeItem(at: tmp)
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
            }
        } else {
            try? FileManager.default.removeItem(at: dest)
        }
    }

    // MARK: - Internals

    static func bundledScriptURL() -> URL? {
        Bundle.module.url(forResource: "ccu-statusline-bridge", withExtension: "sh")
    }

    private static func currentStatusLineCommand() -> String? {
        guard FileManager.default.fileExists(atPath: settingsFile.path),
              let data = try? Data(contentsOf: settingsFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any]
        else { return nil }
        return statusLine["command"] as? String
    }

    private static func writeInnerSidecar(_ command: String) throws {
        let body = """
        # Written by Claude Code Usage — your previous statusLine command.
        # The bridge runs this so your existing statusline keeps working.
        \(command)

        """
        do {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: innerSidecar, options: .atomic)
        } catch {
            throw BridgeInstallerError.writeFailed(String(describing: error))
        }
    }

    private static func atomicWrite(_ data: Data, to dest: URL) throws {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).ccu.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw BridgeInstallerError.writeFailed(String(describing: error))
        }
        if rename(tmp.path, dest.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw BridgeInstallerError.writeFailed("rename: \(err)")
        }
    }
}
