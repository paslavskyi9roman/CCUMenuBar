import Foundation

enum AppPaths {
    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    static let claudeDirectory = homeDirectory
        .appendingPathComponent(".claude", isDirectory: true)

    static let claudeScriptsDirectory = claudeDirectory
        .appendingPathComponent("scripts", isDirectory: true)

    static let claudeSettingsFile = claudeDirectory
        .appendingPathComponent("settings.json")

    /// Legacy plaintext OAuth credentials. Modern Claude Code stores them
    /// in the Keychain instead; the poller falls back to either.
    static let claudeCredentialsFile = claudeDirectory
        .appendingPathComponent(".credentials.json")

    static let stateDirectory = homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("ClaudeCodeUsage", isDirectory: true)

    static let stateFile = stateDirectory
        .appendingPathComponent("state.json")

    /// Written by the bridge on every invocation, even when `rate_limits` is
    /// null. Lets the app distinguish "bridge never invoked" from "bridge ran
    /// but no payload."
    static let bridgeStatusFile = stateDirectory
        .appendingPathComponent("bridge-status.json")

    static let bridgeLogFile = stateDirectory
        .appendingPathComponent("bridge.log")

    static let logDirectory = homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("ClaudeCodeUsage", isDirectory: true)

    static let appLogFile = logDirectory
        .appendingPathComponent("ccu.log")

    static let appLogBackupFile = logDirectory
        .appendingPathComponent("ccu.log.1")
}
