import Foundation

/// Polls the undocumented `/api/oauth/usage` endpoint and writes
/// `state.json` with `source = "oauth"`. Authoritative tie-breaker for
/// multi-terminal flicker: the statusline bridge sees one Claude Code
/// session's cached `rate_limits` at a time; the poller talks to the
/// server directly.
final class OAuthPoller {
    private let store: StateStore
    private var task: Task<Void, Never>?
    private var didLogNoCredentials = false
    private var didLogSuccessSample = false

    private static let pollInterval: Duration = .seconds(60)
    private static let backoffAfterAuthStale: Duration = .seconds(300)
    private static let backoffNoCredentials: Duration = .seconds(300)
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let credentialsURL = AppPaths.claudeCredentialsFile
    private static let debugLogSampleKey = "ccu.debug.logOAuthSample"

    /// Endpoint emits `resets_at` with fractional seconds
    /// (`2026-05-31T08:00:00.276250+00:00`). `State.iso8601` doesn't.
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(store: StateStore) {
        self.store = store
    }

    var canRefresh: Bool {
        FileManager.default.isReadableFile(atPath: Self.credentialsURL.path)
            || KeychainCredentials.hasAnyEntry()
    }

    func start() {
        stop()
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshNow() {
        Log.info("oauth manual refresh requested")
        start()
    }

    private func loop() async {
        while !Task.isCancelled {
            let nextDelay: Duration
            do {
                try await tick()
                nextDelay = Self.pollInterval
            } catch PollError.authStale {
                Log.warn("oauth refresh failed: auth expired")
                nextDelay = Self.backoffAfterAuthStale
            } catch PollError.noCredentials {
                if !didLogNoCredentials {
                    didLogNoCredentials = true
                    Log.info("oauth poller idle: \(Self.credentialsURL.path) not found")
                }
                nextDelay = Self.backoffNoCredentials
            } catch {
                Log.warn("oauth refresh failed: \(error)")
                nextDelay = Self.pollInterval
            }
            do {
                try await Task.sleep(for: nextDelay)
            } catch {
                return
            }
        }
    }

    private func tick() async throws {
        let tokens = readAccessTokens()
        if tokens.isEmpty {
            throw PollError.noCredentials
        }
        // Keychain retains tokens for old profiles whose servers will 401;
        // walk every token before giving up.
        var lastError: Error = PollError.authStale
        for (index, token) in tokens.enumerated() {
            do {
                try await tick(withToken: token)
                if index > 0 {
                    Log.info("oauth refresh succeeded with credential #\(index + 1) of \(tokens.count)")
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

    private func tick(withToken token: String) async throws {
        var req = URLRequest(url: Self.usageURL)
        req.timeoutInterval = 15
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ccu-menubar/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PollError.transport("non-http response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PollError.authStale
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PollError.transport("http \(http.statusCode)")
        }
        guard let parsed = parseUsage(data: data) else {
            let preview = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(512)
            Log.warn("oauth usage parse miss; raw[\(data.count)B, first 512]=\(preview)")
            throw PollError.parse
        }
        if !didLogSuccessSample, UserDefaults.standard.bool(forKey: Self.debugLogSampleKey) {
            didLogSuccessSample = true
            let preview = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(2048)
            Log.info("oauth usage success sample [\(data.count)B, first 2048]=\(preview)")
        }
        let newState = State(
            session: parsed.session,
            weekly: parsed.weekly,
            source: "oauth",
            updatedAt: State.nowISO()
        )
        await MainActor.run { store.writeAndStore(newState) }
        Log.info("oauth refresh succeeded session=\(formatPct(parsed.session?.usedPct)) weekly=\(formatPct(parsed.weekly?.usedPct))")
    }

    private func formatPct(_ pct: Double?) -> String {
        pct.map { String(format: "%.1f%%", $0) } ?? "nil"
    }

    private func readAccessTokens() -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        if let token = readAccessTokenFromFile(), seen.insert(token).inserted {
            tokens.append(token)
        }
        for token in KeychainCredentials.readAccessTokens() where seen.insert(token).inserted {
            tokens.append(token)
        }
        return tokens
    }

    private func readAccessTokenFromFile() -> String? {
        guard let data = try? Data(contentsOf: Self.credentialsURL),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return Self.extractAccessToken(from: root)
    }

    // MARK: - Response parsing

    private struct UsageParsed {
        var session: Bucket?
        var weekly: Bucket?
    }

    /// Keys tried in order against any JSON root that might hold an OAuth
    /// access token. Covers both the legacy file shape and what Claude Code
    /// stores in the Keychain.
    static let accessTokenPaths: [[String]] = [
        ["claudeAiOauth", "accessToken"],
        ["claudeAiOauth", "access_token"],
        ["oauth", "accessToken"],
        ["oauth", "access_token"],
        ["accessToken"],
        ["access_token"],
    ]

    static func extractAccessToken(from root: Any) -> String? {
        for path in accessTokenPaths {
            if let value = traverse(root, path: path) as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func parseUsage(data: Data) -> UsageParsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let session = extractBucket(from: root, keys: ["five_hour", "fiveHour", "session", "five_hour_limit"])
        let weekly = extractBucket(from: root, keys: ["seven_day", "sevenDay", "weekly", "week", "seven_day_limit"])
        return (session == nil && weekly == nil) ? nil : UsageParsed(session: session, weekly: weekly)
    }

    private func extractBucket(from root: Any, keys: [String]) -> Bucket? {
        for k in keys {
            guard let dict = Self.traverse(root, path: [k]) as? [String: Any] else { continue }
            let pct = extractPercent(dict)
            let resets = extractResetsUnix(dict)
            if pct != nil || resets != nil {
                return Bucket(usedPct: pct, resetsAtUnix: resets)
            }
        }
        return nil
    }

    private func extractPercent(_ dict: [String: Any]) -> Double? {
        let keys = ["used_percentage", "usedPercentage", "utilization",
                    "usage_percentage", "usagePercentage",
                    "percentage", "percent", "used_pct"]
        for k in keys {
            if let n = dict[k] as? NSNumber { return n.doubleValue }
            if let s = dict[k] as? String, let d = Double(s) { return d }
        }
        if let usage = dict["usage"] as? [String: Any] {
            return extractPercent(usage)
        }
        return nil
    }

    private func extractResetsUnix(_ dict: [String: Any]) -> Int? {
        let keys = ["resets_at", "resetsAt", "reset_at", "resetAt",
                    "reset_time", "resetTime", "resets_at_unix"]
        for k in keys {
            if let n = dict[k] as? NSNumber {
                return normalizeUnix(n.doubleValue)
            }
            if let s = dict[k] as? String {
                if let d = State.iso8601.date(from: s) { return Int(d.timeIntervalSince1970) }
                if let d = Self.iso8601WithFractional.date(from: s) { return Int(d.timeIntervalSince1970) }
                if let v = Double(s) { return normalizeUnix(v) }
            }
        }
        return nil
    }

    /// Some encodings return milliseconds since epoch; everything beyond
    /// the year ~33000 must be ms, so normalize to seconds.
    private func normalizeUnix(_ v: Double) -> Int {
        v > 1e12 ? Int(v / 1000) : Int(v)
    }

    static func traverse(_ root: Any, path: [String]) -> Any? {
        var cur: Any? = root
        for k in path {
            guard let dict = cur as? [String: Any] else { return nil }
            cur = dict[k]
            if cur == nil { return nil }
        }
        return cur
    }
}

private enum PollError: Error {
    case noCredentials
    case authStale
    case transport(String)
    case parse
}
