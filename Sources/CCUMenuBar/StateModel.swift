import Foundation

struct Bucket: Codable, Equatable {
    var usedPct: Double?
    var resetsAtUnix: Int?

    enum CodingKeys: String, CodingKey {
        case usedPct = "used_pct"
        case resetsAtUnix = "resets_at_unix"
    }

    /// True when `resets_at_unix` is meaningfully in the past. After a window
    /// boundary, Claude Code briefly keeps emitting the *previous* window's
    /// `used_percentage` paired with the (now-past) old `resets_at`, until the
    /// first API call in the new window refreshes them. Treating those readings
    /// as untrustworthy keeps the UI from showing yesterday's number as if it
    /// were today's. 30s grace avoids flicker at the exact reset moment.
    var isResetOverdue: Bool {
        guard let unix = resetsAtUnix else { return false }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(unix))) > 30
    }

    /// Clamps `usedPct` to 0...100. The bridge's upstream JSON is uncontracted
    /// (see README "Caveats"); an out-of-range value would otherwise flip
    /// `Pace`'s projection negative and render nonsensical ETAs.
    func clamped() -> Bucket {
        var copy = self
        if let pct = copy.usedPct {
            copy.usedPct = min(max(pct, 0), 100)
        }
        return copy
    }
}

struct State: Codable, Equatable {
    /// Absent on files written before this field existed — treated as version 1
    /// (the original, unversioned shape) rather than failing to decode.
    var schemaVersion: Int?
    var session: Bucket?
    var weekly: Bucket?
    var source: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case session
        case weekly
        case source
        case updatedAt = "updated_at"
    }

    init(schemaVersion: Int? = 1, session: Bucket?, weekly: Bucket?, source: String, updatedAt: String) {
        self.schemaVersion = schemaVersion
        self.session = session
        self.weekly = weekly
        self.source = source
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        session = try c.decodeIfPresent(Bucket.self, forKey: .session)
        weekly = try c.decodeIfPresent(Bucket.self, forKey: .weekly)
        source = try c.decode(String.self, forKey: .source)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }

    var updatedAtDate: Date? {
        Self.parseTimestamp(updatedAt)
    }

    var ageSeconds: TimeInterval? {
        guard let d = updatedAtDate else { return nil }
        return Date().timeIntervalSince(d)
    }

    var isStale: Bool {
        (ageSeconds ?? .infinity) > 300
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Accepts both fractional- and whole-second ISO-8601 timestamps. `state.json`
    /// is a documented external interface (see README), so a third-party writer
    /// using fractional seconds shouldn't silently look "permanently stale."
    static func parseTimestamp(_ value: String) -> Date? {
        iso8601Fractional.date(from: value) ?? iso8601.date(from: value)
    }

    static func nowISO() -> String {
        iso8601.string(from: Date())
    }
}

/// Mirrors `bridge-status.json`. The bridge writes this on every invocation;
/// the app reads it lazily (no kqueue watch) to decide whether the bridge is
/// running but just hasn't seen a `rate_limits` payload yet.
struct BridgeStatus: Codable, Equatable {
    var schemaVersion: Int
    var bridgeLastSeenAt: String
    var bridgePath: String?
    var rateLimitsPresent: Bool
    var jqPath: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bridgeLastSeenAt = "bridge_last_seen_at"
        case bridgePath = "bridge_path"
        case rateLimitsPresent = "rate_limits_present"
        case jqPath = "jq_path"
    }

    var lastSeenDate: Date? {
        State.parseTimestamp(bridgeLastSeenAt)
    }

    var ageSeconds: TimeInterval? {
        guard let d = lastSeenDate else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// Considered "active" if we've seen a heartbeat within the last 5 minutes.
    /// Claude Code statuslines tick frequently while a session is open, so a
    /// gap longer than this means the bridge has stopped being invoked.
    var isActive: Bool {
        (ageSeconds ?? .infinity) <= 300
    }

    static func read(from url: URL = AppPaths.bridgeStatusFile) -> BridgeStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BridgeStatus.self, from: data)
    }
}
