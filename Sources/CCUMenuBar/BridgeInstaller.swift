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
        guard let src = bundledScriptURL(),
              let data = FileManager.default.contents(atPath: src.path) else {
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
