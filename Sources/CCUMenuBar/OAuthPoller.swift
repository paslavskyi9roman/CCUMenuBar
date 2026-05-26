import Foundation

/// Producer B. Reads the OAuth access token from `~/.claude/.credentials.json`
/// and polls the undocumented `/api/oauth/usage` endpoint every 60 s.
///
/// The endpoint shape is community-discovered, not contracted. We parse
/// defensively via `JSONSerialization`, trying several plausible key paths
/// and number/string formats. Any miss is logged with the raw body so the
/// candidate list can be tightened.
final class OAuthPoller {
    private let store: StateStore
    private var task: Task<Void, Never>?
    // Opt-in probe: log one successful /api/oauth/usage response per app
    // launch so its payload shape can be inspected (e.g. for per-model fields
    // we may not be parsing yet). Off by default — the response is from an
    // undocumented endpoint and we don't fully know what it carries, so we
    // don't write it to disk without the user opting in. Enable with:
    //   defaults write com.ccu.menubar ccu.debug.logOAuthSample -bool true
    // …then restart the app and check ~/Library/Logs/ClaudeCodeUsage/ccu.log.
    private var didLogSuccessSample = false
    // One-time log when we discover there are no OAuth credentials on disk.
    // Before this existed the poller went silent — the user saw `--%` and
    // nothing in ccu.log explaining why.
    private var didLogNoCredentials = false
    private static let debugLogSampleKey = "ccu.debug.logOAuthSample"

    private static let pollInterval: Duration = .seconds(60)
    private static let backoffAfterAuthStale: Duration = .seconds(300)
    private static let backoffNoCredentials: Duration = .seconds(300)

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let credentialsURL = AppPaths.claudeCredentialsFile

    init(store: StateStore) {
        self.store = store
    }

    var canRefresh: Bool {
        FileManager.default.isReadableFile(atPath: Self.credentialsURL.path)
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

    /// Trigger an immediate poll, bypassing the current sleep interval.
    /// `start()` cancels the sleeping loop and the fresh loop ticks at once.
    func refreshNow() {
        Log.info("manual refresh requested")
        start()
    }

    private func loop() async {
        while !Task.isCancelled {
            let nextDelay: Duration
            await MainActor.run { store.markOAuthRefreshStarted() }
            do {
                try await tick()
                await MainActor.run { store.markOAuthRefreshSucceeded() }
                nextDelay = Self.pollInterval
            } catch PollError.authStale {
                await MainActor.run {
                    store.markOAuthRefreshFailed("auth expired")
                    store.markOAuthUnavailable("auth expired", authStale: true)
                }
                nextDelay = Self.backoffAfterAuthStale
            } catch PollError.noCredentials {
                if !didLogNoCredentials {
                    didLogNoCredentials = true
                    Log.info("OAuth poller idle: \(Self.credentialsURL.path) not found")
                }
                await MainActor.run {
                    store.markOAuthRefreshFailed("no credentials")
                    store.markOAuthUnavailable("no credentials")
                }
                nextDelay = Self.backoffNoCredentials
            } catch {
                let reason = String(describing: error)
                await MainActor.run {
                    store.markOAuthRefreshFailed(reason)
                    store.markOAuthUnavailable(reason)
                }
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
        guard let token = readAccessToken() else {
            throw PollError.noCredentials
        }
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
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: Self.credentialsURL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let candidates: [[String]] = [
            ["claudeAiOauth", "accessToken"],
            ["claudeAiOauth", "access_token"],
            ["oauth", "accessToken"],
            ["oauth", "access_token"],
            ["accessToken"],
            ["access_token"],
        ]
        for path in candidates {
            if let value = traverse(root, path: path) as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Response parsing

    private struct UsageParsed {
        var session: Bucket?
        var weekly: Bucket?
    }

    private func parseUsage(data: Data) -> UsageParsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let sessionKeys = ["five_hour", "fiveHour", "session", "five_hour_limit"]
        let weeklyKeys = ["seven_day", "sevenDay", "weekly", "week", "seven_day_limit"]
        let session = extractBucket(from: root, keys: sessionKeys)
        let weekly = extractBucket(from: root, keys: weeklyKeys)
        if session == nil && weekly == nil { return nil }
        return UsageParsed(session: session, weekly: weekly)
    }

    private func extractBucket(from root: Any, keys: [String]) -> Bucket? {
        for k in keys {
            guard let dict = traverse(root, path: [k]) as? [String: Any] else { continue }
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
            if let n = dict[k] as? NSNumber {
                return n.doubleValue
            }
            if let s = dict[k] as? String, let d = Double(s) {
                return d
            }
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
                let v = n.doubleValue
                if v > 1e12 { return Int(v / 1000) }
                return Int(v)
            }
            if let s = dict[k] as? String {
                if let d = State.iso8601.date(from: s) {
                    return Int(d.timeIntervalSince1970)
                }
                if let v = Double(s) {
                    if v > 1e12 { return Int(v / 1000) }
                    return Int(v)
                }
            }
        }
        return nil
    }

    private func traverse(_ root: Any, path: [String]) -> Any? {
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
