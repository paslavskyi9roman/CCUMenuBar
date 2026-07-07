import Foundation

/// Reads OAuth access tokens from Claude Code's macOS Keychain entries
/// (`Claude Code-credentials-<8-hex>`, one per install/profile).
///
/// We shell out to `/usr/bin/security` rather than calling SecItem with
/// `kSecMatchLimit = .all` — that would scan every generic-password entry
/// the app has ACL access to. `dump-keychain` returns metadata only (no
/// secret material, no prompt) so we can discover matching services first,
/// then ask for each password by name.
///
/// First read after each rebuild triggers a Keychain prompt — the bundle
/// is ad-hoc signed, so re-signing changes the identity. Users should pick
/// "Always Allow" to make subsequent polls silent.
enum KeychainCredentials {
    private static let servicePrefix = "Claude Code-credentials-"

    static func readAccessTokens() -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for service in discoverServices() {
            guard let token = accessToken(forService: service), !token.isEmpty else { continue }
            if seen.insert(token).inserted {
                tokens.append(token)
            }
        }
        return tokens
    }

    static func hasAnyEntry() -> Bool {
        !discoverServices().isEmpty
    }

    private static func discoverServices() -> [String] {
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
        return result
    }

    private static func accessToken(forService service: String) -> String? {
        guard let raw = runSecurity(["find-generic-password", "-s", service, "-w"]) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return OAuthPoller.extractAccessToken(from: root)
    }

    private static func runSecurity(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe() // swallow denied prompts, "item not found", etc.
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
