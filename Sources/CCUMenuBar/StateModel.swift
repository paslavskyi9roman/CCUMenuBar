import CryptoKit
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
}

struct State: Codable, Equatable {
    var session: Bucket?
    var weekly: Bucket?
    var source: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case session
        case weekly
        case source
        case updatedAt = "updated_at"
    }

    var updatedAtDate: Date? {
        Self.iso8601.date(from: updatedAt)
    }

    var ageSeconds: TimeInterval? {
        guard let d = updatedAtDate else { return nil }
        return Date().timeIntervalSince(d)
    }

    var isStale: Bool {
        (ageSeconds ?? .infinity) > 300
    }

    func fingerprint() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
        State.iso8601.date(from: bridgeLastSeenAt)
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
