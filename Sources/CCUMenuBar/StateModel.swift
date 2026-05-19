import CryptoKit
import Foundation

struct Bucket: Codable, Equatable {
    var usedPct: Double?
    var resetsAtUnix: Int?

    enum CodingKeys: String, CodingKey {
        case usedPct = "used_pct"
        case resetsAtUnix = "resets_at_unix"
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
