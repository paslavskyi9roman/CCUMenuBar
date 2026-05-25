import AppKit
import Foundation

enum ClaudeLogin {
    static var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: AppPaths.claudeCredentialsFile.path)
    }

    static func openInTerminal() {
        let command = "claude /login"
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
        if let error {
            Log.warn("could not open Terminal for Claude login: \(error)")
        }
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
